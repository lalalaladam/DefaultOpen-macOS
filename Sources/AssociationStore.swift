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
    private let starterExtensions = ["pdf", "txt", "md", "jpg", "png", "heic", "svg", "zip", "json", "csv", "docx", "xlsx", "pptx", "html", "mp3", "mp4"]
    private var optimisticDefaultAppStatuses: [String: DefaultAppCategoryStatus] = [:]
    private var queriedApplicationExtensions = Set<String>()
    private var queriedDefaultContentTypes = Set<String>()
    private var lastActivationDefaults: [String: ApplicationInfo?]?

    init() {
        customDefaultAppCategories = Self.loadCustomDefaultAppCategories()
        let saved = customExtensionNames
        fileTypes = (starterExtensions + saved).uniqued().flatMap { (try? launchServices.fileTypes(for: $0)) ?? [] }
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
            guard let types = try? launchServices.fileTypes(for: $0) else { return true }
            return types.isEmpty
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
        removeOptimisticDefaultAppStatuses(for: category)
        defaultAppRevision += 1
        return true
    }

    func recognizedExtensions(_ extensions: [String]) -> [String] {
        extensions.filter {
            guard let types = try? launchServices.fileTypes(for: $0) else { return false }
            return !types.isEmpty
        }
    }

    func extensionTypeScope(for extensionName: String) -> ExtensionTypeScope {
        let allTypes = (try? launchServices.fileTypes(for: extensionName)) ?? []
        let includedTypes = (try? launchServices.fileTypeFamily(for: extensionName)) ?? []
        let includedIdentifiers = Set(includedTypes.map(\.contentTypeIdentifier))
        return ExtensionTypeScope(
            extensionName: extensionName.lowercased(),
            includedTypeCount: includedTypes.count,
            independentTypeCount: allTypes.filter {
                !includedIdentifiers.contains($0.contentTypeIdentifier)
            }.count
        )
    }

    func removeCustomDefaultAppCategory(_ category: DefaultAppCategory) {
        guard category.isCustom else { return }
        customDefaultAppCategories.removeAll { $0.id == category.id }
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
              !queriedApplicationExtensions.contains(extensionName),
              let matchingTypes = try? launchServices.fileTypes(for: extensionName),
              !matchingTypes.isEmpty else { return }

        queriedApplicationExtensions.insert(extensionName)
        let scanner = self.scanner
        let discovered = await Task.detached(priority: .userInitiated) {
            matchingTypes.flatMap { scanner.applicationsCapable(of: $0) }
        }.value
        guard !discovered.isEmpty else { return }
        mergeApplications(discovered)
        mergeIntoFileTypeCatalog(matchingTypes)
        for type in matchingTypes {
            if let defaultApplication = launchServices.defaultApplication(for: type) {
                defaultsByContentType[type.contentTypeIdentifier] = defaultApplication
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
              let matchingTypes = try? launchServices.fileTypes(for: extensionName),
              !matchingTypes.isEmpty else { return }

        let typesToQuery = matchingTypes.filter {
            defaultsByContentType[$0.contentTypeIdentifier] == nil
                && !queriedDefaultContentTypes.contains($0.contentTypeIdentifier)
        }
        guard !typesToQuery.isEmpty else { return }
        queriedDefaultContentTypes.formUnion(typesToQuery.map(\.contentTypeIdentifier))
        let launchServices = self.launchServices
        let results = await Task.detached(priority: .userInitiated) {
            typesToQuery.map { ($0, launchServices.defaultApplication(for: $0)) }
        }.value
        for (type, defaultApplication) in results {
            if let defaultApplication {
                defaultsByContentType[type.contentTypeIdentifier] = defaultApplication
            }
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
            let types = try launchServices.fileTypes(for: value)
            guard let type = types.first else { throw AssociationError.invalidExtension(value) }
            let isKnownExtension = allFileTypes.contains {
                $0.extensionName.caseInsensitiveCompare(type.extensionName) == .orderedSame
            }
            let newTypes = types.filter { candidate in
                !fileTypes.contains(where: { $0.id == candidate.id })
            }
            if !newTypes.isEmpty {
                fileTypes.append(contentsOf: newTypes)
                fileTypes.sort { $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending }
            }
            mergeIntoFileTypeCatalog(types)
            if !isKnownExtension && !starterExtensions.contains(type.extensionName.lowercased()) {
                var custom = customExtensionNames
                if !custom.contains(type.extensionName.lowercased()) {
                    custom.append(type.extensionName.lowercased())
                    persistCustomExtensions(custom)
                }
            }
            refreshDefaults(for: types)
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

    func capableApplications(for type: FileTypeInfo) -> [ApplicationInfo] {
        launchServices.capableApplications(for: type)
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
        let coreTargets = defaultAppDisplayTargets(for: category, includingOptional: false)
        let targets = defaultAppDisplayTargets(for: category, includingOptional: includingOptional)
        let unsupportedCore = coreTargets.filter { !applicationSupports(application, target: $0) }
        guard unsupportedCore.isEmpty else {
            throw AssociationError.incompatibleApplication(application.name, unsupportedCore.map(\.label))
        }

        let supported = targets.filter { applicationSupports(application, target: $0) }
        let unsupported = targets.filter { !applicationSupports(application, target: $0) }
        return DefaultAppCandidate(
            application: application,
            supportedCount: uniqueTargetCount(supported),
            totalCount: uniqueTargetCount(targets),
            supportedTargets: summarizedTargetLabels(supported),
            unsupportedTargets: summarizedTargetLabels(unsupported),
            currentTargets: summarizedTargetLabels(targets.filter {
                $0.defaultApplication?.bundleIdentifier == application.bundleIdentifier
            }),
            currentCount: uniqueTargetCount(targets.filter {
                $0.defaultApplication?.bundleIdentifier == application.bundleIdentifier
            }),
            isCurrentDefault: targets.allSatisfy {
                $0.defaultApplication?.bundleIdentifier == application.bundleIdentifier
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
        return defaultAppStatus(
            from: targets,
            formats: defaultAppFormatStatuses(for: optionalCategory, includingOptional: false)
        )
    }

    private func systemDefaultAppStatus(for category: DefaultAppCategory,
                                        includingOptional: Bool) -> DefaultAppCategoryStatus {
        let targets = defaultAppTargets(for: category, includingOptional: includingOptional,
                                        includeCapabilities: false)
        return defaultAppStatus(
            from: targets,
            formats: defaultAppFormatStatuses(for: category, includingOptional: includingOptional)
        )
    }

    private func defaultAppStatus(from targets: [DefaultAppTarget],
                                  formats: [DefaultAppFormatStatus] = []) -> DefaultAppCategoryStatus {
        let missingTargets = targets.filter { $0.defaultApplication == nil }.map(\.label)
        let assignedTargets = targets.compactMap { target -> (ApplicationInfo, String)? in
            guard let app = target.defaultApplication else { return nil }
            return (app, target.label)
        }
        let assignments = Dictionary(grouping: assignedTargets, by: { $0.0.bundleIdentifier }).values
            .compactMap { values -> DefaultAppAssignment? in
                guard let app = values.first?.0 else { return nil }
                return DefaultAppAssignment(application: app, targets: values.map(\.1))
            }
            .sorted { $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending }
        let unified = missingTargets.isEmpty && assignments.count == 1 ? assignments.first?.application : nil
        return DefaultAppCategoryStatus(unifiedApplication: unified,
                                        assignments: assignments,
                                        missingTargets: missingTargets,
                                        formats: formats)
    }

    func defaultAppCandidates(for category: DefaultAppCategory,
                              includingOptional: Bool) -> [DefaultAppCandidate] {
        let coreTargets = defaultAppTargets(for: category, includingOptional: false, includeCapabilities: false)
        let targets = defaultAppTargets(for: category, includingOptional: includingOptional)
        var appsByID: [String: ApplicationInfo] = [:]

        for target in targets {
            for app in target.capableApplications {
                appsByID[app.bundleIdentifier] = app
            }
        }

        let displayCoreTargets = defaultAppDisplayTargets(for: category, includingOptional: false)
        let displayTargets = defaultAppDisplayTargets(for: category, includingOptional: includingOptional)
        return appsByID.values.compactMap { app in
            guard coreTargets.allSatisfy({ applicationSupports(app, target: $0) }) else { return nil }
            guard displayCoreTargets.allSatisfy({ applicationSupports(app, target: $0) }) else { return nil }
            let supportedTargets = displayTargets.filter { applicationSupports(app, target: $0) }
            let isCurrentDefault = displayTargets.allSatisfy {
                $0.defaultApplication?.bundleIdentifier == app.bundleIdentifier
            }
            return DefaultAppCandidate(application: app,
                                       supportedCount: uniqueTargetCount(supportedTargets),
                                       totalCount: uniqueTargetCount(displayTargets),
                                       supportedTargets: summarizedTargetLabels(supportedTargets),
                                       unsupportedTargets: summarizedTargetLabels(displayTargets.filter {
                                           !applicationSupports(app, target: $0)
                                       }),
                                       currentTargets: summarizedTargetLabels(displayTargets.filter {
                                           $0.defaultApplication?.bundleIdentifier == app.bundleIdentifier
                                       }),
                                       currentCount: uniqueTargetCount(displayTargets.filter {
                                           $0.defaultApplication?.bundleIdentifier == app.bundleIdentifier
                                       }),
                                       isCurrentDefault: isCurrentDefault)
        }.sorted {
            if $0.supportedCount != $1.supportedCount { return $0.supportedCount > $1.supportedCount }
            return $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
        }
    }

    func setDefault(_ application: ApplicationInfo, for category: DefaultAppCategory,
                    includingOptional: Bool,
                    progress: (Int, Int, String) -> Void) async -> DefaultAppChangeResult? {
        do {
            let unsupportedCore = defaultAppTargets(for: category, includingOptional: false,
                                                    includeCapabilities: false)
                .filter { !applicationSupports(application, target: $0) }
            guard unsupportedCore.isEmpty else {
                errorMessage = AssociationError.incompatibleApplication(
                    application.name,
                    unsupportedCore.map(\.label)
                ).localizedDescription
                return nil
            }

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

            for type in resolvedFileTypes(for: category, includingOptional: includingOptional) {
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
                                                   includeCapabilities: false).map(\.label)
            if skippedTargets.isEmpty {
                optimisticDefaultAppStatuses[statusKey] = DefaultAppCategoryStatus(
                    unifiedApplication: application,
                    assignments: [DefaultAppAssignment(application: application, targets: selectedLabels)],
                    missingTargets: [],
                    formats: defaultAppFormatStatuses(
                        for: category,
                        includingOptional: includingOptional,
                        overridingWith: application
                    )
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
                                          skippedTargets: skippedTargets,
                                          unchangedTargets: unchangedTargets)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func setDefault(_ application: ApplicationInfo, for types: [FileTypeInfo]) async -> Bool {
        do {
            let uniqueTypes = Dictionary(grouping: types, by: \FileTypeInfo.contentTypeIdentifier)
                .compactMap(\.value.first)
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
        let types = Dictionary(grouping: fileTypes + allFileTypes, by: \.contentTypeIdentifier)
            .compactMap(\.value.first)
        let launchServices = self.launchServices
        let refreshed = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: types.map { type in
                (type.contentTypeIdentifier, launchServices.defaultApplication(for: type))
            })
        }.value
        defer { lastActivationDefaults = refreshed }
        guard let previous = lastActivationDefaults else { return }
        guard defaultsFingerprint(previous) != defaultsFingerprint(refreshed) else { return }
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

    private func defaultsFingerprint(_ values: [String: ApplicationInfo?]) -> [String: String] {
        values.reduce(into: [:]) { result, item in
            result[item.key] = item.value?.bundleIdentifier ?? ""
        }
    }

    func fileTypes(for supportedType: SupportedType) -> [FileTypeInfo] {
        let extensions = supportedType.extensions
        if extensions.isEmpty,
           let fallback = fileTypes.first(where: { $0.contentTypeIdentifier == supportedType.contentTypeIdentifier }) {
            return [fallback]
        }
        return supportedType.fileTypes
    }

    func matchingFileTypes(for searchText: String, includeAll: Bool) -> [FileTypeSearchResult] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let source = includeAll ? allFileTypes : fileTypes.filter { !isCustomFileType($0) }
            return source.map { FileTypeSearchResult(type: $0, rank: nil) }
        }

        let source = allFileTypes
        let extensionQuery = query.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var matches = source.compactMap { type -> FileTypeSearchResult? in
            guard let rank = FileTypeSearchRank.match(type: type, query: query,
                                                      extensionQuery: extensionQuery) else { return nil }
            return FileTypeSearchResult(type: type, rank: rank)
        }
        if hasLoadedAllFileTypes,
           let exactTypes = try? launchServices.fileTypes(for: extensionQuery) {
            matches.append(contentsOf: exactTypes.compactMap { exactType in
                guard !matches.contains(where: { $0.type.id == exactType.id }) else { return nil }
                return FileTypeSearchResult(type: exactType, rank: .unregistered)
            })
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
                                     extensionQuery: extensionQuery) != nil
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

    private func mergeIntoFileTypeCatalog(_ types: [FileTypeInfo]) {
        allFileTypes = Dictionary(grouping: allFileTypes + types, by: \FileTypeInfo.id)
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
        let types = category.extensions(includingOptional: includingOptional)
            .flatMap { (try? launchServices.fileTypeFamily(for: $0)) ?? [] }
        return Dictionary(grouping: types, by: \FileTypeInfo.contentTypeIdentifier).compactMap(\.value.first)
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
        let resolved = extensions.flatMap { ext -> [(String, FileTypeInfo)] in
            ((try? launchServices.fileTypeFamily(for: ext)) ?? []).map { (ext, $0) }
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
        let schemeTargets = category.urlSchemes.map { scheme in
            DefaultAppTarget(
                key: "scheme:\(scheme)",
                label: scheme.uppercased(),
                kind: .urlScheme(scheme),
                defaultApplication: launchServices.defaultApplication(forURLScheme: scheme),
                capableApplications: []
            )
        }
        let fileTargets = category.extensions(includingOptional: includingOptional)
            .flatMap { ext -> [DefaultAppTarget] in
                ((try? launchServices.fileTypeFamily(for: ext)) ?? []).map { type in
                    DefaultAppTarget(
                        key: "type:\(type.contentTypeIdentifier)",
                        label: "." + ext,
                        kind: .fileType(type),
                        defaultApplication: launchServices.defaultApplication(for: type),
                        capableApplications: []
                    )
                }
            }
        return schemeTargets + fileTargets
    }

    private func summarizedTargetLabels(_ targets: [DefaultAppTarget]) -> [String] {
        var schemeLabels: [String] = []
        var entries: [(labels: [String], keys: Set<String>)] = []
        for target in targets {
            if target.key.hasPrefix("scheme:") {
                if !schemeLabels.contains(target.label) { schemeLabels.append(target.label) }
                continue
            }
            let matching = entries.indices.filter {
                entries[$0].keys.contains(target.key) || entries[$0].labels.contains(target.label)
            }
            if let first = matching.first {
                var mergedLabels = entries[first].labels
                var mergedKeys = entries[first].keys
                for index in matching.dropFirst().reversed() {
                    mergedLabels.append(contentsOf: entries[index].labels)
                    mergedKeys.formUnion(entries[index].keys)
                    entries.remove(at: index)
                }
                mergedLabels.append(target.label)
                mergedKeys.insert(target.key)
                entries[first] = (mergedLabels.uniqued(), mergedKeys)
            } else {
                entries.append(([target.label], [target.key]))
            }
        }
        return schemeLabels + entries.map { entry in
            let label = entry.labels.joined(separator: "/")
            return entry.keys.count > 1
                ? L10n.format("status.formatTypeCount", label, entry.keys.count) : label
        }
    }

    private func uniqueTargetCount(_ targets: [DefaultAppTarget]) -> Int {
        Set(targets.map(\.key)).count
    }

    private func defaultAppFormatStatuses(for category: DefaultAppCategory,
                                          includingOptional: Bool,
                                          overridingWith application: ApplicationInfo? = nil)
        -> [DefaultAppFormatStatus] {
        var result = category.urlSchemes.map { scheme in
            let current = application ?? launchServices.defaultApplication(forURLScheme: scheme)
            return DefaultAppFormatStatus(
                id: "scheme:\(scheme)",
                label: scheme.uppercased(),
                typeCount: 1,
                assignments: current.map {
                    [DefaultAppFormatAssignment(application: $0, typeCount: 1)]
                } ?? [],
                missingCount: current == nil ? 1 : 0
            )
        }

        let entries = category.extensions(includingOptional: includingOptional).map { extensionName in
            DefaultAppFormatEntry(
                extensions: [extensionName],
                types: (try? launchServices.fileTypeFamily(for: extensionName)) ?? []
            )
        }.filter { !$0.types.isEmpty }

        var groups: [DefaultAppFormatEntry] = []
        for entry in entries {
            let entryIdentifiers = Set(entry.types.map(\.contentTypeIdentifier))
            let overlapping = groups.indices.filter { index in
                !entryIdentifiers.isDisjoint(with: Set(groups[index].types.map(\.contentTypeIdentifier)))
            }
            guard let firstIndex = overlapping.first else {
                groups.append(entry)
                continue
            }
            var merged = groups[firstIndex]
            for index in overlapping.reversed() where index != firstIndex {
                merged.extensions.append(contentsOf: groups[index].extensions)
                merged.types.append(contentsOf: groups[index].types)
                groups.remove(at: index)
            }
            merged.extensions.append(contentsOf: entry.extensions)
            merged.types.append(contentsOf: entry.types)
            merged.extensions = merged.extensions.uniqued()
            merged.types = Dictionary(grouping: merged.types, by: \.contentTypeIdentifier)
                .compactMap(\.value.first)
            groups[firstIndex] = merged
        }

        result += groups.map { group in
            let assignments = group.types.compactMap { type -> ApplicationInfo? in
                application ?? launchServices.defaultApplication(for: type)
            }
            let assignmentGroups = Dictionary(grouping: assignments, by: \.bundleIdentifier)
            let formatAssignments = assignmentGroups.values.compactMap { apps -> DefaultAppFormatAssignment? in
                guard let app = apps.first else { return nil }
                return DefaultAppFormatAssignment(application: app, typeCount: apps.count)
            }.sorted {
                if $0.typeCount != $1.typeCount { return $0.typeCount > $1.typeCount }
                return $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
            }
            return DefaultAppFormatStatus(
                id: "extension:" + group.extensions.joined(separator: ","),
                label: group.extensions.map { $0.uppercased() }.joined(separator: "/"),
                typeCount: group.types.count,
                assignments: formatAssignments,
                missingCount: group.types.count - assignments.count
            )
        }
        return result
    }

    private func applicationSupports(_ application: ApplicationInfo, target: DefaultAppTarget) -> Bool {
        switch target.kind {
        case .urlScheme(let scheme):
            applicationSupports(application, urlScheme: scheme)
        case .fileType(let type):
            applicationSupports(application, fileType: type)
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
                      extensionQuery: String) -> FileTypeSearchRank? {
        let normalizedExtension = folded(type.extensionName)
        let normalizedExtensionQuery = folded(extensionQuery)
        if !normalizedExtensionQuery.isEmpty {
            if normalizedExtension == normalizedExtensionQuery { return .extensionExact }
            if normalizedExtension.hasPrefix(normalizedExtensionQuery) { return .extensionPrefix }
        }

        let normalizedQuery = folded(query)
        if matchesWords(normalizedQuery, in: folded(type.displayName)) { return .displayName }

        let identifier = folded(type.contentTypeIdentifier)
        if normalizedQuery.contains(".") {
            if identifier == normalizedQuery || identifier.hasPrefix(normalizedQuery) {
                return .contentTypeIdentifier
            }
        } else if identifierComponents(identifier).contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return .contentTypeIdentifier
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

private struct DefaultAppFormatEntry {
    var extensions: [String]
    var types: [FileTypeInfo]
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
