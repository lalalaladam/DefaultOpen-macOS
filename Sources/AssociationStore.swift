import Foundation
import UniformTypeIdentifiers

private let protectedContentTypeIdentifiers: Set<String> = [
    "public.item", "public.content", "public.data", "public.composite-content"
]

private let broadContentTypeIdentifiers: Set<String> = [
    "public.text", "public.image", "public.audio", "public.movie",
    "public.audiovisual-content", "public.archive"
]

private func fileTypeModificationRisk(forIdentifier identifier: String) -> FileTypeModificationRisk {
    if protectedContentTypeIdentifiers.contains(identifier) { return .protected }
    if broadContentTypeIdentifiers.contains(identifier) { return .broad }
    return .normal
}

private struct CachedDefaultAppStatus {
    let revision: Int
    let status: DefaultAppCategoryStatus
}

private struct CachedDefaultAppCandidates {
    let revision: Int
    let candidates: [DefaultAppCandidate]
}

private struct LoadingDefaultAppCandidates {
    let revision: Int
    let task: Task<[DefaultAppCandidate], Never>
}

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
    @Published private(set) var applicationCapabilityIndex = ApplicationCapabilityIndex()
    @Published private(set) var loadingApplicationExtensions = Set<String>()
    @Published private(set) var capabilityApplicationsByIdentifier: [String: ApplicationInfo] = [:]

    private let launchServices = LaunchServicesClient()
    private let scanner = AppScanner()
    private let savedKey = "managedExtensions"
    private let customDefaultAppCategoriesKey = "customDefaultAppCategories"
    private let ignoredDefaultAppTypesKey = "ignoredDefaultAppTypesByCategory"
    private let includedDefaultAppTypesKey = "includedDefaultAppTypesByCategory"
    private let starterExtensions = ["pdf", "txt", "md", "jpg", "png", "heic", "svg", "zip", "json", "csv", "docx", "xlsx", "pptx", "html", "mp3", "mp4"]
    private var optimisticDefaultAppStatuses: [String: DefaultAppCategoryStatus] = [:]
    private var builtInDefaultAppStatuses: [String: CachedDefaultAppStatus] = [:]
    private var defaultAppCandidatesCache: [String: CachedDefaultAppCandidates] = [:]
    private var loadingDefaultAppCandidates: [String: LoadingDefaultAppCandidates] = [:]
    private var queriedApplicationExtensions = Set<String>()
    private var queriedDefaultContentTypes = Set<String>()
    private var registeredFileTypesByExtension: [String: [FileTypeInfo]] = [:]
    private var fullyLoadedDeclaredFileTypes: [FileTypeInfo] = []
    private var applicationBundleSnapshot: Set<String>?
    private var applicationScanRequested = false
    private var loadingCapabilityApplicationIdentifiers = Set<String>()
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
        refreshBuiltInDefaultAppStatuses()
    }

    func saveCustomDefaultAppCategory(id: String?, title: String, subtitle: String,
                                      symbol: String, extensions: [String]) async -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExtensions = extensions.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased()
        }.filter { !$0.isEmpty }.uniqued()

        guard !normalizedTitle.isEmpty else {
            errorMessage = L10n.string("请输入组合名称。")
            return false
        }
        let invalidExtensions = await Task.detached(priority: .userInitiated) {
            let client = LaunchServicesClient()
            return normalizedExtensions.filter { (try? client.fileType(for: $0)) == nil }
        }.value
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
        advanceDefaultAppRevision()
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
        advanceDefaultAppRevision()
    }

    func scanApplications() async {
        applicationScanRequested = true
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        while applicationScanRequested {
            applicationScanRequested = false
            await performApplicationScan()
        }
    }

    /// Directory notifications arrive before Launch Services necessarily finishes unregistering
    /// a removed application. Preserve whether this was a removal so the app delegate can request
    /// a small number of delayed, full environment refreshes.
    func refreshAfterApplicationDirectoryChange() async -> Bool {
        let previousSnapshot = applicationBundleSnapshot
        let knownApplicationWasRemoved = applications.contains {
            !FileManager.default.fileExists(atPath: $0.url.path)
        }
        let scanner = self.scanner
        let currentSnapshot = await Task.detached(priority: .utility) {
            scanner.applicationBundleSnapshot()
        }.value
        guard !Task.isCancelled else { return false }

        let removedApplication = knownApplicationWasRemoved || (previousSnapshot.map {
            !$0.subtracting(currentSnapshot).isEmpty
        } ?? false)
        await scanApplications()
        return removedApplication
    }

    private func performApplicationScan() async {
        queriedApplicationExtensions.removeAll()
        loadingApplicationExtensions.removeAll()
        queriedDefaultContentTypes.removeAll()
        registeredFileTypesByExtension.removeAll()
        let scanner = self.scanner
        let launchServices = self.launchServices
        let shouldIncludeAllDeclaredTypes = hasLoadedAllFileTypes
        let managedExtensions = fileTypes.map(\.extensionName).uniqued()
        let categoryExtensions = (
            DefaultAppCategory.all.flatMap { $0.extensions(includingOptional: true) }
            + customDefaultAppCategories.flatMap { $0.extensions(includingOptional: true) }
        ).uniqued()
        let seedExtensions = (
            managedExtensions + categoryExtensions
        ).uniqued()
        let result = await Task.detached(priority: .userInitiated) {
            let preliminaryManagedTypes = managedExtensions.compactMap {
                try? launchServices.fileType(for: $0)
            }
            let scannedApplications = scanner.scanInstalledApplications(
                managedTypes: preliminaryManagedTypes
            )
            let discoveredExtensions = scannedApplications.flatMap { application in
                application.documentTypes.flatMap(\.extensions)
                    + application.supportedTypes.flatMap(\.extensions)
            }
            let probeRecords = FreshAssociationProbe.query(
                (seedExtensions + discoveredExtensions).uniqued()
            )
            let freshTypesByExtension = Dictionary(uniqueKeysWithValues: (probeRecords ?? []).map {
                ($0.extensionName, $0.fileType)
            })
            let managedTypes = managedExtensions.compactMap {
                freshTypesByExtension[$0] ?? (try? launchServices.fileType(for: $0))
            }.sorted {
                $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending
            }
            let capabilities = ApplicationCapabilityIndexer().build(
                applications: scannedApplications,
                seedExtensions: seedExtensions,
                resolvedFileTypesByExtension: freshTypesByExtension
            )
            let declaredTypes = shouldIncludeAllDeclaredTypes
                ? scanner.declaredFileTypes(from: capabilities.applications) : []
            let catalogTypes = Dictionary(
                grouping: managedTypes + capabilities.index.allFileTypes + declaredTypes,
                by: \FileTypeInfo.id
            ).compactMap(\.value.first).sorted {
                $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending
            }
            let categoryTypes = categoryExtensions.flatMap {
                (try? launchServices.fileTypes(for: $0)) ?? []
            }
            let applicationTypes = capabilities.applications
                .flatMap(\.supportedTypes).flatMap(\.fileTypes)
            let defaultTypes = Dictionary(
                grouping: catalogTypes + categoryTypes + applicationTypes,
                by: \FileTypeInfo.contentTypeIdentifier
            ).compactMap(\.value.first)
            var defaults: [String: ApplicationInfo] = [:]
            if let probeRecords {
                for record in probeRecords {
                    if let application = record.defaultApplication {
                        defaults[record.contentTypeIdentifier] = application
                    }
                }
            } else {
                for type in defaultTypes {
                    if let application = launchServices.defaultApplication(for: type) {
                        defaults[type.contentTypeIdentifier] = application
                    }
                }
            }
            return (managedTypes, catalogTypes, capabilities, defaults, declaredTypes,
                    scanner.applicationBundleSnapshot())
        }.value
        guard !Task.isCancelled, !applicationScanRequested else { return }

        // Publish one internally consistent environment. Replacing the defaults dictionary is
        // important when an uninstalled app's UTType identifier disappears or changes.
        fileTypes = result.0
        if shouldIncludeAllDeclaredTypes {
            fullyLoadedDeclaredFileTypes = result.4
        }
        allFileTypes = Dictionary(
            grouping: result.1 + (hasLoadedAllFileTypes ? fullyLoadedDeclaredFileTypes : []),
            by: \FileTypeInfo.id
        ).compactMap(\.value.first).sorted {
            $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending
        }
        applicationCapabilityIndex = result.2.index
        applications = result.2.applications
        capabilityApplicationsByIdentifier.merge(
            Dictionary(uniqueKeysWithValues: result.2.applications.map {
                ($0.bundleIdentifier, $0)
            })
        ) { _, scanned in scanned }
        defaultsByContentType = result.3
        applicationBundleSnapshot = result.5
        optimisticDefaultAppStatuses.removeAll()
        defaultAppCandidatesCache.removeAll()
        loadingDefaultAppCandidates.values.forEach { $0.task.cancel() }
        loadingDefaultAppCandidates.removeAll()
        builtInDefaultAppStatuses.removeAll()
        advanceDefaultAppRevision()
    }

    func refreshAfterActivation() async {
        let scanner = self.scanner
        let currentSnapshot = await Task.detached(priority: .utility) {
            scanner.applicationBundleSnapshot()
        }.value
        guard !Task.isCancelled else { return }

        if let previousSnapshot = applicationBundleSnapshot,
           previousSnapshot != currentSnapshot {
            await scanApplications()
        } else {
            applicationBundleSnapshot = currentSnapshot
            await refreshExternalDefaultChanges()
        }
    }

    func loadApplications(matchingExtensionSearch searchText: String) async {
        let extensionName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !extensionName.isEmpty,
              extensionName.count <= 32,
              !extensionName.contains(where: { $0.isWhitespace || $0 == "." }),
              !queriedApplicationExtensions.contains(extensionName),
              !loadingApplicationExtensions.contains(extensionName),
              let fileType = try? launchServices.fileType(for: extensionName) else { return }

        loadingApplicationExtensions.insert(extensionName)
        defer { loadingApplicationExtensions.remove(extensionName) }
        let scanner = self.scanner
        let discovered = await Task.detached(priority: .userInitiated) {
            scanner.applicationsCapable(of: fileType)
        }.value
        guard !Task.isCancelled else { return }
        queriedApplicationExtensions.insert(extensionName)
        guard !discovered.isEmpty else { return }
        mergeApplications(discovered)
        var updatedIndex = applicationCapabilityIndex
        updatedIndex.insert(fileType, for: discovered.map(\.bundleIdentifier))
        applicationCapabilityIndex = updatedIndex
        if UTType(fileType.contentTypeIdentifier)?.isDynamic == false {
            mergeIntoFileTypeCatalog([fileType])
        }
        if let defaultApplication = launchServices.defaultApplication(for: fileType) {
            defaultsByContentType[fileType.contentTypeIdentifier] = defaultApplication
        }
    }

    func verifiedFileTypes(for application: ApplicationInfo) -> [FileTypeInfo] {
        applicationCapabilityIndex.fileTypes(for: application.bundleIdentifier)
    }

    func isLoadingApplications(matchingExtensionSearch searchText: String) -> Bool {
        let extensionName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return loadingApplicationExtensions.contains(extensionName)
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
        fullyLoadedDeclaredFileTypes = result.0
        defaultsByContentType.merge(result.1) { _, new in new }
        hasLoadedAllFileTypes = true
        isLoadingFileTypes = false
        await loadDefaultApplicationCapabilityMetadata(for: Array(result.1.values))
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

    func inferredFileType(forExtension extensionName: String) -> FileTypeInfo? {
        try? launchServices.fileType(for: extensionName)
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
        fileTypeModificationRisk(forIdentifier: type.contentTypeIdentifier)
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

    func capabilityEvidence(for application: ApplicationInfo,
                            fileType: FileTypeInfo) -> ApplicationCapabilityEvidence {
        let resolvedApplication = resolvedCapabilityApplication(for: application) ?? application
        return ApplicationCapabilityEvidenceResolver.evidence(
            for: resolvedApplication,
            fileType: fileType
        )
    }

    func capabilityEvidenceIfAvailable(for application: ApplicationInfo,
                                       fileType: FileTypeInfo) -> ApplicationCapabilityEvidence? {
        guard let resolvedApplication = resolvedCapabilityApplication(for: application) else {
            return nil
        }
        return ApplicationCapabilityEvidenceResolver.evidence(
            for: resolvedApplication,
            fileType: fileType
        )
    }

    func loadDefaultApplicationCapabilityMetadata(
        for requestedApplications: [ApplicationInfo]? = nil
    ) async {
        let source = requestedApplications ?? Array(defaultsByContentType.values)
        var candidatesByIdentifier: [String: ApplicationInfo] = [:]
        for application in source {
            if application.documentTypes.contains(where: { $0.source == .bundleDeclaration }) {
                capabilityApplicationsByIdentifier[application.bundleIdentifier] = application
            } else {
                candidatesByIdentifier[application.bundleIdentifier] = application
            }
        }
        let pending = candidatesByIdentifier.values.filter {
            capabilityApplicationsByIdentifier[$0.bundleIdentifier] == nil
                && !loadingCapabilityApplicationIdentifiers.contains($0.bundleIdentifier)
        }
        guard !pending.isEmpty else { return }

        loadingCapabilityApplicationIdentifiers.formUnion(pending.map(\.bundleIdentifier))
        let scanner = self.scanner
        let loaded = await Task.detached(priority: .utility) {
            pending.compactMap { try? scanner.applicationInfo(at: $0.url) }
        }.value
        loadingCapabilityApplicationIdentifiers.subtract(pending.map(\.bundleIdentifier))
        guard !Task.isCancelled else { return }
        capabilityApplicationsByIdentifier.merge(
            Dictionary(uniqueKeysWithValues: loaded.map { ($0.bundleIdentifier, $0) })
        ) { _, scanned in scanned }
    }

    private func resolvedCapabilityApplication(for application: ApplicationInfo) -> ApplicationInfo? {
        if application.documentTypes.contains(where: { $0.source == .bundleDeclaration }) {
            return application
        }
        if let cached = capabilityApplicationsByIdentifier[application.bundleIdentifier] {
            return cached
        }
        return applications.first { $0.bundleIdentifier == application.bundleIdentifier }
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
        if !category.isCustom,
           let cached = builtInDefaultAppStatuses[statusKey],
           cached.revision == defaultAppRevision {
            return cached.status
        }
        let status = systemDefaultAppStatus(for: category, includingOptional: includingOptional)
        if !category.isCustom {
            builtInDefaultAppStatuses[statusKey] = CachedDefaultAppStatus(
                revision: defaultAppRevision,
                status: status
            )
        }
        return status
    }

    func loadDefaultAppStatus(for category: DefaultAppCategory,
                              includingOptional: Bool = false) async -> DefaultAppCategoryStatus {
        let resolver = makeDefaultAppResolver()
        return await Task.detached(priority: .userInitiated) {
            resolver.status(for: category, includingOptional: includingOptional)
        }.value
    }

    func loadOptionalDefaultAppStatus(for category: DefaultAppCategory) async -> DefaultAppCategoryStatus {
        let resolver = makeDefaultAppResolver()
        return await Task.detached(priority: .userInitiated) {
            resolver.optionalStatus(for: category)
        }.value
    }

    func loadDefaultAppCandidates(for category: DefaultAppCategory,
                                  includingOptional: Bool,
                                  priority: TaskPriority = .userInitiated) async -> [DefaultAppCandidate] {
        let key = defaultAppStatusKey(for: category, includingOptional: includingOptional)
        if let cached = defaultAppCandidatesCache[key], cached.revision == defaultAppRevision {
            return cached.candidates
        }
        if let loading = loadingDefaultAppCandidates[key], loading.revision == defaultAppRevision {
            return await loading.task.value
        }
        let revision = defaultAppRevision
        let resolver = makeDefaultAppResolver()
        let task = Task.detached(priority: priority) {
            resolver.candidates(for: category, includingOptional: includingOptional)
        }
        loadingDefaultAppCandidates[key] = LoadingDefaultAppCandidates(
            revision: revision,
            task: task
        )
        let candidates = await task.value
        if defaultAppRevision == revision {
            defaultAppCandidatesCache[key] = CachedDefaultAppCandidates(
                revision: revision,
                candidates: candidates
            )
        }
        if loadingDefaultAppCandidates[key]?.revision == revision {
            loadingDefaultAppCandidates.removeValue(forKey: key)
        }
        return candidates
    }

    func cachedDefaultAppCandidates(for category: DefaultAppCategory,
                                    includingOptional: Bool) -> [DefaultAppCandidate]? {
        defaultAppCandidatesCache[
            defaultAppStatusKey(for: category, includingOptional: includingOptional)
        ]?.candidates
    }

    func prewarmBuiltInDefaultAppCandidates() async {
        for category in DefaultAppCategory.all {
            guard !Task.isCancelled else { return }
            _ = await loadDefaultAppCandidates(
                for: category,
                includingOptional: false,
                priority: .utility
            )
            await Task.yield()
        }
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

    private func makeDefaultAppResolver() -> DefaultAppResolver {
        DefaultAppResolver(
            ignoredTypes: ignoredDefaultAppTypesByCategory,
            includedTypes: includedDefaultAppTypesByCategory
        )
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
            if $0.capabilitySourceCounts.explicit != $1.capabilitySourceCounts.explicit {
                return $0.capabilitySourceCounts.explicit > $1.capabilitySourceCounts.explicit
            }
            if $0.capabilitySourceCounts.extensionDeclaration
                != $1.capabilitySourceCounts.extensionDeclaration {
                return $0.capabilitySourceCounts.extensionDeclaration
                    > $1.capabilitySourceCounts.extensionDeclaration
            }
            if $0.capabilitySourceCounts.broad != $1.capabilitySourceCounts.broad {
                return $0.capabilitySourceCounts.broad > $1.capabilitySourceCounts.broad
            }
            if $0.capabilitySourceCounts.system != $1.capabilitySourceCounts.system {
                return $0.capabilitySourceCounts.system < $1.capabilitySourceCounts.system
            }
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

            let targets = defaultAppTargets(for: category, includingOptional: includingOptional,
                                            includeCapabilities: false)
                .filter { isDefaultAppTargetManaged($0, for: category) }
            for target in targets {
                if target.defaultApplication?.bundleIdentifier == application.bundleIdentifier {
                    unchangedTargets.append(target.label)
                    continue
                }
                if let type = target.fileType, modificationRisk(for: type) == .protected {
                    skippedTargets.append(target.label)
                    continue
                }
                guard applicationSupports(application, target: target) else {
                    skippedTargets.append(target.label)
                    continue
                }
                switch target.kind {
                case .urlScheme(let scheme):
                    operations.append(.scheme(scheme, target.label))
                case .fileType(let type):
                    operations.append(.fileType(type, target.label))
                }
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
                case .fileType(let type, let label):
                    try await launchServices.setDefaultAwaitingConsent(application, for: type)
                    changedTypes.append(type)
                    changedTargets.append(label)
                }
            }

            refreshDefaults(for: changedTypes)
            let statusKey = defaultAppStatusKey(for: category, includingOptional: includingOptional)
            let selectedLabels = targets.map(\.label).uniqued()
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
            advanceDefaultAppRevision()
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
        defaultsByContentType = Dictionary(uniqueKeysWithValues: refreshed.compactMap {
            identifier, application in application.map { (identifier, $0) }
        })
        await loadDefaultApplicationCapabilityMetadata()
        defaultAppCandidatesCache.removeAll()
        loadingDefaultAppCandidates.values.forEach { $0.task.cancel() }
        loadingDefaultAppCandidates.removeAll()
        builtInDefaultAppStatuses.removeAll()
        advanceDefaultAppRevision()
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
        var merged: [String: ApplicationInfo] = [:]
        for application in applications {
            merged[application.bundleIdentifier] = application
        }
        for application in discovered {
            guard let existing = merged[application.bundleIdentifier] else {
                merged[application.bundleIdentifier] = application
                continue
            }
            var types: [String: SupportedType] = [:]
            for type in existing.supportedTypes {
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
                documentTypes: mergeDocumentTypes(existing.documentTypes,
                                                  application.documentTypes),
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

    private func mergeDocumentTypes(_ existing: [ApplicationDocumentType],
                                    _ discovered: [ApplicationDocumentType]) -> [ApplicationDocumentType] {
        coalescedApplicationDocumentTypes(existing + discovered).sorted {
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
        extensions.compactMap { try? launchServices.fileType(for: $0) }
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
            isManaged: !canCustomizeScope || isDefaultAppTypeManaged(identifier, for: category),
            canChangeDefault: (!canCustomizeScope
                || isDefaultAppTypeManaged(identifier, for: category))
                && (target.fileType.map { modificationRisk(for: $0) != .protected } ?? true),
            capabilityEvidence: capabilityEvidence(for: application, target: target)
        )
    }

    private func capabilityEvidence(for application: ApplicationInfo,
                                    target: DefaultAppTarget) -> ApplicationCapabilityEvidence {
        switch target.kind {
        case .urlScheme(let scheme):
            ApplicationCapabilityEvidenceResolver.evidence(for: application, urlScheme: scheme)
        case .fileType(let type):
            ApplicationCapabilityEvidenceResolver.evidence(for: application, fileType: type)
        }
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
        advanceDefaultAppRevision()
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
        launchServices.application(application.bundleIdentifier, canOpenURLScheme: urlScheme)
    }

    private func applicationSupports(_ application: ApplicationInfo, fileType: FileTypeInfo) -> Bool {
        launchServices.application(
            application.bundleIdentifier,
            canOpenContentType: fileType.contentTypeIdentifier
        )
    }

    private func defaultAppStatusKey(for category: DefaultAppCategory,
                                     includingOptional: Bool) -> String {
        "\(category.id)|\(includingOptional ? "all" : "core")"
    }

    private func advanceDefaultAppRevision() {
        defaultAppRevision += 1
        refreshBuiltInDefaultAppStatuses()
    }

    private func refreshBuiltInDefaultAppStatuses() {
        for category in DefaultAppCategory.all {
            let key = defaultAppStatusKey(for: category, includingOptional: false)
            builtInDefaultAppStatuses[key] = CachedDefaultAppStatus(
                revision: defaultAppRevision,
                status: systemDefaultAppStatus(for: category, includingOptional: false)
            )
        }
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
                    self.advanceDefaultAppRevision()
                    return
                }
            }
            self.optimisticDefaultAppStatuses.removeValue(forKey: statusKey)
            self.advanceDefaultAppRevision()
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

    var fileType: FileTypeInfo? {
        guard case .fileType(let type) = kind else { return nil }
        return type
    }
}

private enum DefaultAppTargetKind {
    case urlScheme(String)
    case fileType(FileTypeInfo)
}

private enum DefaultChangeOperation {
    case scheme(String, String)
    case fileType(FileTypeInfo, String)

    var label: String {
        switch self {
        case .scheme(_, let label): label
        case .fileType(_, let label): label
        }
    }
}

private struct DefaultAppResolver: Sendable {
    let ignoredTypes: [String: Set<String>]
    let includedTypes: [String: Set<String>]
    private let launchServices = LaunchServicesClient()

    func status(for category: DefaultAppCategory,
                includingOptional: Bool) -> DefaultAppCategoryStatus {
        status(from: managedTargets(for: category, includingOptional: includingOptional,
                                    includeCapabilities: false),
               category: category)
    }

    func optionalStatus(for category: DefaultAppCategory) -> DefaultAppCategoryStatus {
        let optionalCategory = DefaultAppCategory(
            id: category.id,
            title: category.title,
            subtitle: category.subtitle,
            symbol: category.symbol,
            coreExtensions: category.optionalExtensions,
            optionalExtensions: [],
            urlSchemes: [],
            isCustom: category.isCustom
        )
        return status(from: managedTargets(for: optionalCategory, includingOptional: false,
                                           includeCapabilities: false, policyCategory: category),
                      category: category)
    }

    // Swift 6.4 in Xcode 27 beta crashes in LoopInvariantCodeMotion while
    // optimizing this function. Keep the workaround local to this resolver.
    @_optimize(none)
    func candidates(for category: DefaultAppCategory,
                    includingOptional: Bool) -> [DefaultAppCandidate] {
        let allTargets = targets(for: category, includingOptional: includingOptional,
                                 includeCapabilities: true)
        let managed = allTargets.filter { isManaged($0, for: category) }
        let discoveryTargets = managed.isEmpty ? allTargets : managed
        var applications: [String: ApplicationInfo] = [:]
        for target in discoveryTargets {
            for application in target.capableApplications {
                applications[application.bundleIdentifier] = application
            }
        }

        let allCore = targets(for: category, includingOptional: false,
                              includeCapabilities: false)
        let allDisplay = targets(for: category, includingOptional: includingOptional,
                                 includeCapabilities: false)
        let managedCore = allCore.filter { isManaged($0, for: category) }
        let managedDisplay = allDisplay.filter { isManaged($0, for: category) }

        return applications.values.compactMap { application in
            let core = managedCore.isEmpty ? allCore : managedCore
            guard core.contains(where: { supports(application, target: $0) }) else { return nil }
            let supported = managedDisplay.filter { supports(application, target: $0) }
            let current = managedDisplay.filter {
                $0.defaultApplication?.bundleIdentifier == application.bundleIdentifier
            }.map(\.label).uniqued()
            return DefaultAppCandidate(
                application: application,
                supportedCount: supported.count,
                totalCount: managedDisplay.count,
                supportedTargets: supported.map(\.label).uniqued(),
                unsupportedTargets: managedDisplay.filter {
                    !supports(application, target: $0)
                }.map(\.label).uniqued(),
                currentTargets: current,
                isCurrentDefault: managedDisplay.allSatisfy {
                    $0.defaultApplication?.bundleIdentifier == application.bundleIdentifier
                },
                typeDetails: allDisplay.map { detail($0, application: application, category: category) }
            )
        }.sorted {
            if $0.supportedCount != $1.supportedCount { return $0.supportedCount > $1.supportedCount }
            if $0.capabilitySourceCounts.explicit != $1.capabilitySourceCounts.explicit {
                return $0.capabilitySourceCounts.explicit > $1.capabilitySourceCounts.explicit
            }
            if $0.capabilitySourceCounts.extensionDeclaration
                != $1.capabilitySourceCounts.extensionDeclaration {
                return $0.capabilitySourceCounts.extensionDeclaration
                    > $1.capabilitySourceCounts.extensionDeclaration
            }
            if $0.capabilitySourceCounts.broad != $1.capabilitySourceCounts.broad {
                return $0.capabilitySourceCounts.broad > $1.capabilitySourceCounts.broad
            }
            if $0.capabilitySourceCounts.system != $1.capabilitySourceCounts.system {
                return $0.capabilitySourceCounts.system < $1.capabilitySourceCounts.system
            }
            return $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
        }
    }

    private func status(from targets: [DefaultAppTarget],
                        category: DefaultAppCategory) -> DefaultAppCategoryStatus {
        var missing: [String] = []
        var applicationOrder: [String] = []
        var applicationByID: [String: ApplicationInfo] = [:]
        var labelsByApplication: [String: [String]] = [:]
        for target in targets {
            guard let application = target.defaultApplication else {
                missing.append(target.label)
                continue
            }
            let id = application.bundleIdentifier
            if applicationByID[id] == nil { applicationOrder.append(id) }
            applicationByID[id] = application
            labelsByApplication[id, default: []].append(target.label)
        }
        let assignments = applicationOrder.compactMap { id -> DefaultAppAssignment? in
            guard let application = applicationByID[id] else { return nil }
            return DefaultAppAssignment(application: application,
                                        targets: labelsByApplication[id, default: []].uniqued())
        }
        let unified = missing.isEmpty && assignments.count == 1
            ? assignments.first?.application : nil
        return DefaultAppCategoryStatus(
            unifiedApplication: unified,
            assignments: assignments,
            missingTargets: missing.uniqued(),
            ignoredTypeCount: targets.filter { isIgnored($0, for: category) }.count
        )
    }

    private func managedTargets(for category: DefaultAppCategory,
                                includingOptional: Bool,
                                includeCapabilities: Bool,
                                policyCategory: DefaultAppCategory? = nil) -> [DefaultAppTarget] {
        let policy = policyCategory ?? category
        return targets(for: category, includingOptional: includingOptional,
                       includeCapabilities: includeCapabilities)
            .filter { isManaged($0, for: policy) }
    }

    private func targets(for category: DefaultAppCategory,
                         includingOptional: Bool,
                         includeCapabilities: Bool) -> [DefaultAppTarget] {
        var result = category.urlSchemes.map { scheme in
            DefaultAppTarget(
                key: "scheme:\(scheme)", label: scheme.uppercased(), kind: .urlScheme(scheme),
                defaultApplication: launchServices.defaultApplication(forURLScheme: scheme),
                capableApplications: includeCapabilities
                    ? launchServices.capableApplications(forURLScheme: scheme) : []
            )
        }
        var order: [String] = []
        var typeByIdentifier: [String: FileTypeInfo] = [:]
        var labelsByIdentifier: [String: [String]] = [:]
        for extensionName in category.extensions(includingOptional: includingOptional) {
            guard let type = try? launchServices.fileType(for: extensionName) else { continue }
            let identifier = type.contentTypeIdentifier
            if typeByIdentifier[identifier] == nil { order.append(identifier) }
            typeByIdentifier[identifier] = type
            labelsByIdentifier[identifier, default: []].append("." + extensionName)
        }
        result += order.compactMap { identifier in
            guard let type = typeByIdentifier[identifier] else { return nil }
            return DefaultAppTarget(
                key: "type:\(identifier)",
                label: labelsByIdentifier[identifier, default: []].joined(separator: "/"),
                kind: .fileType(type),
                defaultApplication: launchServices.defaultApplication(for: type),
                capableApplications: includeCapabilities ? launchServices.capableApplications(for: type) : []
            )
        }
        return result
    }

    private func detail(_ target: DefaultAppTarget,
                        application: ApplicationInfo,
                        category: DefaultAppCategory) -> DefaultAppCandidateTypeDetail {
        let identifier: String
        let typeName: String
        let canCustomize: Bool
        let automatic: Bool
        switch target.kind {
        case .urlScheme(let scheme):
            identifier = scheme.lowercased()
            typeName = L10n.string("网页链接")
            canCustomize = false
            automatic = true
        case .fileType(let type):
            identifier = type.contentTypeIdentifier
            typeName = type.specificDisplayName
            canCustomize = true
            automatic = isAutomaticallyManaged(identifier, for: category)
        }
        let policy = scopePolicy(identifier, for: category)
        return DefaultAppCandidateTypeDetail(
            id: target.key, label: target.label, typeName: typeName,
            technicalIdentifier: identifier,
            isSupported: supports(application, target: target),
            isCurrentDefault: target.defaultApplication?.bundleIdentifier == application.bundleIdentifier,
            canCustomizeScope: canCustomize, scopePolicy: policy,
            isAutomaticallyManaged: automatic,
            isManaged: !canCustomize || isManaged(identifier, for: category),
            canChangeDefault: (!canCustomize || isManaged(identifier, for: category))
                && (target.fileType.map {
                    fileTypeModificationRisk(forIdentifier: $0.contentTypeIdentifier) != .protected
                } ?? true),
            capabilityEvidence: capabilityEvidence(for: application, target: target)
        )
    }

    private func capabilityEvidence(for application: ApplicationInfo,
                                    target: DefaultAppTarget) -> ApplicationCapabilityEvidence {
        switch target.kind {
        case .urlScheme(let scheme):
            ApplicationCapabilityEvidenceResolver.evidence(for: application, urlScheme: scheme)
        case .fileType(let type):
            ApplicationCapabilityEvidenceResolver.evidence(for: application, fileType: type)
        }
    }

    private func supports(_ application: ApplicationInfo, target: DefaultAppTarget) -> Bool {
        switch target.kind {
        case .urlScheme(let scheme):
            return launchServices.application(
                application.bundleIdentifier,
                canOpenURLScheme: scheme
            )
        case .fileType(let fileType):
            return launchServices.application(
                application.bundleIdentifier,
                canOpenContentType: fileType.contentTypeIdentifier
            )
        }
    }

    private func scopePolicy(_ identifier: String,
                             for category: DefaultAppCategory) -> DefaultAppTypeScopePolicy {
        if ignoredTypes[category.id]?.contains(identifier) == true { return .excluded }
        if includedTypes[category.id]?.contains(identifier) == true { return .included }
        return .automatic
    }

    private func isManaged(_ target: DefaultAppTarget,
                           for category: DefaultAppCategory) -> Bool {
        guard case .fileType(let type) = target.kind else { return true }
        return isManaged(type.contentTypeIdentifier, for: category)
    }

    private func isIgnored(_ target: DefaultAppTarget,
                           for category: DefaultAppCategory) -> Bool {
        guard case .fileType(let type) = target.kind else { return false }
        return ignoredTypes[category.id]?.contains(type.contentTypeIdentifier) == true
    }

    private func isManaged(_ identifier: String,
                           for category: DefaultAppCategory) -> Bool {
        switch scopePolicy(identifier, for: category) {
        case .included: true
        case .excluded: false
        case .automatic: isAutomaticallyManaged(identifier, for: category)
        }
    }

    private func isAutomaticallyManaged(_ identifier: String,
                                        for category: DefaultAppCategory) -> Bool {
        category.extensions(includingOptional: true).contains { extensionName in
            (try? launchServices.fileType(for: extensionName))?.contentTypeIdentifier == identifier
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
