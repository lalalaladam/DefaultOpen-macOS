import SwiftUI

struct FileTypesView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var searchText = ""
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
            ApplicationPickerSheet(type: type)
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
            let actionWidth: CGFloat = 78
            // Keep a stable gutter for the vertical scroller so its first appearance
            // cannot force the trailing columns to move.
            let typeWidth = max(180, proxy.size.width - extensionWidth - defaultAppWidth - actionWidth - 88)

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
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .frame(width: actionWidth)
                            }
                            .padding(.horizontal, 12).frame(height: 52)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("文件类型").font(.title2.weight(.semibold))
                Text("查看和更改文件的默认打开方式").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("显示范围", selection: $showsAllTypes) {
                Text("常用类型").tag(false)
                Text("全部类型").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
            .onChange(of: showsAllTypes) { _, includeAll in
                if includeAll {
                    Task { await store.loadAllFileTypes() }
                }
            }
            ZStack {
                if store.isLoadingFileTypes {
                    ProgressView()
                        .controlSize(.small)
                        .help("正在载入全部类型…")
                }
            }
            .frame(width: 16, height: 16)
            SearchBox(prompt: "搜索扩展名或文件类型", text: $searchText)
            Button { addingExtension = true } label: { Label("添加扩展名", systemImage: "plus") }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
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
    @State private var applications: [ApplicationInfo] = []
    @State private var selectedApplicationID: ApplicationInfo.ID?
    @State private var isApplying = false
    @State private var validationMessage: String?

    private var selectedApplication: ApplicationInfo? {
        applications.first { $0.id == selectedApplicationID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(type.dottedExtension) 的打开方式")
                        .font(.title2.weight(.semibold))
                    Text("先选择一个 App，再确认设为默认").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            Divider()
            if applications.isEmpty {
                ContentUnavailableView("未找到可用的应用", systemImage: "app.badge.checkmark",
                                       description: Text("Launch Services 没有注册可打开此文件类型的应用。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(applications) { app in
                    Button {
                        selectedApplicationID = app.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedApplicationID == app.id
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selectedApplicationID == app.id
                                                 ? Color.accentColor : Color.secondary)
                            AppIcon(url: app.url, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).foregroundStyle(.primary)
                                Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.defaultApplication(for: type)?.bundleIdentifier == app.bundleIdentifier {
                                Label("当前默认", systemImage: "checkmark.circle.fill")
                                    .font(.callout.weight(.medium)).foregroundStyle(.green)
                            }
                        }.padding(.vertical, 3)
                    }.buttonStyle(.plain).disabled(isApplying)
                }
                .scrollContentBackground(.hidden)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let app = selectedApplication {
                    Text("将 \(app.name) 设为 \(type.dottedExtension) 的默认 App")
                        .font(.headline)
                    Text("修改后，所有 \(type.dottedExtension) 文件将默认使用此 App 打开。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("请先选择一个 App。点击应用不会立即修改系统设置。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        chooseOtherApplication()
                    } label: {
                        Label("选择其他 App…", systemImage: "folder")
                    }
                    .disabled(isApplying)
                    Spacer()
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isApplying)
                    Button {
                        applySelection()
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                            Text("正在设置…")
                        } else {
                            Text("设为默认")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedApplication == nil || isApplying)
                }
            }
            .padding(16)
        }
        .frame(width: 580, height: 620)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .onAppear { applications = store.capableApplications(for: type) }
        .alert("无法使用所选 App", isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private func chooseOtherApplication() {
        guard let url = chooseApplicationURL() else { return }
        do {
            let application = try store.validatedApplication(at: url, for: type)
            applications.removeAll { $0.bundleIdentifier == application.bundleIdentifier }
            applications.append(application)
            applications.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            selectedApplicationID = application.id
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func applySelection() {
        guard let application = selectedApplication else { return }
        isApplying = true
        Task { @MainActor in
            if await store.setDefault(application, for: [type]) {
                dismiss()
            } else {
                isApplying = false
            }
        }
    }
}
