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

    init() {
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
        guard !normalizedExtensions.isEmpty else {
            errorMessage = L10n.string("请至少添加一个文件扩展名。")
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
            subtitle: normalizedSubtitle.isEmpty
                ? normalizedExtensions.map { "." + $0 }.joined(separator: L10n.string("list.separator"))
                : normalizedSubtitle,
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
        optimisticDefaultAppStatuses.removeValue(forKey: category.id)
        defaultAppRevision += 1
        return true
    }

    func removeCustomDefaultAppCategory(_ category: DefaultAppCategory) {
        guard category.isCustom else { return }
        customDefaultAppCategories.removeAll { $0.id == category.id }
        optimisticDefaultAppStatuses.removeValue(forKey: category.id)
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
            let discoveredTypes = apps.flatMap(\.supportedTypes).flatMap { type -> [FileTypeInfo] in
                type.extensions.compactMap { try? launchServices.fileType(for: $0) }
            }
            var defaults: [String: ApplicationInfo] = [:]
            for type in Dictionary(grouping: managedTypes + discoveredTypes,
                                   by: \FileTypeInfo.contentTypeIdentifier).compactMap(\.value.first) {
                defaults[type.contentTypeIdentifier] = launchServices.defaultApplication(for: type)
            }
            return (apps, defaults)
        }.value
        applications = result.0
        mergeIntoFileTypeCatalog(result.0.flatMap(\.supportedTypes).flatMap { supportedType in
            supportedType.extensions.compactMap { try? launchServices.fileType(for: $0) }
        })
        defaultsByContentType.merge(result.1) { _, new in new }
        isScanning = false
    }

    func loadAllFileTypes() async {
        guard !isLoadingFileTypes, !hasLoadedAllFileTypes else { return }
        isLoadingFileTypes = true
        defer { isLoadingFileTypes = false }
        let scanner = self.scanner
        let launchServices = self.launchServices
        let discoveredTypes = await Task.detached(priority: .userInitiated) {
            scanner.scanDeclaredFileTypes().flatMap { supportedType in
                supportedType.extensions.compactMap { try? launchServices.fileType(for: $0) }
            }
        }.value
        mergeIntoFileTypeCatalog(discoveredTypes)
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

    func removeCustomExtension(_ type: FileTypeInfo) {
        let extensionName = type.extensionName.lowercased()
        guard customExtensionNames.contains(extensionName) else { return }
        persistCustomExtensions(customExtensionNames.filter { $0 != extensionName })
        fileTypes.removeAll { $0.extensionName.lowercased() == extensionName }
        allFileTypes.removeAll { $0.extensionName.lowercased() == extensionName }
        defaultsByContentType.removeValue(forKey: type.contentTypeIdentifier)
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
        let coreTargets = defaultAppTargets(for: category, includingOptional: false,
                                            includeCapabilities: false)
        let targets = defaultAppTargets(for: category, includingOptional: includingOptional,
                                        includeCapabilities: false)
        let unsupportedCore = coreTargets.filter { !applicationSupports(application, target: $0) }
        guard unsupportedCore.isEmpty else {
            throw AssociationError.incompatibleApplication(application.name, unsupportedCore.map(\.label))
        }

        let supported = targets.filter { applicationSupports(application, target: $0) }
        let unsupported = targets.filter { !applicationSupports(application, target: $0) }
        let currentTargets = targets.filter {
            $0.defaultApplication?.bundleIdentifier == application.bundleIdentifier
        }.map(\.label)
        return DefaultAppCandidate(
            application: application,
            supportedCount: supported.count,
            totalCount: targets.count,
            supportedTargets: supported.map(\.label),
            unsupportedTargets: unsupported.map(\.label),
            currentTargets: currentTargets,
            isCurrentDefault: coreTargets.allSatisfy {
                $0.defaultApplication?.bundleIdentifier == application.bundleIdentifier
            }
        )
    }

    func defaultAppStatus(for category: DefaultAppCategory) -> DefaultAppCategoryStatus {
        _ = defaultAppRevision
        if let optimistic = optimisticDefaultAppStatuses[category.id] { return optimistic }
        return systemDefaultAppStatus(for: category)
    }

    private func systemDefaultAppStatus(for category: DefaultAppCategory) -> DefaultAppCategoryStatus {
        let targets = defaultAppTargets(for: category, includingOptional: false, includeCapabilities: false)
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
                                        missingTargets: missingTargets)
    }

    func defaultAppCandidates(for category: DefaultAppCategory,
                              includingOptional: Bool) -> [DefaultAppCandidate] {
        let coreTargets = defaultAppTargets(for: category, includingOptional: false, includeCapabilities: false)
        let targets = defaultAppTargets(for: category, includingOptional: includingOptional)
        let requiredKeys = Set(coreTargets.map(\.key))
        var appsByID: [String: ApplicationInfo] = [:]
        var coverage: [String: Set<String>] = [:]

        for target in targets {
            for app in target.capableApplications {
                appsByID[app.bundleIdentifier] = app
                coverage[app.bundleIdentifier, default: []].insert(target.key)
            }
        }

        return appsByID.values.compactMap { app in
            let coveredKeys = coverage[app.bundleIdentifier, default: []]
            guard coveredKeys.isSuperset(of: requiredKeys) else { return nil }
            let currentTargets = targets.filter {
                $0.defaultApplication?.bundleIdentifier == app.bundleIdentifier
            }.map(\.label)
            let isCurrentDefault = coreTargets.allSatisfy {
                $0.defaultApplication?.bundleIdentifier == app.bundleIdentifier
            }
            return DefaultAppCandidate(application: app,
                                       supportedCount: coveredKeys.count,
                                       totalCount: targets.count,
                                       supportedTargets: targets.filter { coveredKeys.contains($0.key) }.map(\.label),
                                       unsupportedTargets: targets.filter { !coveredKeys.contains($0.key) }.map(\.label),
                                       currentTargets: currentTargets,
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
            let coreLabels = defaultAppTargets(for: category, includingOptional: false,
                                               includeCapabilities: false).map(\.label)
            optimisticDefaultAppStatuses[category.id] = DefaultAppCategoryStatus(
                unifiedApplication: application,
                assignments: [DefaultAppAssignment(application: application, targets: coreLabels)],
                missingTargets: []
            )
            defaultAppRevision += 1
            successMessage = changedTargets.isEmpty
                ? L10n.format("success.alreadyCategoryDefault", application.name, category.title)
                : L10n.format("success.setCategoryDefault", application.name, category.title)
            if !changedTargets.isEmpty { verifyDefaultAppStatus(application, for: category) }
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

    func fileTypes(for supportedType: SupportedType) -> [FileTypeInfo] {
        let extensions = supportedType.extensions
        if extensions.isEmpty,
           let fallback = fileTypes.first(where: { $0.contentTypeIdentifier == supportedType.contentTypeIdentifier }) {
            return [fallback]
        }
        return extensions.compactMap { try? launchServices.fileType(for: $0) }
    }

    func matchingFileTypes(for searchText: String, includeAll: Bool) -> [FileTypeInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = includeAll ? allFileTypes : fileTypes.filter { !isCustomFileType($0) }
        guard !query.isEmpty else { return source }

        let extensionQuery = query.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var matches = source.filter {
            $0.extensionName.localizedCaseInsensitiveContains(extensionQuery)
            || $0.displayName.localizedCaseInsensitiveContains(query)
            || $0.contentTypeIdentifier.localizedCaseInsensitiveContains(query)
        }
        if let exactType = try? launchServices.fileType(for: extensionQuery),
           !matches.contains(where: { $0.id == exactType.id }) {
            matches.append(exactType)
        }
        return matches
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

    private func resolvedFileTypes(for category: DefaultAppCategory,
                                   includingOptional: Bool) -> [FileTypeInfo] {
        let types = category.extensions(includingOptional: includingOptional)
            .compactMap { try? launchServices.fileType(for: $0) }
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
        let resolved = extensions.compactMap { ext -> (String, FileTypeInfo)? in
            guard let type = try? launchServices.fileType(for: ext) else { return nil }
            return (ext, type)
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
            if supported.extensions.contains(fileType.extensionName.lowercased()) { return true }
            guard let declaredType = UTType(supported.contentTypeIdentifier) else { return false }
            return requestedType == declaredType || requestedType.conforms(to: declaredType)
        }
    }

    private func verifyDefaultAppStatus(_ application: ApplicationInfo,
                                        for category: DefaultAppCategory) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [350, 900, 1_800] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard self.optimisticDefaultAppStatuses[category.id]?
                    .unifiedApplication?.bundleIdentifier == application.bundleIdentifier else { return }
                let status = self.systemDefaultAppStatus(for: category)
                if status.unifiedApplication?.bundleIdentifier == application.bundleIdentifier {
                    self.optimisticDefaultAppStatuses.removeValue(forKey: category.id)
                    self.defaultAppRevision += 1
                    return
                }
            }
            self.optimisticDefaultAppStatuses.removeValue(forKey: category.id)
            self.defaultAppRevision += 1
            let finalStatus = self.systemDefaultAppStatus(for: category)
            if finalStatus.unifiedApplication?.bundleIdentifier != application.bundleIdentifier {
                self.errorMessage = L10n.format("error.unifiedUpdateFailed", category.title)
            }
        }
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
