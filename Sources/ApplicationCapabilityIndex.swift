import Foundation
import UniformTypeIdentifiers

struct ApplicationCapabilityIndex: Sendable {
    private var fileTypesByApplication: [String: [String: FileTypeInfo]] = [:]
    private var applicationIdentifiersByExtension: [String: Set<String>] = [:]

    mutating func insert<Identifiers: Sequence>(
        _ fileType: FileTypeInfo,
        for applicationIdentifiers: Identifiers
    ) where Identifiers.Element == String {
        let extensionName = fileType.extensionName.lowercased()
        for identifier in applicationIdentifiers {
            fileTypesByApplication[identifier, default: [:]][extensionName] = fileType
            applicationIdentifiersByExtension[extensionName, default: []].insert(identifier)
        }
    }

    func fileTypes(for applicationIdentifier: String) -> [FileTypeInfo] {
        (fileTypesByApplication[applicationIdentifier] ?? [:]).values.sorted {
            $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending
        }
    }

    func applicationIdentifiers(forExtension extensionName: String) -> Set<String> {
        applicationIdentifiersByExtension[extensionName.lowercased()] ?? []
    }

    var allFileTypes: [FileTypeInfo] {
        Dictionary(
            grouping: fileTypesByApplication.values.flatMap(\.values),
            by: \.extensionName
        ).compactMap(\.value.first).sorted {
            $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending
        }
    }
}

struct ApplicationCapabilityBuildResult: Sendable {
    let applications: [ApplicationInfo]
    let index: ApplicationCapabilityIndex
}

struct ApplicationCapabilityIndexer: Sendable {
    private let scanner = AppScanner()
    private let launchServices = LaunchServicesClient()

    func build(applications initialApplications: [ApplicationInfo],
               seedExtensions: [String],
               resolvedFileTypesByExtension: [String: FileTypeInfo] = [:])
    -> ApplicationCapabilityBuildResult {
        var applicationsByIdentifier: [String: ApplicationInfo] = [:]
        for application in initialApplications {
            applicationsByIdentifier[application.bundleIdentifier] = application
        }
        var pendingExtensions = Set(seedExtensions.compactMap(normalizedExtension))
        for application in initialApplications {
            pendingExtensions.formUnion(candidateExtensions(from: application))
        }

        var processedExtensions = Set<String>()
        var applicationIdentifiersByType = [String: Set<String>]()
        var index = ApplicationCapabilityIndex()

        while true {
            let batch = pendingExtensions.subtracting(processedExtensions).sorted()
            guard !batch.isEmpty else { break }
            processedExtensions.formUnion(batch)

            var fileTypesByIdentifier = [String: [FileTypeInfo]]()
            for extensionName in batch {
                guard let fileType = resolvedFileTypesByExtension[extensionName]
                        ?? (try? launchServices.fileType(for: extensionName)),
                      UTType(fileType.contentTypeIdentifier)?.isDynamic == false else { continue }
                fileTypesByIdentifier[fileType.contentTypeIdentifier, default: []].append(fileType)
            }

            for typeIdentifier in fileTypesByIdentifier.keys.sorted() {
                guard let fileTypes = fileTypesByIdentifier[typeIdentifier] else { continue }
                let applicationIdentifiers: Set<String>
                if let cached = applicationIdentifiersByType[typeIdentifier] {
                    applicationIdentifiers = cached
                } else {
                    var discoveredIdentifiers = Set<String>()
                    for url in launchServices.capableApplicationURLs(forContentType: typeIdentifier) {
                        guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { continue }
                        if applicationsByIdentifier[bundleIdentifier] == nil,
                           let application = try? scanner.applicationInfo(at: url) {
                            applicationsByIdentifier[bundleIdentifier] = application
                            pendingExtensions.formUnion(candidateExtensions(from: application))
                        }
                        if applicationsByIdentifier[bundleIdentifier] != nil {
                            discoveredIdentifiers.insert(bundleIdentifier)
                        }
                    }
                    applicationIdentifiersByType[typeIdentifier] = discoveredIdentifiers
                    applicationIdentifiers = discoveredIdentifiers
                }

                for fileType in fileTypes {
                    index.insert(fileType, for: applicationIdentifiers)
                }
            }
        }

        let applications = applicationsByIdentifier.values.map { application in
            var result = application
            let groupedTypes = Dictionary(
                grouping: index.fileTypes(for: application.bundleIdentifier),
                by: \.contentTypeIdentifier
            )
            for identifier in groupedTypes.keys.sorted() {
                guard let group = groupedTypes[identifier], let representative = group.first else { continue }
                let supportedType = SupportedType(
                    contentTypeIdentifier: identifier,
                    extensions: group.map(\.extensionName).sorted(),
                    displayName: representative.specificDisplayName
                )
                result = scanner.mergingVerifiedCapability(supportedType, into: result)
            }
            return result
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        return ApplicationCapabilityBuildResult(applications: applications, index: index)
    }

    private func candidateExtensions(from application: ApplicationInfo) -> Set<String> {
        let declared = application.documentTypes
            .filter { $0.source == .bundleDeclaration }
            .flatMap(\.extensions)
        return Set((declared + application.supportedTypes.flatMap(\.extensions))
            .compactMap(normalizedExtension))
    }

    private func normalizedExtension(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            .lowercased()
        guard !value.isEmpty, value != "*" else { return nil }
        return value
    }
}
