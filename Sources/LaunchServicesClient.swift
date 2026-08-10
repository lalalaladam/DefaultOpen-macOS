import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

enum AssociationError: LocalizedError {
    case invalidExtension(String)
    case missingBundleIdentifier(URL)
    case launchServices(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidExtension(let value): "无法识别文件扩展名：\(value)"
        case .missingBundleIdentifier(let url): "应用缺少 Bundle Identifier：\(url.lastPathComponent)"
        case .launchServices(let status): "Launch Services 修改失败（OSStatus \(status)）"
        }
    }
}

struct LaunchServicesClient: Sendable {
    func fileType(for rawExtension: String) throws -> FileTypeInfo {
        let ext = rawExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            throw AssociationError.invalidExtension(rawExtension)
        }
        return FileTypeInfo(
            extensionName: ext,
            contentTypeIdentifier: type.identifier,
            displayName: type.localizedDescription ?? type.identifier
        )
    }

    func defaultApplication(for type: FileTypeInfo) -> ApplicationInfo? {
        guard let unmanaged = LSCopyDefaultRoleHandlerForContentType(type.contentTypeIdentifier as CFString, .all),
              let bundleID = unmanaged.takeRetainedValue() as String?,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return lightweightApplication(bundleID: bundleID, url: url)
    }

    func capableApplications(for type: FileTypeInfo) -> [ApplicationInfo] {
        capableBundleIdentifiers(forContentType: type.contentTypeIdentifier).compactMap { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { lightweightApplication(bundleID: bundleID, url: $0) }
        }
        .uniqued(by: \ApplicationInfo.bundleIdentifier)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func capableBundleIdentifiers(forContentType identifier: String) -> [String] {
        guard let unmanaged = LSCopyAllRoleHandlersForContentType(identifier as CFString, .all) else { return [] }
        return unmanaged.takeRetainedValue() as? [String] ?? []
    }

    func defaultApplication(forURLScheme scheme: String) -> ApplicationInfo? {
        guard let unmanaged = LSCopyDefaultHandlerForURLScheme(scheme as CFString),
              let bundleID = unmanaged.takeRetainedValue() as String?,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return lightweightApplication(bundleID: bundleID, url: url)
    }

    func capableApplications(forURLScheme scheme: String) -> [ApplicationInfo] {
        guard let unmanaged = LSCopyAllHandlersForURLScheme(scheme as CFString),
              let bundleIDs = unmanaged.takeRetainedValue() as? [String] else { return [] }
        return bundleIDs.compactMap { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { lightweightApplication(bundleID: bundleID, url: $0) }
        }
        .uniqued(by: \ApplicationInfo.bundleIdentifier)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return ApplicationInfo(bundleIdentifier: bundleID, name: name, url: url, supportedTypes: [])
    }
}

private extension Sequence {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
