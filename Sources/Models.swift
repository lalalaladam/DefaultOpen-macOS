import AppKit
import Foundation
import SwiftUI

struct ApplicationInfo: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let url: URL
    let supportedTypes: [SupportedType]

    var id: String { bundleIdentifier }
}

struct SupportedType: Identifiable, Hashable, Sendable {
    let contentTypeIdentifier: String
    let extensions: [String]
    let displayName: String

    var id: String { contentTypeIdentifier + extensions.joined(separator: ",") }
}

struct FileTypeInfo: Identifiable, Hashable, Sendable {
    let extensionName: String
    let contentTypeIdentifier: String
    let displayName: String

    var id: String { extensionName.lowercased() }
    var dottedExtension: String { "." + extensionName }
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

    static let all: [DefaultAppCategory] = [
        .init(id: "browser", title: "默认浏览器", subtitle: "网页链接与可选的本地网页文件",
              symbol: "safari", coreExtensions: [], optionalExtensions: ["html", "htm", "webarchive"],
              urlSchemes: ["http", "https"]),
        .init(id: "video", title: "默认视频播放器", subtitle: "常见视频文件的默认播放器",
              symbol: "play.rectangle", coreExtensions: ["mp4", "mov", "m4v"],
              optionalExtensions: ["mkv", "avi", "webm", "mpeg"], urlSchemes: []),
        .init(id: "music", title: "默认音乐播放器", subtitle: "常见音频文件的默认播放器",
              symbol: "music.note", coreExtensions: ["mp3", "m4a", "aac", "wav"],
              optionalExtensions: ["flac", "ogg", "aiff"], urlSchemes: []),
        .init(id: "image", title: "默认图片查看器", subtitle: "常见图片文件的默认查看器",
              symbol: "photo", coreExtensions: ["jpg", "jpeg", "png", "heic", "gif"],
              optionalExtensions: ["webp", "tiff", "bmp", "svg"], urlSchemes: []),
        .init(id: "pdf", title: "默认 PDF 阅读器", subtitle: "PDF 文档的默认阅读器",
              symbol: "doc.richtext", coreExtensions: ["pdf"], optionalExtensions: [], urlSchemes: []),
        .init(id: "text", title: "默认文本编辑器", subtitle: "纯文本与常见文本文件",
              symbol: "doc.plaintext", coreExtensions: ["txt", "log"],
              optionalExtensions: ["md", "rtf", "json", "xml", "yaml", "yml", "csv"], urlSchemes: []),
        .init(id: "archive", title: "默认解压软件", subtitle: "压缩包与归档文件的默认处理程序",
              symbol: "archivebox", coreExtensions: ["zip", "rar", "7z"],
              optionalExtensions: ["tar", "gz", "bz2", "xz"], urlSchemes: []),
        .init(id: "word", title: "默认 Word 文档 App", subtitle: "文字处理文档的默认编辑器",
              symbol: "doc.text", coreExtensions: ["doc", "docx"],
              optionalExtensions: ["odt"], urlSchemes: []),
        .init(id: "spreadsheet", title: "默认电子表格 App", subtitle: "工作簿与电子表格的默认编辑器",
              symbol: "tablecells", coreExtensions: ["xls", "xlsx"],
              optionalExtensions: ["ods", "csv"], urlSchemes: []),
        .init(id: "presentation", title: "默认演示文稿 App", subtitle: "幻灯片文件的默认编辑器",
              symbol: "rectangle.on.rectangle.angled", coreExtensions: ["ppt", "pptx"],
              optionalExtensions: ["odp"], urlSchemes: [])
    ]
}

struct DefaultAppCandidate: Identifiable {
    let application: ApplicationInfo
    let supportedCount: Int
    let totalCount: Int
    let supportedTargets: [String]
    let unsupportedTargets: [String]
    let currentTargets: [String]
    let isCurrentDefault: Bool
    var id: String { application.id }
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

    var body: some View {
        Group {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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
    }
}
