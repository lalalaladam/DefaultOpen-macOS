import AppKit
import SwiftUI

struct FileTypesView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var searchText = ""
    @State private var selection = Set<FileTypeInfo.ID>()
    @State private var presentedType: FileTypeInfo?
    @State private var addingExtension = false
    @State private var newExtension = ""
    @State private var showsAllTypes = false
    @State private var sortOrder = [KeyPathComparator<FileTypeRow>(\.extensionName)]

    private var rows: [FileTypeRow] {
        let types = store.matchingFileTypes(for: searchText, includeAll: showsAllTypes)
        return types.map { type in
            let app = store.defaultApplication(for: type)
            return FileTypeRow(type: type, defaultApplication: app)
        }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            fileTypeList
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

    private var fileTypeList: some View {
        GeometryReader { proxy in
            let extensionWidth: CGFloat = 96
            let defaultAppWidth = min(220, max(160, proxy.size.width * 0.24))
            let actionWidth: CGFloat = 62
            let typeWidth = max(180, proxy.size.width - extensionWidth - defaultAppWidth - actionWidth - 72)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("扩展名").frame(width: extensionWidth, alignment: .leading)
                    Text("文件类型").frame(width: typeWidth, alignment: .leading)
                    Text("当前默认 App").frame(width: defaultAppWidth, alignment: .leading)
                    Color.clear.frame(width: actionWidth)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 30)
                Divider()

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                Text(row.type.dottedExtension)
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .lineLimit(1).frame(width: extensionWidth, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.type.displayName).lineLimit(1).truncationMode(.tail)
                                    Text(row.type.contentTypeIdentifier).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                .frame(width: typeWidth, alignment: .leading)
                                .help("\(row.type.displayName)\n\(row.type.contentTypeIdentifier)")
                                DefaultAppLabel(application: row.defaultApplication)
                                    .frame(width: defaultAppWidth, alignment: .leading)
                                Button("更改…") { presentedType = row.type }
                                    .buttonStyle(.borderless).frame(width: actionWidth)
                            }
                            .padding(.horizontal, 12).frame(height: 52)
                            .background(selection.contains(row.id) ? Color.accentColor.opacity(0.18) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { presentedType = row.type }
                            .onTapGesture { selectRow(row.id) }
                            .contextMenu {
                                Button("更改默认打开程序…") { presentedType = row.type }
                            }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }

    private func selectRow(_ id: FileTypeInfo.ID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("文件类型").font(.title2.weight(.semibold))
                Text("查看和批量更改文件的默认打开方式").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if selection.count > 1 { Text("已选择 \(selection.count) 项").foregroundStyle(.secondary) }
            Button {
                selection.removeAll()
                if showsAllTypes {
                    showsAllTypes = false
                } else {
                    showsAllTypes = true
                    Task { await store.loadAllFileTypes() }
                }
            } label: {
                if store.isLoadingFileTypes {
                    Label("正在载入类型…", systemImage: "list.bullet")
                } else {
                    Label(showsAllTypes ? "仅显示常用类型" : "显示全部类型",
                          systemImage: showsAllTypes ? "line.3.horizontal.decrease.circle.fill" : "list.bullet")
                }
            }
            .buttonStyle(.bordered)
            .disabled(store.isLoadingFileTypes)
            SearchBox(prompt: "搜索扩展名或文件类型", text: $searchText)
            Button { addingExtension = true } label: { Label("添加扩展名", systemImage: "plus") }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private func selectedTypes(including type: FileTypeInfo) -> [FileTypeInfo] {
        let chosen = store.allFileTypes.filter { selection.contains($0.id) }
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
    @State private var isApplying = false

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
                        isApplying = true
                        Task { @MainActor in
                            if await store.setDefault(app, for: batchTypes) { dismiss() }
                            else { isApplying = false }
                        }
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
                    }.buttonStyle(.plain).disabled(isApplying)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 520, height: 520)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .onAppear { applications = store.capableApplications(for: type) }
    }
}
