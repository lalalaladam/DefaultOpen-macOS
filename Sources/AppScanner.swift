import Foundation
import UniformTypeIdentifiers

struct AppScanner: Sendable {
    func scanInstalledApplications(managedTypes: [FileTypeInfo]) -> [ApplicationInfo] {
        augmentWithLaunchServices(scanApplicationBundles(), managedTypes: managedTypes)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func scanDeclaredFileTypes() -> [SupportedType] {
        let types = scanApplicationBundles().flatMap(\.supportedTypes)
        return Dictionary(grouping: types, by: \SupportedType.contentTypeIdentifier).values.map { group in
            let first = group[0]
            return SupportedType(
                contentTypeIdentifier: first.contentTypeIdentifier,
                extensions: Array(Set(group.flatMap(\.extensions))).sorted(),
                displayName: first.displayName
            )
        }
    }

    func applicationsCapable(of fileType: FileTypeInfo) -> [ApplicationInfo] {
        let client = LaunchServicesClient()
        let inferredType = SupportedType(
            contentTypeIdentifier: fileType.contentTypeIdentifier,
            extensions: [fileType.extensionName],
            displayName: fileType.displayName
        )
        return client.capableApplicationURLs(forContentType: fileType.contentTypeIdentifier).compactMap { url in
            guard let application = try? applicationInfo(at: url) else { return nil }
            return merging(inferredType, into: application)
        }
    }

    private func scanApplicationBundles() -> [ApplicationInfo] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        var apps: [String: ApplicationInfo] = [:]

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            for url in applicationURLs(in: root, maximumDepth: 2) {
                if let app = try? applicationInfo(at: url) { apps[app.bundleIdentifier] = app }
            }
        }
        return Array(apps.values)
    }

    /// Installed applications normally live at the root or one grouping folder below it.
    /// A depth-limited walk avoids accidentally traversing large unrelated directory trees.
    private func applicationURLs(in root: URL, maximumDepth: Int) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for child in children {
            if child.pathExtension.lowercased() == "app" {
                result.append(child)
                continue
            }
            guard maximumDepth > 0,
                  let values = try? child.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            result.append(contentsOf: applicationURLs(in: child, maximumDepth: maximumDepth - 1))
        }
        return result
    }

    /// Bundle document declarations are frequently incomplete. Launch Services' registered
    /// handlers are the authoritative second source (for example, Adobe may omit PDF from the
    /// document type block we can parse while still being registered as a PDF handler).
    private func augmentWithLaunchServices(_ applications: [ApplicationInfo], managedTypes: [FileTypeInfo]) -> [ApplicationInfo] {
        let client = LaunchServicesClient()
        var discoveredApplications = Dictionary(
            uniqueKeysWithValues: applications.map { ($0.bundleIdentifier, $0) }
        )
        var knownTypes: [String: SupportedType] = [:]
        for type in managedTypes {
            knownTypes[type.contentTypeIdentifier] = SupportedType(
                contentTypeIdentifier: type.contentTypeIdentifier,
                extensions: [type.extensionName],
                displayName: type.displayName
            )
        }

        var inferred: [String: [SupportedType]] = [:]
        for type in knownTypes.values {
            for url in client.capableApplicationURLs(forContentType: type.contentTypeIdentifier) {
                guard let application = try? applicationInfo(at: url) else { continue }
                let bundleID = application.bundleIdentifier
                inferred[bundleID, default: []].append(type)
                if discoveredApplications[bundleID] == nil {
                    discoveredApplications[bundleID] = application
                }
            }
        }

        return discoveredApplications.values.map { app in
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
            }, searchAliases: app.searchAliases)
        }
    }

    func applicationInfo(at url: URL) throws -> ApplicationInfo {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url) else {
            throw AssociationError.invalidApplication(url)
        }
        guard let bundleID = bundle.bundleIdentifier else {
            throw AssociationError.missingBundleIdentifier(url)
        }
        guard let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AssociationError.missingApplicationExecutable(url)
        }
        let info = bundle.infoDictionary ?? [:]
        let fallbackName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let localName = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
        let name = localName.isEmpty ? fallbackName : localName
        let aliases = applicationNameAliases(bundle: bundle, url: url, info: info, displayName: name)
        let types = parseDocumentTypes(info: info)
        return ApplicationInfo(bundleIdentifier: bundleID, name: name, url: url,
                               supportedTypes: types, searchAliases: aliases)
    }

    func supportedURLSchemes(at url: URL) -> Set<String> {
        guard let info = Bundle(url: url)?.infoDictionary else { return [] }
        let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return Set(urlTypes.flatMap { stringArray($0["CFBundleURLSchemes"]) }
            .map { $0.lowercased() })
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
            guard isUsableDocumentType(document) else { continue }
            let identifiers = stringArray(document["LSItemContentTypes"])
            let legacyExtensions = stringArray(document["CFBundleTypeExtensions"])
            let declaredName = document["CFBundleTypeName"] as? String

            for identifier in identifiers {
                let type = UTType(identifier)
                let extensions = (declaredExtensions[identifier] ?? [])
                    + preferredExtensions(for: type)
                    + legacyExtensions
                result.append(SupportedType(
                    contentTypeIdentifier: identifier,
                    extensions: normalize(extensions),
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

    private func isUsableDocumentType(_ document: [String: Any]) -> Bool {
        let role = (document["CFBundleTypeRole"] as? String)?.lowercased()
        let rank = (document["LSHandlerRank"] as? String)?.lowercased()
        return role != "none" && rank != "none"
    }

    private func merging(_ inferredType: SupportedType,
                         into application: ApplicationInfo) -> ApplicationInfo {
        var types = application.supportedTypes
        if let index = types.firstIndex(where: {
            $0.contentTypeIdentifier == inferredType.contentTypeIdentifier
        }) {
            let existing = types[index]
            types[index] = SupportedType(
                contentTypeIdentifier: existing.contentTypeIdentifier,
                extensions: normalize(existing.extensions + inferredType.extensions),
                displayName: existing.displayName
            )
        } else {
            types.append(inferredType)
        }
        return ApplicationInfo(
            bundleIdentifier: application.bundleIdentifier,
            name: application.name,
            url: application.url,
            supportedTypes: types.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            searchAliases: application.searchAliases
        )
    }

    private func stringArray(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let value = value as? String { return [value] }
        return []
    }

    private func applicationNameAliases(bundle: Bundle, url: URL,
                                        info: [String: Any], displayName: String) -> [String] {
        var names = [
            displayName,
            url.deletingPathExtension().lastPathComponent,
            info["CFBundleDisplayName"] as? String,
            info["CFBundleName"] as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        ].compactMap { $0 }

        let resourcesURL = bundle.resourceURL
        let localizedFiles = resourcesURL.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])
        }?.filter { $0.pathExtension == "lproj" }
            .map { $0.appendingPathComponent("InfoPlist.strings") } ?? []

        for fileURL in localizedFiles {
            guard let data = try? Data(contentsOf: fileURL),
                  let dictionary = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil
                  ) as? [String: Any] else { continue }
            names.append(contentsOf: [
                dictionary["CFBundleDisplayName"] as? String,
                dictionary["CFBundleName"] as? String
            ].compactMap { $0 })
        }

        var seen = Set<String>()
        return names.filter {
            let normalized = $0.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                        locale: .current)
            return !$0.isEmpty && seen.insert(normalized).inserted
        }
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
