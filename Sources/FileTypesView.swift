import SwiftUI

struct FileTypesView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var searchText = ""
    @State private var presentedType: FileTypeInfo?
    @State private var addingExtension = false
    @State private var newExtension = ""
    @State private var showsAllTypes = false
    @State private var sortColumn: FileTypeSortColumn = .extensionName
    @State private var sortAscending = true
    @State private var highlightedTypeID: FileTypeInfo.ID?
    @State private var managingCustomExtensions = false
    @State private var typePendingDeletion: FileTypeInfo?

    private var rows: [FileTypeRow] {
        let types = store.matchingFileTypes(for: searchText, includeAll: showsAllTypes)
        return types.map { type in
            let app = store.defaultApplication(for: type)
            return FileTypeRow(type: type, defaultApplication: app)
        }.sorted { lhs, rhs in
            let lhsIsUnset = lhs.defaultApplication == nil
            let rhsIsUnset = rhs.defaultApplication == nil
            if lhsIsUnset != rhsIsUnset { return !lhsIsUnset }
            let comparison: ComparisonResult
            switch sortColumn {
            case .extensionName:
                comparison = lhs.extensionName.localizedStandardCompare(rhs.extensionName)
            case .displayName:
                comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            case .defaultAppName:
                comparison = lhs.defaultAppName.localizedStandardCompare(rhs.defaultAppName)
            }
            if comparison == .orderedSame {
                return lhs.extensionName.localizedStandardCompare(rhs.extensionName) == .orderedAscending
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
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
        .sheet(isPresented: $managingCustomExtensions) {
            CustomExtensionsSheet().environmentObject(store)
        }
        .confirmationDialog("删除自定义扩展名？", isPresented: Binding(
            get: { typePendingDeletion != nil },
            set: { if !$0 { typePendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let type = typePendingDeletion {
                Button(L10n.format("action.deleteExtension", type.dottedExtension), role: .destructive) {
                    store.removeCustomExtension(type)
                    typePendingDeletion = nil
                }
            }
            Button("取消", role: .cancel) { typePendingDeletion = nil }
        } message: {
            Text("只会移除本应用保存的自定义记录，不会删除任何文件或系统类型。")
        }
        .alert("添加文件扩展名", isPresented: $addingExtension) {
            TextField("例如：webp", text: $newExtension)
            Button("取消", role: .cancel) { newExtension = "" }
            Button("添加") {
                let normalized = newExtension.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased()
                if store.addExtension(newExtension) {
                    showsAllTypes = true
                    searchText = ""
                    highlightedTypeID = normalized
                    newExtension = ""
                    Task { await store.loadAllFileTypes() }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        if highlightedTypeID == normalized { highlightedTypeID = nil }
                    }
                }
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
                    sortableHeader("扩展名", column: .extensionName)
                        .frame(width: extensionWidth, alignment: .leading)
                    sortableHeader("文件类型", column: .displayName)
                        .frame(width: typeWidth, alignment: .leading)
                    sortableHeader("当前默认 App", column: .defaultAppName)
                        .frame(width: defaultAppWidth, alignment: .leading)
                    Color.clear.frame(width: actionWidth)
                }
                .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 34)
                Divider()

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                            HStack(spacing: 12) {
                                Text(row.type.dottedExtension)
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .lineLimit(1).frame(width: extensionWidth, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(row.type.displayName).lineLimit(1).truncationMode(.tail)
                                        if store.isCustomFileType(row.type) {
                                            Text("自定义")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(.secondary.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    Text(row.type.contentTypeIdentifier).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                .frame(width: typeWidth, alignment: .leading)
                                .help("\(row.type.displayName)\n\(row.type.contentTypeIdentifier)")
                                DefaultAppLabel(application: row.defaultApplication)
                                    .frame(width: defaultAppWidth, alignment: .leading)
                                Button("更改…") { presentedType = row.type }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                    .frame(width: actionWidth)
                            }
                            .padding(.horizontal, 12).frame(height: 56)
                            .background(row.id == highlightedTypeID ? Color.accentColor.opacity(0.14) : .clear)
                            .id(row.id)
                            .contextMenu {
                                if store.isCustomFileType(row.type) {
                                    Button("删除自定义扩展名…", role: .destructive) {
                                        typePendingDeletion = row.type
                                    }
                                }
                            }
                            Divider().padding(.leading, 12)
                            }
                        }
                    }
                    .onChange(of: highlightedTypeID) { _, id in
                        guard let id else { return }
                        withAnimation { scrollProxy.scrollTo(id, anchor: .center) }
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
            .frame(width: 220)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .onChange(of: showsAllTypes) { _, includeAll in
                if includeAll {
                    Task { await store.loadAllFileTypes() }
                }
            }
            ProgressView()
                .controlSize(.small)
                .opacity(store.isLoadingFileTypes ? 1 : 0)
                .accessibilityHidden(!store.isLoadingFileTypes)
                .help("正在载入全部类型…")
            .frame(width: 16, height: 16)
            SearchBox(prompt: "搜索扩展名或文件类型", text: $searchText)
            Button { addingExtension = true } label: { Label("添加扩展名", systemImage: "plus") }
                .buttonStyle(.bordered)
            Menu {
                Button("管理自定义扩展名…") { managingCustomExtensions = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("管理自定义扩展名")
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private func sortableHeader(_ title: String, column: FileTypeSortColumn) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(LanguageSettings.shared.string(title))
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                }
            }
        }
        .buttonStyle(.plain)
    }

}

private enum FileTypeSortColumn {
    case extensionName, displayName, defaultAppName
}

private struct CustomExtensionsSheet: View {
    @EnvironmentObject private var store: AssociationStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var typePendingDeletion: FileTypeInfo?

    private var types: [FileTypeInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.customFileTypes }
        return store.customFileTypes.filter {
            $0.extensionName.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.contentTypeIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("管理自定义扩展名").font(.title2.weight(.semibold))
                    Text("管理为补充系统扫描结果而手动添加的文件类型")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                SearchBox(prompt: "搜索自定义扩展名", text: $searchText)
                    .frame(width: 220)
            }
            .padding(20)
            Divider()
            if store.customFileTypes.isEmpty {
                ContentUnavailableView("没有自定义扩展名", systemImage: "doc.badge.plus",
                                       description: Text("手动添加的扩展名会显示在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if types.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(types) { type in
                    HStack(spacing: 12) {
                        Text(type.dottedExtension)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .frame(width: 90, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(type.displayName)
                            Text(type.contentTypeIdentifier).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        DefaultAppLabel(application: store.defaultApplication(for: type))
                            .frame(width: 180, alignment: .leading)
                        Button(role: .destructive) { typePendingDeletion = type } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.format("action.deleteExtension", type.dottedExtension))
                    }
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            }
            Divider()
            HStack {
                Text("删除只会移除本应用保存的记录。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 680, height: 480)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .confirmationDialog("删除自定义扩展名？", isPresented: Binding(
            get: { typePendingDeletion != nil },
            set: { if !$0 { typePendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let type = typePendingDeletion {
                Button(L10n.format("action.deleteExtension", type.dottedExtension), role: .destructive) {
                    store.removeCustomExtension(type)
                    typePendingDeletion = nil
                }
            }
            Button("取消", role: .cancel) { typePendingDeletion = nil }
        } message: {
            Text("不会删除任何文件，也不会修改系统的文件类型数据库。")
        }
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
            Text(application?.name ?? L10n.string("未设置"))
                .foregroundStyle(application == nil ? .secondary : .primary)
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
                    Text(L10n.format("picker.openWithTitle", type.dottedExtension))
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
                    Text(L10n.format("picker.setAppForExtension", app.name, type.dottedExtension))
                        .font(.headline)
                    Text(L10n.format("picker.extensionExplanation", type.dottedExtension))
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
