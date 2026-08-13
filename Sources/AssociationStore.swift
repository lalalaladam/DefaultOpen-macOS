import Foundation
import UniformTypeIdentifiers

@MainActor
final class AssociationStore: ObservableObject {
    @Published var fileTypes: [FileTypeInfo] = []
    @Published private(set) var allFileTypes: [FileTypeInfo] = []
    @Published var applications: [ApplicationInfo] = []
    @Published var isScanning = false
    @Published private(set) var isLoadingFileTypes = false
    @Published private(set) var hasLoadedAllFileTypes = false
    @Published private(set) var defaultAppRevision = 0
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published private(set) var defaultsByContentType: [String: ApplicationInfo] = [:]
    @Published private(set) var customDefaultAppCategories: [DefaultAppCategory] = []

    private let launchServices = LaunchServicesClient()
    private let scanner = AppScanner()
    private let savedKey = "managedExtensions"
    private let customDefaultAppCategoriesKey = "customDefaultAppCategories"
    private let ignoredDefaultAppTypesKey = "ignoredDefaultAppTypesByCategory"
    private let includedDefaultAppTypesKey = "includedDefaultAppTypesByCategory"
    private let starterExtensions = ["pdf", "txt", "md", "jpg", "png", "heic", "svg", "zip", "json", "csv", "docx", "xlsx", "pptx", "html", "mp3", "mp4"]
    private var optimisticDefaultAppStatuses: [String: DefaultAppCategoryStatus] = [:]
    private var queriedApplicationExtensions = Set<String>()
    private var queriedDefaultContentTypes = Set<String>()
    private var registeredFileTypesByExtension: [String: [FileTypeInfo]] = [:]
    private var ignoredDefaultAppTypesByCategory: [String: Set<String>]
    private var includedDefaultAppTypesByCategory: [String: Set<String>]

    init() {
        ignoredDefaultAppTypesByCategory = Self.loadIgnoredDefaultAppTypes()
        includedDefaultAppTypesByCategory = Self.loadIncludedDefaultAppTypes()
        customDefaultAppCategories = Self.loadCustomDefaultAppCategories()
        let saved = customExtensionNames
        fileTypes = (starterExtensions + saved).uniqued().compactMap { try? launchServices.fileType(for: $0) }
            .sorted { $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending }
        allFileTypes = fileTypes
        refreshDefaults(for: fileTypes)
    }

    func saveCustomDefaultAppCategory(id: String?, title: String, subtitle: String,
                                      symbol: String, extensions: [String]) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExtensions = extensions.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased()
        }.filter { !$0.isEmpty }.uniqued()

        guard !normalizedTitle.isEmpty else {
            errorMessage = L10n.string("请输入组合名称。")
            return false
        }
        let invalidExtensions = normalizedExtensions.filter {
            (try? launchServices.fileType(for: $0)) == nil
        }
        guard invalidExtensions.isEmpty else {
            errorMessage = L10n.format(
                "error.unrecognizedExtensions",
                invalidExtensions.joined(separator: L10n.string("list.separator"))
            )
            return false
        }

        let category = DefaultAppCategory(
            id: id ?? "custom.\(UUID().uuidString.lowercased())",
            title: normalizedTitle,
            subtitle: normalizedSubtitle,
            symbol: symbol,
            coreExtensions: normalizedExtensions,
            optionalExtensions: [],
            urlSchemes: [],
            isCustom: true
        )
        if let index = customDefaultAppCategories.firstIndex(where: { $0.id == category.id }) {
            customDefaultAppCategories[index] = category
        } else {
            customDefaultAppCategories.append(category)
        }
        persistCustomDefaultAppCategories()
        pruneDefaultAppTypePolicies(for: category)
        removeOptimisticDefaultAppStatuses(for: category)
        defaultAppRevision += 1
        return true
    }

    func recognizedExtensions(_ extensions: [String]) -> [String] {
        extensions.filter { (try? launchServices.fileType(for: $0)) != nil }
    }

    func removeCustomDefaultAppCategory(_ category: DefaultAppCategory) {
        guard category.isCustom else { return }
        customDefaultAppCategories.removeAll { $0.id == category.id }
        ignoredDefaultAppTypesByCategory.removeValue(forKey: category.id)
        includedDefaultAppTypesByCategory.removeValue(forKey: category.id)
        persistIgnoredDefaultAppTypes()
        persistIncludedDefaultAppTypes()
        removeOptimisticDefaultAppStatuses(for: category)
        persistCustomDefaultAppCategories()
        defaultAppRevision += 1
    }

    func scanApplications() async {
        guard !isScanning else { return }
        isScanning = true
        let scanner = self.scanner
        let managedTypes = fileTypes
        let launchServices = self.launchServices
        let result = await Task.detached(priority: .userInitiated) {
            let apps = scanner.scanInstalledApplications(managedTypes: managedTypes)
            let discoveredTypes = apps.flatMap(\.supportedTypes).flatMap(\.fileTypes)
            var defaults: [String: ApplicationInfo] = [:]
            for type in Dictionary(grouping: managedTypes + discoveredTypes,
                                   by: \FileTypeInfo.contentTypeIdentifier).compactMap(\.value.first) {
                defaults[type.contentTypeIdentifier] = launchServices.defaultApplication(for: type)
            }
            return (apps, defaults)
        }.value
        applications = result.0
        registeredFileTypesByExtension.removeAll()
        mergeIntoFileTypeCatalog(result.0.flatMap(\.supportedTypes).flatMap(\.fileTypes))
        defaultsByContentType.merge(result.1) { _, new in new }
        isScanning = false
    }

    func loadApplications(matchingExtensionSearch searchText: String) async {
        let extensionName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !extensionName.isEmpty,
              extensionName.count <= 32,
              !extensionName.contains(where: { $0.isWhitespace || $0 == "." }),
              !queriedApplicationExtensions.contains(extensionName) else { return }

        queriedApplicationExtensions.insert(extensionName)
        let fileTypes = (try? launchServices.fileTypes(for: extensionName)) ?? []
        guard !fileTypes.isEmpty else { return }
        let scanner = self.scanner
        let discovered = await Task.detached(priority: .userInitiated) {
            fileTypes.flatMap { scanner.applicationsCapable(of: $0) }
        }.value
        guard !discovered.isEmpty else { return }
        mergeApplications(discovered)
        if let representative = fileTypes.first,
           UTType(representative.contentTypeIdentifier)?.isDynamic == false {
            mergeIntoFileTypeCatalog([representative])
        }
        for fileType in fileTypes {
            if let defaultApplication = launchServices.defaultApplication(for: fileType) {
                defaultsByContentType[fileType.contentTypeIdentifier] = defaultApplication
            }
        }
    }

    func loadDefaultApplication(matchingExtensionSearch searchText: String) async {
        let extensionName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !extensionName.isEmpty,
              extensionName.count <= 32,
              !extensionName.contains(where: { $0.isWhitespace || $0 == "." }),
              let fileType = try? launchServices.fileType(for: extensionName),
              defaultsByContentType[fileType.contentTypeIdentifier] == nil,
              !queriedDefaultContentTypes.contains(fileType.contentTypeIdentifier) else { return }

        queriedDefaultContentTypes.insert(fileType.contentTypeIdentifier)
        let launchServices = self.launchServices
        let defaultApplication = await Task.detached(priority: .userInitiated) {
            launchServices.defaultApplication(for: fileType)
        }.value
        if let defaultApplication {
            defaultsByContentType[fileType.contentTypeIdentifier] = defaultApplication
        }
    }

    func loadAllFileTypes() async {
        guard !isLoadingFileTypes, !hasLoadedAllFileTypes else { return }
        isLoadingFileTypes = true
        defer { isLoadingFileTypes = false }
        let scanner = self.scanner
        let launchServices = self.launchServices
        let result = await Task.detached(priority: .userInitiated) {
            let discoveredTypes = scanner.scanDeclaredFileTypes().flatMap(\.fileTypes)
            let uniqueTypes = Dictionary(
                grouping: discoveredTypes,
                by: \FileTypeInfo.contentTypeIdentifier
            ).compactMap(\.value.first)
            let defaults = Dictionary(uniqueKeysWithValues: uniqueTypes.compactMap { type in
                launchServices.defaultApplication(for: type).map {
                    (type.contentTypeIdentifier, $0)
                }
            })
            return (discoveredTypes, defaults)
        }.value
        mergeIntoFileTypeCatalog(result.0)
        defaultsByContentType.merge(result.1) { _, new in new }
        hasLoadedAllFileTypes = true
    }

    func addExtension(_ value: String) -> Bool {
        do {
            let type = try launchServices.fileType(for: value)
            let isKnownType = allFileTypes.contains(where: { $0.id == type.id })
            if !fileTypes.contains(where: { $0.id == type.id }) {
                fileTypes.append(type)
                fileTypes.sort { $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending }
            }
            mergeIntoFileTypeCatalog([type])
            if !isKnownType && !starterExtensions.contains(type.extensionName.lowercased()) {
                var custom = customExtensionNames
                if !custom.contains(type.extensionName.lowercased()) {
                    custom.append(type.extensionName.lowercased())
                    persistCustomExtensions(custom)
                }
            }
            refreshDefaults(for: [type])
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    var customFileTypes: [FileTypeInfo] {
        customExtensionNames.compactMap { extensionName in
            fileTypes.first { $0.extensionName.caseInsensitiveCompare(extensionName) == .orderedSame }
                ?? (try? launchServices.fileType(for: extensionName))
        }.sorted { $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending }
    }

    func isCustomFileType(_ type: FileTypeInfo) -> Bool {
        customExtensionNames.contains(type.extensionName.lowercased())
    }

    func isKnownFileType(_ type: FileTypeInfo) -> Bool {
        allFileTypes.contains(where: { $0.id == type.id })
    }

    func removeCustomExtension(_ type: FileTypeInfo) {
        let extensionName = type.extensionName.lowercased()
        guard customExtensionNames.contains(extensionName) else { return }
        persistCustomExtensions(customExtensionNames.filter { $0 != extensionName })
        fileTypes.removeAll { $0.extensionName.lowercased() == extensionName }
        allFileTypes.removeAll { $0.extensionName.lowercased() == extensionName }
    }

    func defaultApplication(for type: FileTypeInfo) -> ApplicationInfo? {
        defaultsByContentType[type.contentTypeIdentifier]
    }

    func registeredFileTypes(forExtension extensionName: String) -> [FileTypeInfo] {
        let normalized = extensionName.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            .lowercased()
        if let cached = registeredFileTypesByExtension[normalized] { return cached }
        let types = (try? launchServices.fileTypes(for: normalized)) ?? []
        registeredFileTypesByExtension[normalized] = types
        return types
    }

    func registeredFileTypes(forExtensions extensionNames: [String]) -> [FileTypeInfo] {
        let types = extensionNames.flatMap { registeredFileTypes(forExtension: $0) }
        return Dictionary(grouping: types, by: \.contentTypeIdentifier)
            .compactMap(\.value.first)
    }

    func currentSystemDefaultApplication(for type: FileTypeInfo) -> ApplicationInfo? {
        launchServices.defaultApplication(for: type)
    }

    func capableApplications(for type: FileTypeInfo) -> [ApplicationInfo] {
        launchServices.capableApplications(for: type)
    }

    func modificationRisk(for type: FileTypeInfo) -> FileTypeModificationRisk {
        let identifier = type.contentTypeIdentifier
        if Self.protectedContentTypeIdentifiers.contains(identifier) { return .protected }
        if Self.broadContentTypeIdentifiers.contains(identifier) { return .broad }
        return .normal
    }

    func broadTypeIdentifiers(for category: DefaultAppCategory,
                              includingOptional: Bool) -> [String] {
        resolvedFileTypes(for: category, includingOptional: includingOptional)
            .filter { isDefaultAppTypeManaged($0.contentTypeIdentifier, for: category) }
            .filter { modificationRisk(for: $0) == .broad }
            .map(\.contentTypeIdentifier)
            .uniqued().sorted()
    }

    func validatedApplication(at url: URL, for type: FileTypeInfo) throws -> ApplicationInfo {
        let application = try scanner.applicationInfo(at: url)
        guard applicationSupports(application, fileType: type) else {
            throw AssociationError.incompatibleApplication(application.name, [type.dottedExtension])
        }
        return application
    }

    func validatedDefaultAppCandidate(at url: URL, for category: DefaultAppCategory,
                                      includingOptional: Bool) throws -> DefaultAppCandidate {
        let application = try scanner.applicationInfo(at: url)
        let allCoreTargets = defaultAppDisplayTargets(for: category, includingOptional: false)
        let allTargets = defaultAppDisplayTargets(for: category, includingOptional: includingOptional)
        let coreTargets = managedDefaultAppTargets(allCoreTargets, for: category)
        let targets = managedDefaultAppTargets(allTargets, for: category)
        let validationTargets = coreTargets.isEmpty ? allCoreTargets : coreTargets
        guard validationTargets.contains(where: { applicationSupports(application, target: $0) }) else {
            throw AssociationError.incompatibleApplication(application.name,
                                                            validationTargets.map(\.label).uniqued())
        }
        let supported = targets.filter { applicationSupports(application, target: $0) }
        let unsupported = targets.filter { !applicationSupports(application, target: $0) }
        let currentTargets = targets.filter {
            $0.defaultApplication?.bundleIdentifier == application.bundleIdentifier
        }.map(\.label).uniqued()
        return DefaultAppCandidate(
            application: application,
            supportedCount: supported.count,
            totalCount: targets.count,
            supportedTargets: supported.map(\.label).uniqued(),
            unsupportedTargets: unsupported.map(\.label).uniqued(),
            currentTargets: currentTargets,
            isCurrentDefault: targets.allSatisfy {
                $0.defaultApplication?.bundleIdentifier == application.bundleIdentifier
            },
            typeDetails: allTargets.map {
                candidateTypeDetail($0, application: application, category: category)
            }
        )
    }

    func defaultAppStatus(for category: DefaultAppCategory,
                          includingOptional: Bool = false) -> DefaultAppCategoryStatus {
        _ = defaultAppRevision
        let statusKey = defaultAppStatusKey(for: category, includingOptional: includingOptional)
        if let optimistic = optimisticDefaultAppStatuses[statusKey] { return optimistic }
        return systemDefaultAppStatus(for: category, includingOptional: includingOptional)
    }

    func optionalDefaultAppStatus(for category: DefaultAppCategory) -> DefaultAppCategoryStatus {
        _ = defaultAppRevision
        let optionalCategory = DefaultAppCategory(
            id: category.id + ".optional-status",
            title: category.title,
            subtitle: category.subtitle,
            symbol: category.symbol,
            coreExtensions: category.optionalExtensions,
            optionalExtensions: [],
            urlSchemes: []
        )
        let targets = defaultAppTargets(for: optionalCategory, includingOptional: false,
                                        includeCapabilities: false)
        return defaultAppStatus(from: managedDefaultAppTargets(targets, for: category),
                                ignoredTypeCount: ignoredTypeCount(in: targets, for: category))
    }

    func defaultAppTypeDetails(for category: DefaultAppCategory,
                               includingOptional: Bool) -> [DefaultAppCategoryTypeDetail] {
        _ = defaultAppRevision
        return defaultAppDisplayTargets(for: category, includingOptional: includingOptional).map { target in
            let typeName: String
            let identifier: String
            let risk: FileTypeModificationRisk
            let canCustomizeScope: Bool
            let isAutomaticallyManaged: Bool
            switch target.kind {
            case .urlScheme(let scheme):
                typeName = L10n.string("网页链接")
                identifier = scheme.lowercased()
                risk = .normal
                canCustomizeScope = false
                isAutomaticallyManaged = true
            case .fileType(let type):
                typeName = type.specificDisplayName
                identifier = type.contentTypeIdentifier
                risk = modificationRisk(for: type)
                canCustomizeScope = true
                isAutomaticallyManaged = isAutomaticallyManagedDefaultAppType(
                    identifier,
                    for: category
                )
            }
            let scopePolicy = defaultAppTypeScopePolicy(identifier, for: category)
            return DefaultAppCategoryTypeDetail(
                id: target.key,
                label: target.label,
                typeName: typeName,
                technicalIdentifier: identifier,
                modificationRisk: risk,
                canCustomizeScope: canCustomizeScope,
                scopePolicy: scopePolicy,
                isAutomaticallyManaged: isAutomaticallyManaged,
                isManaged: !canCustomizeScope || isDefaultAppTypeManaged(identifier, for: category)
            )
        }
    }

    private func systemDefaultAppStatus(for category: DefaultAppCategory,
                                        includingOptional: Bool) -> DefaultAppCategoryStatus {
        let targets = defaultAppTargets(for: category, includingOptional: includingOptional,
                                        includeCapabilities: false)
        return defaultAppStatus(from: managedDefaultAppTargets(targets, for: category),
                                ignoredTypeCount: ignoredTypeCount(in: targets, for: category))
    }

    private func defaultAppStatus(from targets: [DefaultAppTarget],
                                  ignoredTypeCount: Int) -> DefaultAppCategoryStatus {
        let missingTargets = targets.filter { $0.defaultApplication == nil }.map(\.label).uniqued()
        let assignedTargets = targets.compactMap { target -> (ApplicationInfo, String)? in
            guard let app = target.defaultApplication else { return nil }
            return (app, target.label)
        }
        let assignments = Dictionary(grouping: assignedTargets, by: { $0.0.bundleIdentifier }).values
            .compactMap { values -> DefaultAppAssignment? in
                guard let app = values.first?.0 else { return nil }
                return DefaultAppAssignment(application: app, targets: values.map(\.1).uniqued())
            }
            .sorted { $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending }
        let unified = missingTargets.isEmpty && assignments.count == 1 ? assignments.first?.application : nil
        return DefaultAppCategoryStatus(unifiedApplication: unified,
                                        assignments: assignments,
                                        missingTargets: missingTargets,
                                        ignoredTypeCount: ignoredTypeCount)
    }

    func defaultAppCandidates(for category: DefaultAppCategory,
                              includingOptional: Bool) -> [DefaultAppCandidate] {
        let allTargets = defaultAppTargets(for: category, includingOptional: includingOptional)
        let targets = managedDefaultAppTargets(allTargets, for: category)
        var appsByID: [String: ApplicationInfo] = [:]

        let discoveryTargets = targets.isEmpty ? allTargets : targets
        for target in discoveryTargets {
            for app in target.capableApplications {
                appsByID[app.bundleIdentifier] = app
            }
        }

        let allDisplayCoreTargets = defaultAppDisplayTargets(for: category, includingOptional: false)
        let allDisplayTargets = defaultAppDisplayTargets(for: category,
                                                         includingOptional: includingOptional)
        let displayCoreTargets = managedDefaultAppTargets(allDisplayCoreTargets, for: category)
        let displayTargets = managedDefaultAppTargets(allDisplayTargets, for: category)
        return appsByID.values.compactMap { app in
            let candidateCoreTargets = displayCoreTargets.isEmpty
                ? allDisplayCoreTargets : displayCoreTargets
            guard candidateCoreTargets.contains(where: { applicationSupports(app, target: $0) }) else {
                return nil
            }
            let supportedTargets = displayTargets.filter { applicationSupports(app, target: $0) }
            let currentTargets = displayTargets.filter {
                $0.defaultApplication?.bundleIdentifier == app.bundleIdentifier
            }.map(\.label).uniqued()
            let isCurrentDefault = displayTargets.allSatisfy {
                $0.defaultApplication?.bundleIdentifier == app.bundleIdentifier
            }
            return DefaultAppCandidate(application: app,
                                       supportedCount: supportedTargets.count,
                                       totalCount: displayTargets.count,
                                       supportedTargets: supportedTargets.map(\.label).uniqued(),
                                       unsupportedTargets: displayTargets.filter {
                                           !applicationSupports(app, target: $0)
                                       }.map(\.label).uniqued(),
                                       currentTargets: currentTargets,
                                       isCurrentDefault: isCurrentDefault,
                                       typeDetails: allDisplayTargets.map {
                                           candidateTypeDetail($0, application: app,
                                                               category: category)
                                       })
        }.sorted {
            if $0.supportedCount != $1.supportedCount { return $0.supportedCount > $1.supportedCount }
            return $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
        }
    }

    func setDefault(_ application: ApplicationInfo, for category: DefaultAppCategory,
                    includingOptional: Bool,
                    progress: (Int, Int, String) -> Void) async -> DefaultAppChangeResult? {
        do {
            var changedTargets: [String] = []
            var skippedTargets: [String] = []
            var unchangedTargets: [String] = []
            var operations: [DefaultChangeOperation] = []

            for scheme in category.urlSchemes {
                let label = scheme.uppercased()
                if launchServices.defaultApplication(forURLScheme: scheme)?.bundleIdentifier
                    == application.bundleIdentifier {
                    unchangedTargets.append(label)
                    continue
                }
                guard applicationSupports(application, urlScheme: scheme) else {
                    skippedTargets.append(label)
                    continue
                }
                operations.append(.scheme(scheme, label))
            }

            for type in resolvedFileTypes(for: category, includingOptional: includingOptional)
                where isDefaultAppTypeManaged(type.contentTypeIdentifier, for: category) {
                if modificationRisk(for: type) == .protected {
                    skippedTargets.append(type.dottedExtension)
                    continue
                }
                if launchServices.defaultApplication(for: type)?.bundleIdentifier == application.bundleIdentifier {
                    unchangedTargets.append(type.dottedExtension)
                    continue
                }
                guard applicationSupports(application, fileType: type) else {
                    skippedTargets.append(type.dottedExtension)
                    continue
                }
                operations.append(.fileType(type))
            }

            guard !operations.isEmpty || !unchangedTargets.isEmpty else {
                errorMessage = L10n.format("error.notRegisteredForFormats", application.name)
                return nil
            }

            var changedTypes: [FileTypeInfo] = []
            for (index, operation) in operations.enumerated() {
                progress(index + 1, operations.count, operation.label)
                await Task.yield()
                switch operation {
                case .scheme(let scheme, let label):
                    try await launchServices.setDefaultAwaitingConsent(application, forURLScheme: scheme)
                    changedTargets.append(label)
                case .fileType(let type):
                    try await launchServices.setDefaultAwaitingConsent(application, for: type)
                    changedTypes.append(type)
                    changedTargets.append(type.dottedExtension)
                }
            }

            refreshDefaults(for: changedTypes)
            let statusKey = defaultAppStatusKey(for: category, includingOptional: includingOptional)
            let selectedLabels = defaultAppTargets(for: category, includingOptional: includingOptional,
                                                   includeCapabilities: false)
                .filter { isDefaultAppTargetManaged($0, for: category) }
                .map(\.label).uniqued()
            let ignoredCount = ignoredTypeCount(
                in: defaultAppTargets(for: category, includingOptional: includingOptional,
                                      includeCapabilities: false),
                for: category
            )
            if skippedTargets.isEmpty {
                optimisticDefaultAppStatuses[statusKey] = DefaultAppCategoryStatus(
                    unifiedApplication: application,
                    assignments: [DefaultAppAssignment(application: application, targets: selectedLabels)],
                    missingTargets: [],
                    ignoredTypeCount: ignoredCount
                )
            }
            defaultAppRevision += 1
            successMessage = changedTargets.isEmpty
                ? L10n.format("success.alreadyCategoryDefault", application.name, category.title)
                : L10n.format("success.setCategoryDefault", application.name, category.title)
            if !changedTargets.isEmpty && skippedTargets.isEmpty {
                verifyDefaultAppStatus(application, for: category, includingOptional: includingOptional)
            }
            return DefaultAppChangeResult(changedTargets: changedTargets,
                                          skippedTargets: skippedTargets.uniqued(),
                                          unchangedTargets: unchangedTargets.uniqued())
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func setDefault(_ application: ApplicationInfo, for types: [FileTypeInfo]) async -> Bool {
        do {
            let uniqueTypes = Dictionary(grouping: types, by: \FileTypeInfo.contentTypeIdentifier)
                .compactMap(\.value.first)
            guard !uniqueTypes.contains(where: { modificationRisk(for: $0) == .protected }) else {
                errorMessage = L10n.string("基础 UTType 仅供查看，不能修改默认 App。")
                return false
            }
            let unsupportedTypes = uniqueTypes.filter {
                !applicationSupports(application, fileType: $0)
            }
            guard unsupportedTypes.isEmpty else {
                errorMessage = AssociationError.incompatibleApplication(
                    application.name,
                    unsupportedTypes.map(\.dottedExtension)
                ).localizedDescription
                return false
            }
            let typesToChange = uniqueTypes.filter {
                launchServices.defaultApplication(for: $0)?.bundleIdentifier != application.bundleIdentifier
            }
            for type in typesToChange {
                try await launchServices.setDefaultAwaitingConsent(application, for: type)
            }
            refreshDefaults(for: uniqueTypes)
            successMessage = typesToChange.isEmpty
                ? L10n.format("success.typesAlreadyUseApp", application.name)
                : typesToChange.count == 1
                    ? L10n.format("success.setExtensionDefault", application.name, typesToChange[0].dottedExtension)
                    : L10n.format("success.setMultipleDefaults", application.name, typesToChange.count)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                refreshDefaults(for: uniqueTypes)
                try? await Task.sleep(for: .milliseconds(900))
                refreshDefaults(for: uniqueTypes)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshDefaults(for types: [FileTypeInfo]? = nil) {
        let target = types ?? fileTypes
        for type in target {
            if let application = launchServices.defaultApplication(for: type) {
                defaultsByContentType[type.contentTypeIdentifier] = application
            } else {
                defaultsByContentType.removeValue(forKey: type.contentTypeIdentifier)
            }
        }
    }

    func refreshExternalDefaultChanges() async {
        let categoryExtensions = (DefaultAppCategory.all + customDefaultAppCategories)
            .flatMap { $0.extensions(includingOptional: true) }
        let categoryTypes = registeredFileTypes(forExtensions: categoryExtensions)
        let registeredTypes = registeredFileTypesByExtension.values.flatMap { $0 }
        let applicationTypes = applications.flatMap(\.supportedTypes).flatMap(\.fileTypes)
        let types = Dictionary(grouping: fileTypes + allFileTypes + categoryTypes
                               + registeredTypes + applicationTypes,
                               by: \.contentTypeIdentifier)
            .compactMap(\.value.first)
        let launchServices = self.launchServices
        let refreshed = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: types.map { type in
                (type.contentTypeIdentifier, launchServices.defaultApplication(for: type))
            })
        }.value
        optimisticDefaultAppStatuses.removeAll()
        for (identifier, application) in refreshed {
            if let application {
                defaultsByContentType[identifier] = application
            } else {
                defaultsByContentType.removeValue(forKey: identifier)
            }
        }
        defaultAppRevision += 1
    }

    func fileTypes(for supportedType: SupportedType) -> [FileTypeInfo] {
        let extensions = supportedType.extensions
        if extensions.isEmpty,
           let fallback = fileTypes.first(where: { $0.contentTypeIdentifier == supportedType.contentTypeIdentifier }) {
            return [fallback]
        }
        return supportedType.fileTypes
    }

    func matchingFileTypes(for searchText: String, includeAll: Bool,
                           includesDisplayName: Bool,
                           includesContentTypeIdentifier: Bool) -> [FileTypeSearchResult] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let source = includeAll ? allFileTypes : fileTypes.filter { !isCustomFileType($0) }
            return source.map { FileTypeSearchResult(type: $0, rank: nil) }
        }

        let source = allFileTypes
        let extensionQuery = query.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let requiresExactExtension = query.hasPrefix(".")
        var matches = source.compactMap { type -> FileTypeSearchResult? in
            guard let rank = FileTypeSearchRank.match(type: type, query: query,
                                                      extensionQuery: extensionQuery,
                                                      requiresExactExtension: requiresExactExtension,
                                                      includesDisplayName: includesDisplayName,
                                                      includesContentTypeIdentifier:
                                                        includesContentTypeIdentifier) else { return nil }
            return FileTypeSearchResult(type: type, rank: rank)
        }
        if hasLoadedAllFileTypes,
           let exactType = try? launchServices.fileType(for: extensionQuery),
           !matches.contains(where: { $0.type.id == exactType.id }) {
            matches.append(FileTypeSearchResult(type: exactType, rank: .unregistered))
        }
        return matches
    }

    func matchingCatalogFileTypes(for searchText: String, includeAll: Bool) -> [FileTypeInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return includeAll ? allFileTypes : fileTypes.filter { !isCustomFileType($0) }
        }
        let source = allFileTypes
        let extensionQuery = query.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return source.filter {
            FileTypeSearchRank.match(type: $0, query: query,
                                     extensionQuery: extensionQuery,
                                     requiresExactExtension: query.hasPrefix("."),
                                     includesDisplayName: true,
                                     includesContentTypeIdentifier: true) != nil
        }
    }

    private var customExtensionNames: [String] {
        let starterSet = Set(starterExtensions)
        return (UserDefaults.standard.stringArray(forKey: savedKey) ?? [])
            .map { $0.lowercased() }
            .filter { !starterSet.contains($0) }
            .uniqued()
    }

    private func persistCustomExtensions(_ extensions: [String]) {
        UserDefaults.standard.set(extensions, forKey: savedKey)
    }

    private static func loadCustomDefaultAppCategories() -> [DefaultAppCategory] {
        guard let data = UserDefaults.standard.data(forKey: "customDefaultAppCategories"),
              let categories = try? JSONDecoder().decode([DefaultAppCategory].self, from: data) else {
            return []
        }
        return categories.filter(\.isCustom)
    }

    private func persistCustomDefaultAppCategories() {
        guard let data = try? JSONEncoder().encode(customDefaultAppCategories) else { return }
        UserDefaults.standard.set(data, forKey: customDefaultAppCategoriesKey)
    }

    private static func loadIgnoredDefaultAppTypes() -> [String: Set<String>] {
        guard let raw = UserDefaults.standard.dictionary(forKey: "ignoredDefaultAppTypesByCategory")
                as? [String: [String]] else { return [:] }
        return raw.mapValues(Set.init)
    }

    private static func loadIncludedDefaultAppTypes() -> [String: Set<String>] {
        guard let raw = UserDefaults.standard.dictionary(forKey: "includedDefaultAppTypesByCategory")
                as? [String: [String]] else { return [:] }
        return raw.mapValues(Set.init)
    }

    private func persistIgnoredDefaultAppTypes() {
        let raw = ignoredDefaultAppTypesByCategory.mapValues { Array($0).sorted() }
        UserDefaults.standard.set(raw, forKey: ignoredDefaultAppTypesKey)
    }

    private func persistIncludedDefaultAppTypes() {
        let raw = includedDefaultAppTypesByCategory.mapValues { Array($0).sorted() }
        UserDefaults.standard.set(raw, forKey: includedDefaultAppTypesKey)
    }

    private func pruneDefaultAppTypePolicies(for category: DefaultAppCategory) {
        let valid = Set(candidateFileTypes(forExtensions: category.coreExtensions)
            .map(\.contentTypeIdentifier))
        if let ignored = ignoredDefaultAppTypesByCategory[category.id] {
            let retained = ignored.intersection(valid)
            if retained.isEmpty {
                ignoredDefaultAppTypesByCategory.removeValue(forKey: category.id)
            } else {
                ignoredDefaultAppTypesByCategory[category.id] = retained
            }
        }
        if let included = includedDefaultAppTypesByCategory[category.id] {
            let retained = included.intersection(valid)
            if retained.isEmpty {
                includedDefaultAppTypesByCategory.removeValue(forKey: category.id)
            } else {
                includedDefaultAppTypesByCategory[category.id] = retained
            }
        }
        persistIgnoredDefaultAppTypes()
        persistIncludedDefaultAppTypes()
    }

    private func mergeIntoFileTypeCatalog(_ types: [FileTypeInfo]) {
        let inferredTypes = types.map { type in
            (try? launchServices.fileType(for: type.extensionName)) ?? type
        }
        allFileTypes = Dictionary(grouping: allFileTypes + inferredTypes, by: \FileTypeInfo.id)
            .compactMap(\.value.first)
            .sorted { $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending }
    }

    private func mergeApplications(_ discovered: [ApplicationInfo]) {
        var merged = Dictionary(uniqueKeysWithValues: applications.map { ($0.bundleIdentifier, $0) })
        for application in discovered {
            guard let existing = merged[application.bundleIdentifier] else {
                merged[application.bundleIdentifier] = application
                continue
            }
            var types = Dictionary(
                uniqueKeysWithValues: existing.supportedTypes.map { ($0.contentTypeIdentifier, $0) }
            )
            for type in application.supportedTypes {
                if let previous = types[type.contentTypeIdentifier] {
                    types[type.contentTypeIdentifier] = SupportedType(
                        contentTypeIdentifier: previous.contentTypeIdentifier,
                        extensions: (previous.extensions + type.extensions).uniqued().sorted(),
                        displayName: previous.displayName
                    )
                } else {
                    types[type.contentTypeIdentifier] = type
                }
            }
            merged[application.bundleIdentifier] = ApplicationInfo(
                bundleIdentifier: existing.bundleIdentifier,
                name: existing.name,
                url: existing.url,
                supportedTypes: types.values.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                },
                searchAliases: (existing.searchAliases + application.searchAliases).uniqued()
            )
        }
        applications = merged.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func resolvedFileTypes(for category: DefaultAppCategory,
                                   includingOptional: Bool) -> [FileTypeInfo] {
        let types = candidateFileTypes(
            forExtensions: category.extensions(includingOptional: includingOptional)
        )
        return Dictionary(grouping: types, by: \FileTypeInfo.contentTypeIdentifier).compactMap(\.value.first)
    }

    private func candidateFileTypes(forExtensions extensions: [String]) -> [FileTypeInfo] {
        extensions.flatMap { ext in
            var types: [FileTypeInfo] = []
            if let inferred = try? launchServices.fileType(for: ext) { types.append(inferred) }
            types += (try? launchServices.fileTypes(for: ext)) ?? []
            return Dictionary(grouping: types, by: \.contentTypeIdentifier)
                .compactMap(\.value.first)
        }
    }

    private func defaultAppTargets(for category: DefaultAppCategory,
                                   includingOptional: Bool,
                                   includeCapabilities: Bool = true) -> [DefaultAppTarget] {
        var targets = category.urlSchemes.map { scheme in
            DefaultAppTarget(key: "scheme:\(scheme)", label: scheme.uppercased(),
                             kind: .urlScheme(scheme),
                             defaultApplication: launchServices.defaultApplication(forURLScheme: scheme),
                             capableApplications: includeCapabilities
                                ? launchServices.capableApplications(forURLScheme: scheme) : [])
        }

        let extensions = category.extensions(includingOptional: includingOptional)
        let resolved = extensions.flatMap { ext in
            candidateFileTypes(forExtensions: [ext]).map { (ext, $0) }
        }
        var order: [String] = []
        var typeByIdentifier: [String: FileTypeInfo] = [:]
        var labelsByIdentifier: [String: [String]] = [:]
        for (ext, type) in resolved {
            if typeByIdentifier[type.contentTypeIdentifier] == nil { order.append(type.contentTypeIdentifier) }
            typeByIdentifier[type.contentTypeIdentifier] = type
            labelsByIdentifier[type.contentTypeIdentifier, default: []].append("." + ext)
        }
        targets += order.compactMap { identifier in
            guard let type = typeByIdentifier[identifier] else { return nil }
            return DefaultAppTarget(key: "type:\(identifier)",
                                    label: labelsByIdentifier[identifier, default: []].joined(separator: "/"),
                                    kind: .fileType(type),
                                    defaultApplication: launchServices.defaultApplication(for: type),
                                    capableApplications: includeCapabilities
                                        ? launchServices.capableApplications(for: type) : [])
        }
        return targets
    }

    private func defaultAppDisplayTargets(for category: DefaultAppCategory,
                                          includingOptional: Bool) -> [DefaultAppTarget] {
        defaultAppTargets(for: category, includingOptional: includingOptional,
                          includeCapabilities: false)
    }

    private func applicationSupports(_ application: ApplicationInfo, target: DefaultAppTarget) -> Bool {
        switch target.kind {
        case .urlScheme(let scheme):
            applicationSupports(application, urlScheme: scheme)
        case .fileType(let type):
            applicationSupports(application, fileType: type)
        }
    }

    private func candidateTypeDetail(_ target: DefaultAppTarget,
                                     application: ApplicationInfo,
                                     category: DefaultAppCategory) -> DefaultAppCandidateTypeDetail {
        let typeName: String
        let identifier: String
        let canCustomizeScope: Bool
        let isAutomaticallyManaged: Bool
        switch target.kind {
        case .urlScheme(let scheme):
            typeName = L10n.string("网页链接")
            identifier = scheme.lowercased()
            canCustomizeScope = false
            isAutomaticallyManaged = true
        case .fileType(let type):
            typeName = type.specificDisplayName
            identifier = type.contentTypeIdentifier
            canCustomizeScope = true
            isAutomaticallyManaged = isAutomaticallyManagedDefaultAppType(identifier, for: category)
        }
        let scopePolicy = defaultAppTypeScopePolicy(identifier, for: category)
        return DefaultAppCandidateTypeDetail(
            id: target.key,
            label: target.label,
            typeName: typeName,
            technicalIdentifier: identifier,
            isSupported: applicationSupports(application, target: target),
            isCurrentDefault: target.defaultApplication?.bundleIdentifier == application.bundleIdentifier,
            canCustomizeScope: canCustomizeScope,
            scopePolicy: scopePolicy,
            isAutomaticallyManaged: isAutomaticallyManaged,
            isManaged: !canCustomizeScope || isDefaultAppTypeManaged(identifier, for: category)
        )
    }

    func setDefaultAppType(_ identifier: String, scopePolicy: DefaultAppTypeScopePolicy,
                           for category: DefaultAppCategory) {
        switch scopePolicy {
        case .automatic:
            ignoredDefaultAppTypesByCategory[category.id]?.remove(identifier)
            includedDefaultAppTypesByCategory[category.id]?.remove(identifier)
        case .included:
            ignoredDefaultAppTypesByCategory[category.id]?.remove(identifier)
            includedDefaultAppTypesByCategory[category.id, default: []].insert(identifier)
        case .excluded:
            includedDefaultAppTypesByCategory[category.id]?.remove(identifier)
            ignoredDefaultAppTypesByCategory[category.id, default: []].insert(identifier)
        }
        if ignoredDefaultAppTypesByCategory[category.id]?.isEmpty == true {
            ignoredDefaultAppTypesByCategory.removeValue(forKey: category.id)
        }
        if includedDefaultAppTypesByCategory[category.id]?.isEmpty == true {
            includedDefaultAppTypesByCategory.removeValue(forKey: category.id)
        }
        persistIgnoredDefaultAppTypes()
        persistIncludedDefaultAppTypes()
        removeOptimisticDefaultAppStatuses(for: category)
        defaultAppRevision += 1
    }

    private func managedDefaultAppTargets(_ targets: [DefaultAppTarget],
                                          for category: DefaultAppCategory) -> [DefaultAppTarget] {
        targets.filter { isDefaultAppTargetManaged($0, for: category) }
    }

    private func ignoredTypeCount(in targets: [DefaultAppTarget],
                                  for category: DefaultAppCategory) -> Int {
        targets.filter { isDefaultAppTargetIgnored($0, for: category) }.count
    }

    private func isDefaultAppTargetManaged(_ target: DefaultAppTarget,
                                           for category: DefaultAppCategory) -> Bool {
        guard case .fileType(let type) = target.kind else { return true }
        return isDefaultAppTypeManaged(type.contentTypeIdentifier, for: category)
    }

    private func isDefaultAppTargetIgnored(_ target: DefaultAppTarget,
                                           for category: DefaultAppCategory) -> Bool {
        guard case .fileType(let type) = target.kind else { return false }
        return isDefaultAppTypeIgnored(type.contentTypeIdentifier, for: category)
    }

    private func isDefaultAppTypeIgnored(_ identifier: String,
                                         for category: DefaultAppCategory) -> Bool {
        ignoredDefaultAppTypesByCategory[category.id]?.contains(identifier) == true
    }

    private func defaultAppTypeScopePolicy(_ identifier: String,
                                           for category: DefaultAppCategory) -> DefaultAppTypeScopePolicy {
        if isDefaultAppTypeIgnored(identifier, for: category) { return .excluded }
        if includedDefaultAppTypesByCategory[category.id]?.contains(identifier) == true {
            return .included
        }
        return .automatic
    }

    private func isDefaultAppTypeManaged(_ identifier: String,
                                         for category: DefaultAppCategory) -> Bool {
        switch defaultAppTypeScopePolicy(identifier, for: category) {
        case .included: return true
        case .excluded: return false
        case .automatic: return isAutomaticallyManagedDefaultAppType(identifier, for: category)
        }
    }

    private func isAutomaticallyManagedDefaultAppType(_ identifier: String,
                                                       for category: DefaultAppCategory) -> Bool {
        category.extensions(includingOptional: true).contains { extensionName in
            (try? launchServices.fileType(for: extensionName))?.contentTypeIdentifier == identifier
        }
    }

    private func applicationSupports(_ application: ApplicationInfo, urlScheme: String) -> Bool {
        if launchServices.capableApplications(forURLScheme: urlScheme)
            .contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) {
            return true
        }
        return scanner.supportedURLSchemes(at: application.url).contains(urlScheme.lowercased())
    }

    private func applicationSupports(_ application: ApplicationInfo, fileType: FileTypeInfo) -> Bool {
        if launchServices.capableBundleIdentifiers(forContentType: fileType.contentTypeIdentifier)
            .contains(application.bundleIdentifier) {
            return true
        }
        guard let requestedType = UTType(fileType.contentTypeIdentifier) else { return false }
        return application.supportedTypes.contains { supported in
            guard let declaredType = UTType(supported.contentTypeIdentifier) else { return false }
            return requestedType == declaredType || requestedType.conforms(to: declaredType)
        }
    }

    private func defaultAppStatusKey(for category: DefaultAppCategory,
                                     includingOptional: Bool) -> String {
        "\(category.id)|\(includingOptional ? "all" : "core")"
    }

    private func removeOptimisticDefaultAppStatuses(for category: DefaultAppCategory) {
        let prefix = category.id + "|"
        optimisticDefaultAppStatuses = optimisticDefaultAppStatuses.filter {
            !$0.key.hasPrefix(prefix)
        }
    }

    private func verifyDefaultAppStatus(_ application: ApplicationInfo,
                                        for category: DefaultAppCategory,
                                        includingOptional: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let statusKey = self.defaultAppStatusKey(for: category, includingOptional: includingOptional)
            for delay in [350, 900, 1_800] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard self.optimisticDefaultAppStatuses[statusKey]?
                    .unifiedApplication?.bundleIdentifier == application.bundleIdentifier else { return }
                let status = self.systemDefaultAppStatus(for: category, includingOptional: includingOptional)
                if status.unifiedApplication?.bundleIdentifier == application.bundleIdentifier {
                    self.optimisticDefaultAppStatuses.removeValue(forKey: statusKey)
                    self.defaultAppRevision += 1
                    return
                }
            }
            self.optimisticDefaultAppStatuses.removeValue(forKey: statusKey)
            self.defaultAppRevision += 1
            let finalStatus = self.systemDefaultAppStatus(for: category, includingOptional: includingOptional)
            if finalStatus.unifiedApplication?.bundleIdentifier != application.bundleIdentifier {
                self.errorMessage = L10n.format("error.unifiedUpdateFailed", category.title)
            }
        }
    }

    private static let protectedContentTypeIdentifiers: Set<String> = [
        "public.item", "public.content", "public.data", "public.composite-content"
    ]

    private static let broadContentTypeIdentifiers: Set<String> = [
        "public.text", "public.image", "public.audio", "public.movie",
        "public.audiovisual-content", "public.archive"
    ]
}

struct FileTypeSearchResult {
    let type: FileTypeInfo
    let rank: FileTypeSearchRank?
}

enum FileTypeSearchRank: Int, Comparable {
    case extensionExact
    case extensionPrefix
    case displayName
    case contentTypeIdentifier
    case unregistered

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func match(type: FileTypeInfo, query: String,
                      extensionQuery: String,
                      requiresExactExtension: Bool,
                      includesDisplayName: Bool,
                      includesContentTypeIdentifier: Bool) -> FileTypeSearchRank? {
        let normalizedExtension = folded(type.extensionName)
        let normalizedExtensionQuery = folded(extensionQuery)
        if !normalizedExtensionQuery.isEmpty {
            if normalizedExtension == normalizedExtensionQuery { return .extensionExact }
            if !requiresExactExtension,
               normalizedExtension.hasPrefix(normalizedExtensionQuery) { return .extensionPrefix }
        }

        let normalizedQuery = folded(query)
        if includesDisplayName,
           matchesWords(normalizedQuery, in: folded(type.displayName)) { return .displayName }

        if includesContentTypeIdentifier {
            let identifier = folded(type.contentTypeIdentifier)
            if normalizedQuery.contains(".") {
                if identifier == normalizedQuery || identifier.hasPrefix(normalizedQuery) {
                    return .contentTypeIdentifier
                }
            } else if identifierComponents(identifier).contains(where: { $0.hasPrefix(normalizedQuery) }) {
                return .contentTypeIdentifier
            }
        }
        return nil
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func matchesWords(_ query: String, in value: String) -> Bool {
        guard !query.isEmpty else { return false }
        if value == query || value.hasPrefix(query) { return true }
        if query.unicodeScalars.contains(where: { !$0.isASCII }) { return value.contains(query) }
        return value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains(where: { !$0.isEmpty && $0.hasPrefix(query) })
    }

    private static func identifierComponents(_ identifier: String) -> [String] {
        identifier.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

private struct DefaultAppTarget {
    let key: String
    let label: String
    let kind: DefaultAppTargetKind
    let defaultApplication: ApplicationInfo?
    let capableApplications: [ApplicationInfo]
}

private enum DefaultAppTargetKind {
    case urlScheme(String)
    case fileType(FileTypeInfo)
}

private enum DefaultChangeOperation {
    case scheme(String, String)
    case fileType(FileTypeInfo)

    var label: String {
        switch self {
        case .scheme(_, let label): label
        case .fileType(let type): type.dottedExtension
        }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Sequence {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
