import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

func isUsableApplicationURL(_ url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let components = url.standardizedFileURL.pathComponents
    return !components.contains(".Trash") && !components.contains(".Trashes")
}

enum AssociationError: LocalizedError {
    case invalidExtension(String)
    case invalidApplication(URL)
    case missingBundleIdentifier(URL)
    case missingApplicationExecutable(URL)
    case incompatibleApplication(String, [String])
    case launchServices(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidExtension(let value): L10n.format("error.invalidExtension", value)
        case .invalidApplication(let url): L10n.format("error.invalidApplication", url.lastPathComponent)
        case .missingBundleIdentifier(let url): L10n.format("error.missingBundleIdentifier", url.lastPathComponent)
        case .missingApplicationExecutable(let url): L10n.format("error.missingApplicationExecutable", url.lastPathComponent)
        case .incompatibleApplication(let name, let targets):
            L10n.format("error.incompatibleApplication", name, targets.joined(separator: L10n.string("list.separator")))
        case .launchServices(let status): L10n.format("error.launchServices", status)
        }
    }
}

struct LaunchServicesClient: Sendable {
    func defaultApplication(forFileAt url: URL) -> ApplicationInfo? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundleID = Bundle(url: applicationURL)?.bundleIdentifier,
              isUsableApplicationURL(applicationURL) else { return nil }
        return lightweightApplication(bundleID: bundleID, url: applicationURL)
    }

    func capableApplications(forFileAt url: URL) -> [ApplicationInfo] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
            .filter(isUsableApplicationURL)
            .compactMap { applicationURL in
                guard let bundleID = Bundle(url: applicationURL)?.bundleIdentifier else {
                    return nil
                }
                return lightweightApplication(bundleID: bundleID, url: applicationURL)
            }
            .uniqued(by: \ApplicationInfo.bundleIdentifier)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func applicationInfo(at url: URL) throws -> ApplicationInfo {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              isUsableApplicationURL(url) else {
            throw AssociationError.invalidApplication(url)
        }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            throw AssociationError.missingBundleIdentifier(url)
        }
        return (try? AppScanner().applicationInfo(at: url))
            ?? lightweightApplication(bundleID: bundleID, url: url)
    }

    func setDefaultAwaitingConsent(_ application: ApplicationInfo,
                                   forFileAt url: URL) async throws {
        try await NSWorkspace.shared.setDefaultApplication(
            at: application.url,
            toOpenFileAt: url
        )
    }

    func fileTypes(for rawExtension: String) throws -> [FileTypeInfo] {
        let ext = try normalizedExtension(rawExtension)

        var types = UTType.types(
            tag: ext,
            tagClass: .filenameExtension,
            conformingTo: nil
        ).filter { !$0.isDynamic }
        if types.isEmpty, let fallback = UTType(filenameExtension: ext) {
            types = [fallback]
        }
        guard !types.isEmpty else { throw AssociationError.invalidExtension(rawExtension) }

        var seen = Set<String>()
        return types.compactMap { type in
            guard seen.insert(type.identifier).inserted else { return nil }
            return FileTypeInfo(
                extensionName: ext,
                contentTypeIdentifier: type.identifier,
                displayName: type.localizedDescription ?? type.identifier
            )
        }
    }

    func fileType(for rawExtension: String) throws -> FileTypeInfo {
        let ext = try normalizedExtension(rawExtension)
        guard let type = UTType(filenameExtension: ext) else {
            throw AssociationError.invalidExtension(rawExtension)
        }
        return FileTypeInfo(
            extensionName: ext,
            contentTypeIdentifier: type.identifier,
            displayName: type.localizedDescription ?? type.identifier
        )
    }

    private func normalizedExtension(_ rawExtension: String) throws -> String {
        let ext = rawExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !ext.isEmpty else { throw AssociationError.invalidExtension(rawExtension) }
        return ext
    }

    func defaultApplication(for type: FileTypeInfo) -> ApplicationInfo? {
        guard let contentType = UTType(type.contentTypeIdentifier),
              let url = NSWorkspace.shared.urlForApplication(toOpen: contentType),
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              isUsableApplicationURL(url) else { return nil }
        return lightweightApplication(bundleID: bundleID, url: url)
    }

    func capableApplications(for type: FileTypeInfo) -> [ApplicationInfo] {
        capableApplicationURLs(forContentType: type.contentTypeIdentifier).compactMap { url in
            if let application = try? AppScanner().applicationInfo(at: url) { return application }
            return Bundle(url: url)?.bundleIdentifier.map {
                lightweightApplication(bundleID: $0, url: url)
            }
        }
        .uniqued(by: \ApplicationInfo.bundleIdentifier)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func capableBundleIdentifiers(forContentType identifier: String) -> [String] {
        capableApplicationURLs(forContentType: identifier).compactMap {
            Bundle(url: $0)?.bundleIdentifier
        }.uniqued(by: \.self)
    }

    func application(_ bundleIdentifier: String, canOpenContentType identifier: String) -> Bool {
        capableBundleIdentifiers(forContentType: identifier).contains(bundleIdentifier)
    }

    func capableApplicationURLs(forContentType identifier: String) -> [URL] {
        guard let type = UTType(identifier) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
            .filter(isUsableApplicationURL)
            .uniqued(by: { url in
            Bundle(url: url)?.bundleIdentifier ?? url.standardizedFileURL.path
        })
    }

    func defaultApplication(forURLScheme scheme: String) -> ApplicationInfo? {
        guard let unmanaged = LSCopyDefaultHandlerForURLScheme(scheme as CFString),
              let bundleID = unmanaged.takeRetainedValue() as String?,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              isUsableApplicationURL(url) else { return nil }
        return lightweightApplication(bundleID: bundleID, url: url)
    }

    func capableApplications(forURLScheme scheme: String) -> [ApplicationInfo] {
        guard let unmanaged = LSCopyAllHandlersForURLScheme(scheme as CFString),
              let bundleIDs = unmanaged.takeRetainedValue() as? [String] else { return [] }
        return bundleIDs.compactMap { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            guard isUsableApplicationURL(url) else { return nil }
            return (try? AppScanner().applicationInfo(at: url))
                ?? lightweightApplication(bundleID: bundleID, url: url)
        }
        .uniqued(by: \ApplicationInfo.bundleIdentifier)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func application(_ bundleIdentifier: String, canOpenURLScheme scheme: String) -> Bool {
        capableApplications(forURLScheme: scheme).contains {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    func setDefault(_ application: ApplicationInfo, forURLScheme scheme: String) throws {
        let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, application.bundleIdentifier as CFString)
        guard status == noErr else { throw AssociationError.launchServices(status) }
    }

    func setDefault(_ application: ApplicationInfo, for type: FileTypeInfo) throws {
        let status = LSSetDefaultRoleHandlerForContentType(
            type.contentTypeIdentifier as CFString,
            .all,
            application.bundleIdentifier as CFString
        )
        guard status == noErr else { throw AssociationError.launchServices(status) }
    }

    func setDefaultAwaitingConsent(_ application: ApplicationInfo,
                                   forURLScheme scheme: String) async throws {
        try await NSWorkspace.shared.setDefaultApplication(
            at: application.url,
            toOpenURLsWithScheme: scheme
        )
    }

    func setDefaultAwaitingConsent(_ application: ApplicationInfo,
                                   for type: FileTypeInfo) async throws {
        guard let contentType = UTType(type.contentTypeIdentifier) else {
            throw AssociationError.invalidExtension(type.extensionName)
        }
        try await NSWorkspace.shared.setDefaultApplication(
            at: application.url,
            toOpen: contentType
        )
    }

    private func lightweightApplication(bundleID: String, url: URL) -> ApplicationInfo {
        let bundle = Bundle(url: url)
        let fallbackName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let localName = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
        let name = localName.isEmpty ? fallbackName : localName
        return ApplicationInfo(bundleIdentifier: bundleID, name: name, url: url, supportedTypes: [])
    }

}

private extension Sequence {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }

    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}

struct FreshAssociationProbeRecord: Codable, Sendable {
    let extensionName: String
    let contentTypeIdentifier: String
    let displayName: String
    let defaultBundleIdentifier: String?
    let defaultApplicationName: String?
    let defaultApplicationPath: String?

    var fileType: FileTypeInfo {
        FileTypeInfo(extensionName: extensionName,
                     contentTypeIdentifier: contentTypeIdentifier,
                     displayName: displayName)
    }

    var defaultApplication: ApplicationInfo? {
        guard let bundleIdentifier = defaultBundleIdentifier,
              let name = defaultApplicationName,
              let path = defaultApplicationPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard isUsableApplicationURL(url) else { return nil }
        return ApplicationInfo(bundleIdentifier: bundleIdentifier, name: name,
                               url: url, supportedTypes: [])
    }
}

enum FreshAssociationProbe {
    static let argument = "--defaultopen-association-probe"

    /// Runs before NSApplicationMain in a short-lived child process.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let marker = arguments.firstIndex(of: argument) else { return false }
        let extensions = arguments.dropFirst(marker + 1).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased()
        }.filter { !$0.isEmpty }.uniqued(by: \.self)
        let client = LaunchServicesClient()
        let records = extensions.compactMap { extensionName -> FreshAssociationProbeRecord? in
            guard let type = try? client.fileType(for: extensionName) else { return nil }
            let application = client.defaultApplication(for: type)
            return FreshAssociationProbeRecord(
                extensionName: extensionName,
                contentTypeIdentifier: type.contentTypeIdentifier,
                displayName: type.specificDisplayName,
                defaultBundleIdentifier: application?.bundleIdentifier,
                defaultApplicationName: application?.name,
                defaultApplicationPath: application?.url.path
            )
        }
        guard let data = try? JSONEncoder().encode(records) else { return true }
        FileHandle.standardOutput.write(data)
        return true
    }

    /// Launching the current executable directly creates a fresh UTType/Launch Services process
    /// without opening another app window or registering another installed component.
    static func query(_ extensions: [String], timeout: TimeInterval = 6) -> [FreshAssociationProbeRecord]? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        let normalized = extensions.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased()
        }.filter { !$0.isEmpty }.uniqued(by: \.self)
        guard !normalized.isEmpty else { return [] }

        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultOpen-Probe-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.executableURL = executableURL
        process.arguments = [argument] + normalized
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        try? output.close()
        guard let data = try? Data(contentsOf: outputURL) else { return nil }
        return try? JSONDecoder().decode([FreshAssociationProbeRecord].self, from: data)
    }
}
