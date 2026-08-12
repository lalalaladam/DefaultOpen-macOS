import AppKit
import Foundation
import SwiftUI

struct ApplicationInfo: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let url: URL
    let supportedTypes: [SupportedType]
    let searchAliases: [String]

    init(bundleIdentifier: String, name: String, url: URL,
         supportedTypes: [SupportedType], searchAliases: [String] = []) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.url = url
        self.supportedTypes = supportedTypes
        self.searchAliases = searchAliases
    }

    var id: String { bundleIdentifier }
}

struct SupportedType: Identifiable, Hashable, Sendable {
    let contentTypeIdentifier: String
    let extensions: [String]
    private let systemDisplayName: String

    init(contentTypeIdentifier: String, extensions: [String], displayName: String) {
        self.contentTypeIdentifier = contentTypeIdentifier
        self.extensions = extensions
        systemDisplayName = displayName
    }

    var id: String { contentTypeIdentifier + extensions.joined(separator: ",") }
    var displayName: String {
        L10n.fileTypeDisplayName(systemName: systemDisplayName,
                                 extensions: extensions,
                                 identifier: contentTypeIdentifier)
    }

    var fileTypes: [FileTypeInfo] {
        extensions.map {
            FileTypeInfo(extensionName: $0,
                         contentTypeIdentifier: contentTypeIdentifier,
                         displayName: systemDisplayName)
        }
    }
}

struct FileTypeInfo: Identifiable, Hashable, Sendable {
    let extensionName: String
    let contentTypeIdentifier: String
    private let systemDisplayName: String

    init(extensionName: String, contentTypeIdentifier: String, displayName: String) {
        self.extensionName = extensionName
        self.contentTypeIdentifier = contentTypeIdentifier
        systemDisplayName = displayName
    }

    var id: String { extensionName.lowercased() }
    var dottedExtension: String { "." + extensionName }
    var displayName: String {
        L10n.fileTypeDisplayName(systemName: systemDisplayName,
                                 extensions: [extensionName],
                                 identifier: contentTypeIdentifier)
    }
    var specificDisplayName: String { systemDisplayName }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case fileTypes = "文件类型"
    case applications = "应用程序"
    case defaultApps = "默认 App"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .fileTypes: "doc.badge.gearshape"
        case .applications: "square.grid.2x2"
        case .defaultApps: "checkmark.circle.fill"
        }
    }
}

struct DefaultAppCategory: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let coreExtensions: [String]
    let optionalExtensions: [String]
    let urlSchemes: [String]
    var isCustom = false

    var hasOptionalExtensions: Bool { !optionalExtensions.isEmpty }
    func extensions(includingOptional: Bool) -> [String] {
        coreExtensions + (includingOptional ? optionalExtensions : [])
    }

    @MainActor static var all: [DefaultAppCategory] {
        let localize = LanguageSettings.shared.string
        return [
        .init(id: "browser", title: localize("默认浏览器"), subtitle: localize("网页链接与可选的本地网页文件"),
              symbol: "safari", coreExtensions: [], optionalExtensions: ["html", "htm", "webarchive"],
              urlSchemes: ["http", "https"]),
        .init(id: "video", title: localize("默认视频播放器"), subtitle: localize("常见视频文件的默认播放器"),
              symbol: "play.rectangle", coreExtensions: ["mp4", "mov", "m4v"],
              optionalExtensions: ["mkv", "avi", "webm", "mpeg"], urlSchemes: []),
        .init(id: "music", title: localize("默认音乐播放器"), subtitle: localize("常见音频文件的默认播放器"),
              symbol: "music.note", coreExtensions: ["mp3", "m4a", "aac", "wav"],
              optionalExtensions: ["flac", "ogg", "aiff"], urlSchemes: []),
        .init(id: "image", title: localize("默认图片查看器"), subtitle: localize("常见图片文件的默认查看器"),
              symbol: "photo", coreExtensions: ["jpg", "jpeg", "png", "heic", "gif"],
              optionalExtensions: ["webp", "tiff", "bmp", "svg"], urlSchemes: []),
        .init(id: "pdf", title: localize("默认 PDF 阅读器"), subtitle: localize("PDF 文档的默认阅读器"),
              symbol: "doc.richtext", coreExtensions: ["pdf"], optionalExtensions: [], urlSchemes: []),
        .init(id: "text", title: localize("默认文本编辑器"), subtitle: localize("纯文本与常见文本文件"),
              symbol: "doc.plaintext", coreExtensions: ["txt", "log"],
              optionalExtensions: ["md", "rtf", "json", "xml", "yaml", "yml", "csv"], urlSchemes: []),
        .init(id: "archive", title: localize("默认解压软件"), subtitle: localize("压缩包与归档文件的默认处理程序"),
              symbol: "archivebox", coreExtensions: ["zip", "rar", "7z"],
              optionalExtensions: ["tar", "gz", "bz2", "xz"], urlSchemes: []),
        .init(id: "word", title: localize("默认 Word 文档 App"), subtitle: localize("文字处理文档的默认编辑器"),
              symbol: "doc.text", coreExtensions: ["doc", "docx"],
              optionalExtensions: ["odt"], urlSchemes: []),
        .init(id: "spreadsheet", title: localize("默认电子表格 App"), subtitle: localize("工作簿与电子表格的默认编辑器"),
              symbol: "tablecells", coreExtensions: ["xls", "xlsx"],
              optionalExtensions: ["ods", "csv"], urlSchemes: []),
        .init(id: "presentation", title: localize("默认演示文稿 App"), subtitle: localize("幻灯片文件的默认编辑器"),
              symbol: "rectangle.on.rectangle.angled", coreExtensions: ["ppt", "pptx"],
              optionalExtensions: ["odp"], urlSchemes: [])
        ]
    }
}

struct DefaultAppCandidate: Identifiable {
    let application: ApplicationInfo
    let supportedCount: Int
    let totalCount: Int
    let supportedTargets: [String]
    let unsupportedTargets: [String]
    let currentTargets: [String]
    let isCurrentDefault: Bool
    let typeDetails: [DefaultAppCandidateTypeDetail]
    var id: String { application.id }
}

struct DefaultAppCandidateTypeDetail: Identifiable {
    let id: String
    let label: String
    let typeName: String
    let technicalIdentifier: String
    let isSupported: Bool
    let isCurrentDefault: Bool
}

struct DefaultAppChangeResult {
    let changedTargets: [String]
    let skippedTargets: [String]
    let unchangedTargets: [String]
}

struct DefaultAppAssignment: Identifiable {
    let application: ApplicationInfo
    let targets: [String]
    var id: String { application.id }
}

struct DefaultAppCategoryStatus {
    let unifiedApplication: ApplicationInfo?
    let assignments: [DefaultAppAssignment]
    let missingTargets: [String]

    var isUnified: Bool { unifiedApplication != nil && missingTargets.isEmpty }
}

struct AppIcon: View {
    let url: URL?
    var size: CGFloat = 32
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .task(id: url?.path) {
            guard let url else {
                image = nil
                return
            }
            image = await ApplicationIconCache.shared.icon(for: url)
        }
    }
}

private final class ApplicationIconCache: @unchecked Sendable {
    static let shared = ApplicationIconCache()

    private let images = NSCache<NSURL, NSImage>()
    private let lock = NSLock()

    private init() {
        images.countLimit = 256
    }

    func icon(for url: URL) async -> NSImage {
        if let cached = cachedIcon(for: url) { return cached }

        let image = await Task.detached(priority: .userInitiated) {
            NSWorkspace.shared.icon(forFile: url.path)
        }.value

        lock.withLock {
            images.setObject(image, forKey: url as NSURL)
        }
        return image
    }

    private func cachedIcon(for url: URL) -> NSImage? {
        lock.withLock {
            images.object(forKey: url as NSURL)
        }
    }
}
