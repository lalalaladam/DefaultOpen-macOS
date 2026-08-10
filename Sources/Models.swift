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
    var id: Self { self }
    var symbol: String { self == .fileTypes ? "doc.badge.gearshape" : "square.grid.2x2" }
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
