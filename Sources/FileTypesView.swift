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
    @State private var typePendingAddition: FileTypeInfo?
    @AppStorage("fileTypeSearchIncludesDisplayName") private var searchIncludesDisplayName = false
    @AppStorage("fileTypeSearchIncludesUTType") private var searchIncludesUTType = false

    private var rows: [FileTypeRow] {
        let matches = store.matchingFileTypes(
            for: searchText,
            includeAll: showsAllTypes,
            includesDisplayName: searchIncludesDisplayName,
            includesContentTypeIdentifier: searchIncludesUTType
        )
        return matches.map { match in
            let app = store.defaultApplication(for: match.type)
            return (row: FileTypeRow(type: match.type,
                                     defaultApplication: app,
                                     isUnregistered: match.rank == .unregistered),
                    rank: match.rank)
        }.sorted { lhs, rhs in
            if let lhsRank = lhs.rank, let rhsRank = rhs.rank, lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            let lhsIsUnset = lhs.row.defaultApplication == nil
            let rhsIsUnset = rhs.row.defaultApplication == nil
            if lhsIsUnset != rhsIsUnset { return !lhsIsUnset }
            let comparison: ComparisonResult
            switch sortColumn {
            case .extensionName:
                comparison = lhs.row.extensionName.localizedStandardCompare(rhs.row.extensionName)
            case .displayName:
                comparison = lhs.row.displayName.localizedStandardCompare(rhs.row.displayName)
            case .defaultAppName:
                comparison = lhs.row.defaultAppName.localizedStandardCompare(rhs.row.defaultAppName)
            }
            if comparison == .orderedSame {
                return lhs.row.extensionName.localizedStandardCompare(rhs.row.extensionName) == .orderedAscending
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }.map(\.row)
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
        .confirmationDialog(L10n.string("加入自定义扩展名？"), isPresented: Binding(
            get: { typePendingAddition != nil },
            set: { if !$0 { typePendingAddition = nil } }
        ), titleVisibility: .visible) {
            if let type = typePendingAddition {
                Button(L10n.format("action.addExtension", type.dottedExtension)) {
                    _ = store.addExtension(type.extensionName)
                    typePendingAddition = nil
                }
            }
            Button(L10n.string("取消"), role: .cancel) { typePendingAddition = nil }
        } message: {
            Text(L10n.string("只会将此扩展名保存到 DefaultOpen 的自定义类型，不会修改当前默认 App。"))
        }
        .confirmationDialog(L10n.string("删除自定义扩展名？"), isPresented: Binding(
            get: { typePendingDeletion != nil },
            set: { if !$0 { typePendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let type = typePendingDeletion {
                Button(L10n.format("action.deleteExtension", type.dottedExtension), role: .destructive) {
                    store.removeCustomExtension(type)
                    typePendingDeletion = nil
                }
            }
            Button(L10n.string("取消"), role: .cancel) { typePendingDeletion = nil }
        } message: {
            Text(L10n.string("只会移除 DefaultOpen 保存的自定义记录，不会解除或修改 macOS 默认打开关系。"))
        }
        .alert(L10n.string("添加文件扩展名"), isPresented: $addingExtension) {
            TextField(L10n.string("例如：webp"), text: $newExtension)
            Button(L10n.string("取消"), role: .cancel) { newExtension = "" }
            Button(L10n.string("添加")) {
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
        } message: { Text(L10n.string("输入扩展名，不需要包含句点。")) }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await store.loadAllFileTypes()
            }
            guard !Task.isCancelled else { return }
            await store.loadDefaultApplication(matchingExtensionSearch: searchText)
        }
    }

    private var fileTypeList: some View {
        GeometryReader { proxy in
            let extensionWidth: CGFloat = 96
            let defaultAppWidth = min(220, max(160, proxy.size.width * 0.24))
            let actionWidth: CGFloat = 142
            // Keep a stable gutter for the vertical scroller so its first appearance
            // cannot force the trailing columns to move.
            let typeWidth = max(180, proxy.size.width - extensionWidth - defaultAppWidth - actionWidth - 88)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    sortableHeader("扩展名", column: .extensionName, width: extensionWidth)
                    sortableHeader("文件类型", column: .displayName, width: typeWidth)
                    sortableHeader("此文件类型的默认 App", column: .defaultAppName, width: defaultAppWidth)
                    Color.clear.frame(width: actionWidth)
                }
                .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 34)
                Divider()

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                            let modificationRisk = store.modificationRisk(for: row.type)
                            HStack(spacing: 12) {
                                Text(row.type.dottedExtension)
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .lineLimit(1).frame(width: extensionWidth, alignment: .leading)
                                    .help(row.type.dottedExtension)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(row.type.displayName).lineLimit(1).truncationMode(.tail)
                                        if store.isCustomFileType(row.type) {
                                            Text(L10n.string("自定义"))
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(.secondary.opacity(0.12), in: Capsule())
                                        }
                                        if row.isUnregistered {
                                            Text(L10n.string(row.defaultApplication == nil
                                                ? "未收录" : "已关联，未收录"))
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(.secondary.opacity(0.12), in: Capsule())
                                        }
                                        if modificationRisk != .normal {
                                            Image(systemName: modificationRisk == .protected
                                                  ? "lock.fill" : "exclamationmark.triangle.fill")
                                                .font(.caption).foregroundStyle(.orange)
                                                .help(L10n.string(modificationRisk == .protected
                                                    ? "这是基础 UTType，仅供查看，不能修改默认 App。"
                                                    : "这是较宽泛的 UTType，修改可能影响其他扩展名。"))
                                        }
                                    }
                                    Text(row.type.contentTypeIdentifier).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                .frame(width: typeWidth, alignment: .leading)
                                .help("\(row.type.displayName)\n\(row.type.contentTypeIdentifier)")
                                DefaultAppLabel(application: row.defaultApplication)
                                    .frame(width: defaultAppWidth, alignment: .leading)
                                HStack(spacing: 6) {
                                    if row.isUnregistered, row.defaultApplication != nil {
                                        Button(L10n.string("加入自定义")) {
                                            typePendingAddition = row.type
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)
                                    }
                                    Button(L10n.string("更改…")) { presentedType = row.type }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)
                                        .disabled(modificationRisk == .protected)
                                }
                                .frame(width: actionWidth, alignment: .trailing)
                            }
                            .padding(.horizontal, 12).frame(height: 56)
                            .background(row.id == highlightedTypeID ? Color.accentColor.opacity(0.14) : .clear)
                            .id(row.id)
                            .contextMenu {
                                if store.isCustomFileType(row.type) {
                                    Button(L10n.string("删除自定义扩展名…"), role: .destructive) {
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
                Text(L10n.string("文件类型")).font(.title2.weight(.semibold))
                Text(L10n.string("查看和更改文件的默认打开方式"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Picker(L10n.string("显示范围"), selection: $showsAllTypes) {
                Text(L10n.string("常用类型")).tag(false)
                Text(L10n.string("全部类型")).tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 240)
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
                .help(L10n.string("正在载入全部类型…"))
            .frame(width: 16, height: 16)
            SearchBox(prompt: searchPrompt, text: $searchText)
                .help(L10n.string(searchScopeDescription))
            Menu {
                Toggle(L10n.string("文件类型名称"), isOn: $searchIncludesDisplayName)
                Toggle(L10n.string("UTType 标识符"), isOn: $searchIncludesUTType)
            } label: {
                Image(systemName: searchIncludesDisplayName || searchIncludesUTType
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .help(L10n.string(searchScopeDescription))
            Button { addingExtension = true } label: { Label(L10n.string("添加扩展名"), systemImage: "plus") }
                .buttonStyle(.bordered)
            Menu {
                Button(L10n.string("管理自定义扩展名…")) { managingCustomExtensions = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help(L10n.string("管理自定义扩展名"))
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var searchPrompt: String {
        if searchIncludesDisplayName && searchIncludesUTType {
            return "搜索全部字段"
        }
        if searchIncludesDisplayName { return "搜索扩展名和名称" }
        if searchIncludesUTType { return "搜索扩展名和 UTType" }
        return "搜索扩展名"
    }

    private var searchScopeDescription: String {
        if searchIncludesDisplayName && searchIncludesUTType {
            return "当前搜索：扩展名、文件类型名称和 UTType 标识符"
        }
        if searchIncludesDisplayName { return "当前搜索：扩展名和文件类型名称" }
        if searchIncludesUTType { return "当前搜索：扩展名和 UTType 标识符" }
        return "当前搜索：扩展名"
    }

    private func sortableHeader(_ title: String, column: FileTypeSortColumn,
                                width: CGFloat) -> some View {
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
                Spacer(minLength: 0)
            }
            .frame(width: width, height: 34, alignment: .leading)
            .contentShape(Rectangle())
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
                    Text(L10n.string("管理自定义扩展名")).font(.title2.weight(.semibold))
                    Text(L10n.string("管理为补充系统扫描结果而手动添加的文件类型"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                SearchBox(prompt: "搜索自定义扩展名", text: $searchText)
                    .frame(width: 220)
            }
            .padding(20)
            Divider()
            if store.customFileTypes.isEmpty {
                ContentUnavailableView(L10n.string("没有自定义扩展名"), systemImage: "doc.badge.plus",
                                       description: Text(L10n.string("手动添加的扩展名会显示在这里。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if types.isEmpty {
                ContentUnavailableView(
                    L10n.format("search.noResults", searchText),
                    systemImage: "magnifyingglass",
                    description: Text(L10n.string("请尝试其他搜索关键词。"))
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(types) { type in
                    HStack(spacing: 12) {
                        Text(type.dottedExtension)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1).truncationMode(.tail)
                            .help(type.dottedExtension)
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
                Text(L10n.string("删除只会移除本应用保存的记录。"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 680, height: 480)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .confirmationDialog(L10n.string("删除自定义扩展名？"), isPresented: Binding(
            get: { typePendingDeletion != nil },
            set: { if !$0 { typePendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let type = typePendingDeletion {
                Button(L10n.format("action.deleteExtension", type.dottedExtension), role: .destructive) {
                    store.removeCustomExtension(type)
                    typePendingDeletion = nil
                }
            }
            Button(L10n.string("取消"), role: .cancel) { typePendingDeletion = nil }
        } message: {
            Text(L10n.string("只会移除 DefaultOpen 保存的自定义记录，不会解除或修改 macOS 默认打开关系。"))
        }
    }
}

private struct FileTypeRow: Identifiable {
    let type: FileTypeInfo
    let defaultApplication: ApplicationInfo?
    var isUnregistered = false
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

struct ApplicationPickerSheet: View {
    @EnvironmentObject private var store: AssociationStore
    @Environment(\.dismiss) private var dismiss
    let type: FileTypeInfo
    @State private var applications: [ApplicationInfo] = []
    @State private var selectedApplicationID: ApplicationInfo.ID?
    @State private var isApplying = false
    @State private var validationMessage: String?
    @State private var confirmsBroadTypeChange = false

    private var selectedApplication: ApplicationInfo? {
        applications.first { $0.id == selectedApplicationID }
    }

    private var selectedApplicationIsCurrentDefault: Bool {
        guard let selectedApplication else { return false }
        return store.defaultApplication(for: type)?.bundleIdentifier
            == selectedApplication.bundleIdentifier
    }

    private var modificationRisk: FileTypeModificationRisk {
        store.modificationRisk(for: type)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.format("picker.openWithTitle", type.dottedExtension))
                        .font(.title2.weight(.semibold))
                    if modificationRisk == .protected {
                        Label(L10n.string("这个文件类型只能查看，不能修改默认 App。"),
                              systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else if modificationRisk == .broad {
                        Label(L10n.string("这项修改可能同时影响其他扩展名。"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
            }.padding(20)
            Divider()
            if applications.isEmpty {
                ContentUnavailableView(L10n.string("未找到可用的应用"), systemImage: "app.badge.checkmark",
                                       description: Text(L10n.string("Launch Services 没有注册可打开此文件类型的应用。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
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
                                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                                    dimensions[.leading]
                                }
                                Spacer()
                                if store.defaultApplication(for: type)?.bundleIdentifier == app.bundleIdentifier {
                                    Label(L10n.string("当前默认"), systemImage: "checkmark.circle.fill")
                                        .font(.callout.weight(.medium)).foregroundStyle(.green)
                                }
                            }
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isApplying)
                        .id(app.id)
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: selectedApplicationID) { _, applicationID in
                        guard let applicationID else { return }
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo(applicationID)
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    if let app = selectedApplication {
                        Text(L10n.format("picker.setAppForExtension", app.name, type.dottedExtension))
                            .font(.headline)
                        Text(L10n.format("picker.extensionExplanation", type.dottedExtension))
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.string("请先选择一个 App。点击应用不会立即修改系统设置。"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48,
                       alignment: .topLeading)
                HStack {
                    Button {
                        chooseOtherApplication()
                    } label: {
                        Label(L10n.string("选择其他 App…"), systemImage: "folder")
                    }
                    .disabled(isApplying)
                    Spacer()
                    Button(L10n.string("取消")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isApplying)
                    Button {
                        if modificationRisk == .broad {
                            confirmsBroadTypeChange = true
                        } else {
                            applySelection()
                        }
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                            Text(L10n.string("正在设置…"))
                        } else if selectedApplicationIsCurrentDefault {
                            Text(L10n.string("已是默认"))
                        } else {
                            Text(L10n.string("设为默认"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedApplication == nil || selectedApplicationIsCurrentDefault
                              || isApplying || modificationRisk == .protected)
                }
            }
            .padding(16)
        }
        .frame(width: 580, height: 620)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .onAppear {
            store.refreshDefaults(for: [type])
            applications = store.capableApplications(for: type)
        }
        .onChange(of: store.defaultAppRevision) { _, _ in
            store.refreshDefaults(for: [type])
            applications = store.capableApplications(for: type)
        }
        .alert(L10n.string("无法使用所选 App"), isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button(L10n.string("好"), role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
        .confirmationDialog(L10n.string("这项修改可能影响其他扩展名"),
                            isPresented: $confirmsBroadTypeChange,
                            titleVisibility: .visible) {
            Button(L10n.string("继续设置")) { applySelection() }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(L10n.string("macOS 会把一些扩展名作为同一种文件类型处理。继续后，它们的默认 App 也可能一起改变。"))
        }
    }

    private func chooseOtherApplication() {
        Task { @MainActor in
            guard let url = await chooseApplicationURL() else { return }
            useCustomApplication(at: url)
        }
    }

    private func useCustomApplication(at url: URL) {
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
        let shouldSaveAsCustomType = !store.isKnownFileType(type)
        isApplying = true
        Task { @MainActor in
            if await store.setDefault(application, for: [type]) {
                if shouldSaveAsCustomType {
                    _ = store.addExtension(type.extensionName)
                }
                dismiss()
            } else {
                isApplying = false
            }
        }
    }
}
