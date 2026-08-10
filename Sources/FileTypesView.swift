import SwiftUI

struct FileTypesView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var searchText = ""
    @State private var selection = Set<FileTypeInfo.ID>()
    @State private var presentedType: FileTypeInfo?
    @State private var addingExtension = false
    @State private var newExtension = ""
    @State private var sortOrder = [KeyPathComparator<FileTypeRow>(\.extensionName)]

    private var rows: [FileTypeRow] {
        let types = searchText.isEmpty ? store.fileTypes : store.fileTypes.filter {
            $0.extensionName.localizedCaseInsensitiveContains(searchText.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            || $0.displayName.localizedCaseInsensitiveContains(searchText)
            || $0.contentTypeIdentifier.localizedCaseInsensitiveContains(searchText)
        }
        return types.map { type in
            let app = store.defaultApplication(for: type)
            return FileTypeRow(type: type, defaultApplication: app)
        }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("扩展名", value: \.extensionName) { row in
                    Text(row.type.dottedExtension).font(.system(.body, design: .monospaced).weight(.semibold))
                }.width(min: 90, ideal: 110)
                TableColumn("文件类型", value: \.displayName) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.type.displayName)
                        Text(row.type.contentTypeIdentifier).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("当前默认 App", value: \.defaultAppName) { row in
                    DefaultAppLabel(application: row.defaultApplication)
                }.width(min: 190, ideal: 240)
                TableColumn("") { row in
                    Button("更改…") { presentedType = row.type }.buttonStyle(.borderless)
                }.width(58)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: FileTypeInfo.ID.self) { selected in
                if selected.count == 1, let id = selected.first,
                   let type = store.fileTypes.first(where: { $0.id == id }) {
                    Button("更改默认打开程序…") { presentedType = type }
                }
            } primaryAction: { selected in
                if let id = selected.first { presentedType = store.fileTypes.first { $0.id == id } }
            }
        }
        .sheet(item: $presentedType) { type in
            ApplicationPickerSheet(type: type, batchTypes: selectedTypes(including: type))
                .environmentObject(store)
        }
        .alert("添加文件扩展名", isPresented: $addingExtension) {
            TextField("例如：webp", text: $newExtension)
            Button("取消", role: .cancel) { newExtension = "" }
            Button("添加") {
                if store.addExtension(newExtension) { newExtension = "" }
            }
        } message: { Text("输入扩展名，不需要包含句点。") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("文件类型").font(.title2.weight(.semibold))
                Text("查看和批量更改文件的默认打开方式").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if selection.count > 1 { Text("已选择 \(selection.count) 项").foregroundStyle(.secondary) }
            SearchBox(prompt: "搜索扩展名", text: $searchText)
            Button { addingExtension = true } label: { Label("添加扩展名", systemImage: "plus") }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private func selectedTypes(including type: FileTypeInfo) -> [FileTypeInfo] {
        let chosen = store.fileTypes.filter { selection.contains($0.id) }
        return chosen.count > 1 && selection.contains(type.id) ? chosen : [type]
    }
}

private struct FileTypeRow: Identifiable {
    let type: FileTypeInfo
    let defaultApplication: ApplicationInfo?
    var id: String { type.id }
    var extensionName: String { type.extensionName }
    var displayName: String { type.displayName }
    var defaultAppName: String { defaultApplication?.name ?? "" }
}

private struct DefaultAppLabel: View {
    let application: ApplicationInfo?
    var body: some View {
        HStack(spacing: 8) {
            AppIcon(url: application?.url, size: 28)
            Text(application?.name ?? "未设置").foregroundStyle(application == nil ? .secondary : .primary)
        }
    }
}

private struct ApplicationPickerSheet: View {
    @EnvironmentObject private var store: AssociationStore
    @Environment(\.dismiss) private var dismiss
    let type: FileTypeInfo
    let batchTypes: [FileTypeInfo]
    @State private var applications: [ApplicationInfo] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(batchTypes.count > 1 ? "更改 \(batchTypes.count) 种文件的打开方式" : "\(type.dottedExtension) 的打开方式")
                        .font(.title2.weight(.semibold))
                    Text("选择后将应用于相应扩展名的所有文件").foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if applications.isEmpty {
                ContentUnavailableView("未找到可用的应用", systemImage: "app.badge.checkmark",
                                       description: Text("Launch Services 没有注册可打开此文件类型的应用。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(applications) { app in
                    Button {
                        store.setDefault(app, for: batchTypes)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            AppIcon(url: app.url, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).foregroundStyle(.primary)
                                Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.defaultApplication(for: type)?.bundleIdentifier == app.bundleIdentifier {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }.padding(.vertical, 3)
                    }.buttonStyle(.plain)
                }.scrollContentBackground(.hidden)
            }
        }
        .frame(width: 520, height: 520)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .onAppear { applications = store.capableApplications(for: type) }
    }
}
