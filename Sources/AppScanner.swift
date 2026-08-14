import Foundation
import UniformTypeIdentifiers

struct AppScanner: Sendable {
    func applicationBundleSnapshot() -> Set<String> {
        Set(applicationBundleURLs().map { $0.standardizedFileURL.path })
    }

    func scanInstalledApplications(managedTypes: [FileTypeInfo]) -> [ApplicationInfo] {
        augmentWithLaunchServices(scanApplicationBundles(), managedTypes: managedTypes)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func scanDeclaredFileTypes() -> [SupportedType] {
        let types = scanApplicationBundles().flatMap { application in
            application.documentTypes.flatMap { document in
                document.extensions.compactMap { ext -> SupportedType? in
                    guard let type = UTType(filenameExtension: ext) else { return nil }
                    return SupportedType(contentTypeIdentifier: type.identifier,
                                         extensions: [ext],
                                         displayName: document.name)
                }
            }
        }
        return Dictionary(grouping: types, by: \SupportedType.id).compactMap(\.value.first)
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
            return mergingVerifiedCapability(inferredType, into: application)
        }
    }

    private func scanApplicationBundles() -> [ApplicationInfo] {
        var apps: [String: ApplicationInfo] = [:]
        for url in applicationBundleURLs() {
            if let app = try? applicationInfo(at: url) { apps[app.bundleIdentifier] = app }
        }
        return Array(apps.values)
    }

    private func applicationBundleURLs() -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { applicationURLs(in: $0, maximumDepth: 2) }
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
        var discoveredApplications: [String: ApplicationInfo] = [:]
        for application in applications {
            discoveredApplications[application.bundleIdentifier] = application
        }
        var knownTypes: [String: SupportedType] = [:]
        for type in managedTypes {
            if let existing = knownTypes[type.contentTypeIdentifier] {
                knownTypes[type.contentTypeIdentifier] = SupportedType(
                    contentTypeIdentifier: existing.contentTypeIdentifier,
                    extensions: normalize(existing.extensions + [type.extensionName]),
                    displayName: existing.displayName
                )
            } else {
                knownTypes[type.contentTypeIdentifier] = SupportedType(
                    contentTypeIdentifier: type.contentTypeIdentifier,
                    extensions: [type.extensionName],
                    displayName: type.displayName
                )
            }
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
            let supplementalDocuments: [ApplicationDocumentType] = inferred[
                app.bundleIdentifier, default: []
            ].map { type in
                ApplicationDocumentType(
                    id: "launch-services:\(type.contentTypeIdentifier)",
                    name: type.displayName,
                    extensions: type.extensions,
                    mimeTypes: [],
                    declaredTypeIdentifiers: [],
                    role: "—",
                    handlerRank: nil,
                    source: .launchServices
                )
            }
            return ApplicationInfo(bundleIdentifier: app.bundleIdentifier, name: app.name, url: app.url,
                                   documentTypes: coalescedApplicationDocumentTypes(
                                    app.documentTypes + supplementalDocuments
                                   ),
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
        let documents = parseDocumentTypes(info: info)
        let types = supportedTypes(from: documents, info: info)
        return ApplicationInfo(bundleIdentifier: bundleID, name: name, url: url,
                               documentTypes: documents,
                               supportedTypes: types, searchAliases: aliases)
    }

    func supportedURLSchemes(at url: URL) -> Set<String> {
        guard let info = Bundle(url: url)?.infoDictionary else { return [] }
        let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return Set(urlTypes.flatMap { stringArray($0["CFBundleURLSchemes"]) }
            .map { $0.lowercased() })
    }

    private func parseDocumentTypes(info: [String: Any]) -> [ApplicationDocumentType] {
        var result: [ApplicationDocumentType] = []
        for (index, document) in ((info["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []).enumerated() {
            guard isUsableDocumentType(document) else { continue }
            let identifiers = stringArray(document["LSItemContentTypes"])
            let extensions = normalize(stringArray(document["CFBundleTypeExtensions"]))
            let mimeTypes = stringArray(document["CFBundleTypeMIMETypes"])
            let name = (document["CFBundleTypeName"] as? String)
                ?? extensions.first.map { $0.uppercased() }
                ?? identifiers.first
                ?? "Document"
            result.append(ApplicationDocumentType(
                id: "bundle:\(index)",
                name: name,
                extensions: extensions,
                mimeTypes: mimeTypes,
                declaredTypeIdentifiers: identifiers,
                role: (document["CFBundleTypeRole"] as? String) ?? "None",
                handlerRank: document["LSHandlerRank"] as? String,
                source: .bundleDeclaration
            ))
        }
        return result
    }

    private func supportedTypes(from documents: [ApplicationDocumentType],
                                info: [String: Any]) -> [SupportedType] {
        var result: [SupportedType] = []
        let declarations = ((info["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? [])
            + ((info["UTImportedTypeDeclarations"] as? [[String: Any]]) ?? [])
        var declaredExtensions: [String: [String]] = [:]
        for declaration in declarations {
            guard let identifier = declaration["UTTypeIdentifier"] as? String else { continue }
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            declaredExtensions[identifier] = stringArray(tags?["public.filename-extension"])
        }

        for document in documents {
            for identifier in document.declaredTypeIdentifiers {
                let type = UTType(identifier)
                let extensions = (declaredExtensions[identifier] ?? [])
                    + preferredExtensions(for: type)
                result.append(SupportedType(
                    contentTypeIdentifier: identifier,
                    extensions: normalize(extensions),
                    displayName: document.name
                ))
            }
            if document.declaredTypeIdentifiers.isEmpty {
                for ext in document.extensions {
                    guard let type = UTType(filenameExtension: ext) else { continue }
                    result.append(SupportedType(
                        contentTypeIdentifier: type.identifier,
                        extensions: [ext.lowercased()],
                        displayName: document.name
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
        return role != "none" && role != "qlgenerator" && rank != "none"
    }

    func mergingVerifiedCapability(_ inferredType: SupportedType,
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
        var documentTypes = coalescedApplicationDocumentTypes(application.documentTypes)
        let launchServicesDocument = ApplicationDocumentType(
            id: "launch-services:\(inferredType.contentTypeIdentifier)",
            name: inferredType.displayName,
            extensions: inferredType.extensions,
            mimeTypes: [],
            declaredTypeIdentifiers: [],
            role: "—",
            handlerRank: nil,
            source: .launchServices
        )
        if let index = documentTypes.firstIndex(where: { $0.id == launchServicesDocument.id }) {
            let existing = documentTypes[index]
            documentTypes[index] = ApplicationDocumentType(
                id: existing.id,
                name: existing.name,
                extensions: normalize(existing.extensions + launchServicesDocument.extensions),
                mimeTypes: existing.mimeTypes,
                declaredTypeIdentifiers: existing.declaredTypeIdentifiers,
                role: existing.role,
                handlerRank: existing.handlerRank,
                source: .launchServices
            )
        } else {
            documentTypes.append(launchServicesDocument)
        }
        documentTypes = coalescedApplicationDocumentTypes(documentTypes)
        return ApplicationInfo(
            bundleIdentifier: application.bundleIdentifier,
            name: application.name,
            url: application.url,
            documentTypes: documentTypes,
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
