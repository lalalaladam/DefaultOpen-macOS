import Foundation

@MainActor
final class AssociationStore: ObservableObject {
    @Published var fileTypes: [FileTypeInfo] = []
    @Published var applications: [ApplicationInfo] = []
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published private(set) var defaultsByContentType: [String: ApplicationInfo] = [:]

    private let launchServices = LaunchServicesClient()
    private let scanner = AppScanner()
    private let savedKey = "managedExtensions"
    private let starterExtensions = ["pdf", "txt", "md", "jpg", "png", "heic", "svg", "zip", "json", "csv", "docx", "xlsx", "pptx", "html", "mp3", "mp4"]

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: savedKey) ?? []
        fileTypes = (starterExtensions + saved).uniqued().compactMap { try? launchServices.fileType(for: $0) }
            .sorted { $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending }
        refreshDefaults(for: fileTypes)
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
        defaultsByContentType.merge(result.1) { _, new in new }
        isScanning = false
    }

    func addExtension(_ value: String) -> Bool {
        do {
            let type = try launchServices.fileType(for: value)
            guard !fileTypes.contains(where: { $0.id == type.id }) else { return true }
            fileTypes.append(type)
            fileTypes.sort { $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending }
            persistCustomExtensions()
            refreshDefaults(for: [type])
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func defaultApplication(for type: FileTypeInfo) -> ApplicationInfo? {
        defaultsByContentType[type.contentTypeIdentifier]
    }

    func capableApplications(for type: FileTypeInfo) -> [ApplicationInfo] {
        launchServices.capableApplications(for: type)
    }

    func setDefault(_ application: ApplicationInfo, for types: [FileTypeInfo]) {
        do {
            for type in types { try launchServices.setDefault(application, for: type) }
            refreshDefaults(for: types)
            successMessage = types.count == 1
                ? "已将 \(application.name) 设为 \(types[0].dottedExtension) 的默认打开程序"
                : "已将 \(application.name) 设为 \(types.count) 种文件的默认打开程序"
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                refreshDefaults(for: types)
                try? await Task.sleep(for: .milliseconds(900))
                refreshDefaults(for: types)
            }
        } catch {
            errorMessage = error.localizedDescription
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

    private func persistCustomExtensions() {
        UserDefaults.standard.set(fileTypes.map(\.extensionName), forKey: savedKey)
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
