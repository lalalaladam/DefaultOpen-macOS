import Foundation
import UniformTypeIdentifiers

struct AppScanner: Sendable {
    func scanInstalledApplications(managedTypes: [FileTypeInfo]) -> [ApplicationInfo] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        var apps: [String: ApplicationInfo] = [:]

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            let keys: [URLResourceKey] = [.isApplicationKey, .isDirectoryKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                if let app = applicationInfo(at: url) { apps[app.bundleIdentifier] = app }
            }
        }
        return augmentWithLaunchServices(Array(apps.values), managedTypes: managedTypes)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Bundle document declarations are frequently incomplete. Launch Services' registered
    /// handlers are the authoritative second source (for example, Adobe may omit PDF from the
    /// document type block we can parse while still being registered as a PDF handler).
    private func augmentWithLaunchServices(_ applications: [ApplicationInfo], managedTypes: [FileTypeInfo]) -> [ApplicationInfo] {
        let client = LaunchServicesClient()
        var knownTypes: [String: SupportedType] = [:]
        for type in applications.flatMap(\.supportedTypes) {
            knownTypes[type.contentTypeIdentifier] = type
        }
        for type in managedTypes {
            knownTypes[type.contentTypeIdentifier] = SupportedType(
                contentTypeIdentifier: type.contentTypeIdentifier,
                extensions: [type.extensionName],
                displayName: type.displayName
            )
        }

        var inferred: [String: [SupportedType]] = [:]
        for type in knownTypes.values {
            for bundleID in client.capableBundleIdentifiers(forContentType: type.contentTypeIdentifier) {
                inferred[bundleID, default: []].append(type)
            }
        }

        return applications.map { app in
            var merged: [String: SupportedType] = [:]
            for type in app.supportedTypes + (inferred[app.bundleIdentifier] ?? []) {
                if let previous = merged[type.contentTypeIdentifier] {
                    merged[type.contentTypeIdentifier] = SupportedType(
                        contentTypeIdentifier: type.contentTypeIdentifier,
                        extensions: Array(Set(previous.extensions + type.extensions)).sorted(),
                        displayName: previous.displayName
                    )
                } else {
                    merged[type.contentTypeIdentifier] = type
                }
            }
            return ApplicationInfo(bundleIdentifier: app.bundleIdentifier, name: app.name, url: app.url,
                                   supportedTypes: merged.values.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            })
        }
    }

    private func applicationInfo(at url: URL) -> ApplicationInfo? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let types = parseDocumentTypes(info: info)
        return ApplicationInfo(bundleIdentifier: bundleID, name: name, url: url, supportedTypes: types)
    }

    private func parseDocumentTypes(info: [String: Any]) -> [SupportedType] {
        var result: [SupportedType] = []
        let declarations = ((info["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? [])
            + ((info["UTImportedTypeDeclarations"] as? [[String: Any]]) ?? [])
        var declaredExtensions: [String: [String]] = [:]
        for declaration in declarations {
            guard let identifier = declaration["UTTypeIdentifier"] as? String else { continue }
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            declaredExtensions[identifier] = stringArray(tags?["public.filename-extension"])
        }

        for document in (info["CFBundleDocumentTypes"] as? [[String: Any]]) ?? [] {
            let identifiers = stringArray(document["LSItemContentTypes"])
            let legacyExtensions = stringArray(document["CFBundleTypeExtensions"])
            let declaredName = document["CFBundleTypeName"] as? String

            for identifier in identifiers {
                let type = UTType(identifier)
                let extensions = (declaredExtensions[identifier] ?? []) + preferredExtensions(for: type)
                result.append(SupportedType(
                    contentTypeIdentifier: identifier,
                    extensions: normalize(extensions.isEmpty ? legacyExtensions : extensions),
                    displayName: declaredName ?? type?.localizedDescription ?? identifier
                ))
            }
            if identifiers.isEmpty {
                for ext in legacyExtensions where ext != "*" {
                    guard let type = UTType(filenameExtension: ext) else { continue }
                    result.append(SupportedType(
                        contentTypeIdentifier: type.identifier,
                        extensions: [ext.lowercased()],
                        displayName: declaredName ?? type.localizedDescription ?? type.identifier
                    ))
                }
            }
        }

        return Dictionary(grouping: result, by: \SupportedType.contentTypeIdentifier).values.map { group in
            let first = group[0]
            return SupportedType(contentTypeIdentifier: first.contentTypeIdentifier,
                                 extensions: normalize(group.flatMap(\.extensions)),
                                 displayName: first.displayName)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func stringArray(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let value = value as? String { return [value] }
        return []
    }

    private func preferredExtensions(for type: UTType?) -> [String] {
        guard let ext = type?.preferredFilenameExtension else { return [] }
        return [ext]
    }

    private func normalize(_ extensions: [String]) -> [String] {
        Array(Set(extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty && $0 != "*" })).sorted()
    }
}
