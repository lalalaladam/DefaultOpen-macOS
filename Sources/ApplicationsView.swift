import AppKit
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
                    .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
                    .background(Color.clear)

                    if let app = store.applications.first(where: { $0.id == selectedAppID }) {
                        ApplicationDetailView(application: app)
                            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("选择一个应用程序", systemImage: "app",
                                               description: Text("查看它支持的文件类型并修改默认关联。"))
                            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
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
                Text("按名称或支持的文件类型筛选已安装的应用").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            SearchBox(prompt: "搜索应用或文件类型", text: $searchText)
                .help("可按应用名称、Bundle Identifier、扩展名或文件类型筛选。")
            Button { Task { await store.scanApplications() } } label: {
                Label(store.isScanning ? "正在扫描…" : "重新扫描", systemImage: "arrow.clockwise")
                    .frame(width: 96)
            }
            .buttonStyle(.bordered)
            .disabled(store.isScanning)
        }.padding(.horizontal, 22).padding(.vertical, 16)
    }
}

private struct ApplicationDetailView: View {
    @EnvironmentObject private var store: AssociationStore
    let application: ApplicationInfo
    @State private var selected = Set<SupportedType.ID>()
    @State private var sortColumn: SupportedTypeSortColumn = .extensionName
    @State private var sortAscending = true
    @State private var pendingDefaultChange: PendingDefaultChange?

    private var rows: [SupportedTypeRow] {
        application.supportedTypes.map { type in
            let current = currentDefault(for: type)
            return SupportedTypeRow(type: type, currentDefault: current,
                                    isApplicationDefault: current?.bundleIdentifier == application.bundleIdentifier)
        }.sorted { lhs, rhs in
            let lhsIsUnset = lhs.currentDefault == nil
            let rhsIsUnset = rhs.currentDefault == nil
            if lhsIsUnset != rhsIsUnset { return !lhsIsUnset }

            let comparison: ComparisonResult
            switch sortColumn {
            case .extensionName:
                comparison = lhs.extensionText.localizedStandardCompare(rhs.extensionText)
            case .typeName:
                comparison = lhs.typeSortText.localizedStandardCompare(rhs.typeSortText)
            case .defaultAppName:
                comparison = lhs.defaultAppName.localizedStandardCompare(rhs.defaultAppName)
            }
            if comparison == .orderedSame {
                return lhs.extensionText.localizedStandardCompare(rhs.extensionText) == .orderedAscending
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
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
            supportedTypesList
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { pendingDefaultChange != nil },
            set: { if !$0 { pendingDefaultChange = nil } }
        ), titleVisibility: .visible) {
            Button("继续设置") { applyPendingDefaultChange() }
            Button("取消", role: .cancel) { pendingDefaultChange = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var supportedTypesList: some View {
        GeometryReader { proxy in
            let extensionWidth = min(145, max(90, proxy.size.width * 0.18))
            let defaultAppWidth = min(195, max(145, proxy.size.width * 0.24))
            let actionWidth: CGFloat = 78
            let typeWidth = max(160, proxy.size.width - extensionWidth - defaultAppWidth - actionWidth - 72)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    sortableHeader("扩展名", column: .extensionName)
                        .frame(width: extensionWidth, alignment: .leading)
                    sortableHeader("文件类型 / UTType", column: .typeName)
                        .frame(width: typeWidth, alignment: .leading)
                    sortableHeader("当前默认 App", column: .defaultAppName)
                        .frame(width: defaultAppWidth, alignment: .leading)
                    Color.clear.frame(width: actionWidth)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 30)
                Divider()

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                Text(row.extensionText)
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(width: extensionWidth, alignment: .leading)
                                    .help(row.extensionText)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.type.displayName).lineLimit(1).truncationMode(.tail)
                                    Text(row.type.contentTypeIdentifier).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                .frame(width: typeWidth, alignment: .leading)
                                .help("\(row.type.displayName)\n\(row.type.contentTypeIdentifier)")
                                HStack(spacing: 7) {
                                    AppIcon(url: row.currentDefault?.url, size: 25)
                                    Text(row.currentDefault?.name ?? "未设置").lineLimit(1)
                                    if row.isApplicationDefault {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                    }
                                }
                                .frame(width: defaultAppWidth, alignment: .leading)
                                Button("设为默认") { makeDefault(row.type) }
                                    .buttonStyle(.borderless)
                                    .disabled(row.isApplicationDefault)
                                    .frame(width: actionWidth)
                            }
                            .padding(.horizontal, 12).frame(height: 52)
                            .background(selected.contains(row.id) ? Color.accentColor.opacity(0.18) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { selectRow(row.id) }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }

    private func selectRow(_ id: SupportedType.ID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            selected = [id]
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
        pendingDefaultChange = PendingDefaultChange(types: types, supportedTypeCount: 1)
    }

    private func makeSelectedDefault() {
        let types = application.supportedTypes.filter { selected.contains($0.id) }
            .flatMap { store.fileTypes(for: $0) }
        let unique = Dictionary(grouping: types, by: \FileTypeInfo.id).compactMap(\.value.first)
        guard !unique.isEmpty else {
            store.errorMessage = "所选类型没有可用于设置关联的文件扩展名。"
            return
        }
        pendingDefaultChange = PendingDefaultChange(types: unique, supportedTypeCount: selected.count)
    }

    private var confirmationTitle: String {
        guard let change = pendingDefaultChange else { return "确认设为默认？" }
        return change.supportedTypeCount == 1 ? "确认设为默认？" : "确认批量设为默认？"
    }

    private var confirmationMessage: String {
        guard let change = pendingDefaultChange else { return "" }
        let targets = change.types.map(\.dottedExtension).joined(separator: "、")
        return "将使用 \(application.name) 默认打开 \(targets)。继续后，macOS 还可能要求系统确认。"
    }

    private func applyPendingDefaultChange() {
        guard let change = pendingDefaultChange else { return }
        pendingDefaultChange = nil
        Task { await store.setDefault(application, for: change.types) }
    }

    private func sortableHeader(_ title: String, column: SupportedTypeSortColumn) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private enum SupportedTypeSortColumn {
    case extensionName, typeName, defaultAppName
}

private struct PendingDefaultChange {
    let types: [FileTypeInfo]
    let supportedTypeCount: Int
}

private struct SupportedTypeRow: Identifiable {
    let type: SupportedType
    let currentDefault: ApplicationInfo?
    let isApplicationDefault: Bool
    var id: String { type.id }
    var extensionText: String { type.extensions.isEmpty ? "—" : type.extensions.map { "." + $0 }.joined(separator: ", ") }
    var displayName: String { type.displayName }
    var typeSortText: String { "\(type.displayName) \(type.contentTypeIdentifier)" }
    var defaultAppName: String { currentDefault?.name ?? "" }
}
