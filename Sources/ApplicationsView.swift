import SwiftUI

struct ApplicationsView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var searchText = ""
    @State private var selectedAppID: String?

    private var filteredApps: [ApplicationInfo] {
        guard !searchText.isEmpty else { return store.applications }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = query.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return store.applications.filter { app in
            app.name.localizedCaseInsensitiveContains(query)
            || app.bundleIdentifier.localizedCaseInsensitiveContains(query)
            || app.supportedTypes.contains { type in
                type.extensions.contains(ext)
                || type.displayName.localizedCaseInsensitiveContains(query)
                || type.contentTypeIdentifier.localizedCaseInsensitiveContains(query)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            if store.isScanning && store.applications.isEmpty {
                ProgressView("正在扫描应用程序及其文档类型…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.applications.isEmpty {
                VStack(spacing: 14) {
                    ContentUnavailableView("尚未扫描应用程序", systemImage: "square.grid.2x2",
                                           description: Text("扫描应用 Bundle 中声明的文档类型与 UTType。"))
                    Button("开始扫描") { Task { await store.scanApplications() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(filteredApps, selection: $selectedAppID) { app in
                        HStack(spacing: 10) {
                            AppIcon(url: app.url, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                Text(app.bundleIdentifier).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 3).tag(app.id)
                    }
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 245, idealWidth: 285, maxWidth: 340)
                    .background(Color.clear)

                    if let app = store.applications.first(where: { $0.id == selectedAppID }) {
                        ApplicationDetailView(application: app)
                            .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("选择一个应用程序", systemImage: "app",
                                               description: Text("查看它支持的文件类型并修改默认关联。"))
                            .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task { if store.applications.isEmpty { await store.scanApplications() } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("应用程序").font(.title2.weight(.semibold))
                Text("搜索应用名称，或输入 .pdf 查看支持该格式的应用").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isScanning { ProgressView().controlSize(.small) }
            SearchBox(prompt: "搜索应用或扩展名", text: $searchText)
                .help("输入应用名称、Bundle Identifier，或 .pdf 这样的扩展名，筛选支持该格式的应用。")
            Button { Task { await store.scanApplications() } } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }.buttonStyle(.bordered).disabled(store.isScanning)
        }.padding(.horizontal, 22).padding(.vertical, 16)
    }
}

private struct ApplicationDetailView: View {
    @EnvironmentObject private var store: AssociationStore
    let application: ApplicationInfo
    @State private var selected = Set<SupportedType.ID>()
    @State private var sortOrder = [KeyPathComparator<SupportedTypeRow>(\.extensionText)]

    private var rows: [SupportedTypeRow] {
        application.supportedTypes.map { type in
            let current = currentDefault(for: type)
            return SupportedTypeRow(type: type, currentDefault: current,
                                    isApplicationDefault: current?.bundleIdentifier == application.bundleIdentifier)
        }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AppIcon(url: application.url, size: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(application.name).font(.title2.weight(.semibold))
                    Text(application.bundleIdentifier).font(.callout).foregroundStyle(.secondary)
                    Text("支持 \(application.supportedTypes.count) 种文档类型").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if !selected.isEmpty {
                    Button("将所选类型设为默认") { makeSelectedDefault() }.buttonStyle(.borderedProminent)
                }
            }.padding(20)
            Divider().opacity(0.45)
            Table(rows, selection: $selected, sortOrder: $sortOrder) {
                TableColumn("扩展名", value: \.extensionText) { row in
                    Text(row.extensionText)
                        .font(.system(.callout, design: .monospaced)).lineLimit(2)
                }.width(min: 100, ideal: 160)
                TableColumn("文件类型 / UTType", value: \.displayName) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.type.displayName)
                        Text(row.type.contentTypeIdentifier).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("当前默认 App", value: \.defaultAppName) { row in
                    HStack(spacing: 7) {
                        AppIcon(url: row.currentDefault?.url, size: 25)
                        Text(row.currentDefault?.name ?? "未设置").lineLimit(1)
                        if row.isApplicationDefault {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                }.width(min: 160, ideal: 210)
                TableColumn("") { row in
                    Button("设为默认") { makeDefault(row.type) }
                        .buttonStyle(.borderless)
                        .disabled(row.isApplicationDefault)
                }.width(70)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
        }
    }

    private func currentDefault(for type: SupportedType) -> ApplicationInfo? {
        guard let fileType = store.fileTypes(for: type).first else { return nil }
        return store.defaultApplication(for: fileType)
    }

    private func makeDefault(_ supportedType: SupportedType) {
        let types = store.fileTypes(for: supportedType)
        guard !types.isEmpty else {
            store.errorMessage = "此 UTType 没有声明可用于设置关联的文件扩展名。"
            return
        }
        store.setDefault(application, for: types)
    }

    private func makeSelectedDefault() {
        let types = application.supportedTypes.filter { selected.contains($0.id) }
            .flatMap { store.fileTypes(for: $0) }
        let unique = Dictionary(grouping: types, by: \FileTypeInfo.id).compactMap(\.value.first)
        guard !unique.isEmpty else {
            store.errorMessage = "所选类型没有可用于设置关联的文件扩展名。"
            return
        }
        store.setDefault(application, for: unique)
    }
}

private struct SupportedTypeRow: Identifiable {
    let type: SupportedType
    let currentDefault: ApplicationInfo?
    let isApplicationDefault: Bool
    var id: String { type.id }
    var extensionText: String { type.extensions.isEmpty ? "—" : type.extensions.map { "." + $0 }.joined(separator: ", ") }
    var displayName: String { type.displayName }
    var defaultAppName: String { currentDefault?.name ?? "" }
}
