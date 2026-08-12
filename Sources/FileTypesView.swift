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
    @State private var presentedAssociationDetails: FileTypeAssociationDetails?

    private var rows: [FileTypeRow] {
        let matches = store.matchingFileTypes(for: searchText, includeAll: showsAllTypes)
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
        .sheet(item: $presentedAssociationDetails) { details in
            FileTypeAssociationDetailsSheet(details: details)
                .environmentObject(store)
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
                            let otherRegisteredTypeCount = otherRegisteredTypes(for: row.type).count
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
                                        if otherRegisteredTypeCount > 0 {
                                            Button {
                                                showAssociationDetails(for: row.type)
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "info.circle.fill")
                                                    Text(L10n.format("status.otherRegisteredTypes",
                                                                     otherRegisteredTypeCount))
                                                    Image(systemName: "chevron.right")
                                                        .font(.system(size: 8, weight: .bold))
                                                }
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tint)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.accentColor.opacity(0.13), in: Capsule())
                                                .contentShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                            .help(L10n.string("查看此扩展名的其他注册文件类型"))
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
            SearchBox(prompt: "搜索扩展名或文件类型", text: $searchText)
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

    private func otherRegisteredTypes(for representative: FileTypeInfo) -> [FileTypeInfo] {
        store.registeredFileTypes(forExtension: representative.extensionName).filter {
            $0.contentTypeIdentifier != representative.contentTypeIdentifier
        }
    }

    private func showAssociationDetails(for representative: FileTypeInfo) {
        var types = store.registeredFileTypes(forExtension: representative.extensionName)
        if !types.contains(where: {
            $0.contentTypeIdentifier == representative.contentTypeIdentifier
        }) {
            types.insert(representative, at: 0)
        }
        types.sort { lhs, rhs in
            if lhs.contentTypeIdentifier == rhs.contentTypeIdentifier { return false }
            if lhs.contentTypeIdentifier == representative.contentTypeIdentifier { return true }
            if rhs.contentTypeIdentifier == representative.contentTypeIdentifier { return false }
            return lhs.contentTypeIdentifier.localizedStandardCompare(
                rhs.contentTypeIdentifier
            ) == .orderedAscending
        }
        let entries = types.map {
            FileTypeAssociationEntry(
                type: $0,
                defaultApplication: store.currentSystemDefaultApplication(for: $0),
                isDisplayedType: $0.contentTypeIdentifier == representative.contentTypeIdentifier
            )
        }
        presentedAssociationDetails = FileTypeAssociationDetails(
            representative: representative,
            entries: entries
        )
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

private struct FileTypeAssociationEntry: Identifiable {
    let type: FileTypeInfo
    let defaultApplication: ApplicationInfo?
    let isDisplayedType: Bool
    var id: String { type.contentTypeIdentifier }
}

private struct FileTypeAssociationDetails: Identifiable {
    let representative: FileTypeInfo
    let entries: [FileTypeAssociationEntry]
    var id: String { representative.id }
}

private struct FileTypeAssociationSummary: Identifiable {
    let application: ApplicationInfo?
    let typeCount: Int
    var id: String { application?.bundleIdentifier ?? "__not_set__" }
}

private struct FileTypeAssociationDetailsSheet: View {
    @EnvironmentObject private var store: AssociationStore
    @Environment(\.dismiss) private var dismiss
    let details: FileTypeAssociationDetails
    @State private var typeBeingChanged: FileTypeInfo?

    private var summaries: [FileTypeAssociationSummary] {
        Dictionary(grouping: details.entries) {
            currentApplication(for: $0)?.bundleIdentifier ?? "__not_set__"
        }.values.compactMap { entries in
            guard let first = entries.first else { return nil }
            return FileTypeAssociationSummary(
                application: currentApplication(for: first),
                typeCount: entries.count
            )
        }.sorted { lhs, rhs in
            if lhs.application == nil { return false }
            if rhs.application == nil { return true }
            return (lhs.application?.name ?? "").localizedStandardCompare(
                rhs.application?.name ?? ""
            ) == .orderedAscending
        }
    }

    private var displayedEntry: FileTypeAssociationEntry? {
        details.entries.first(where: \.isDisplayedType)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.format("association.title", details.representative.dottedExtension))
                        .font(.title2.weight(.semibold))
                    Text(L10n.string("主列表仅显示一个文件类型及其默认 App。其他注册类型不会由“更改…”操作修改。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let displayedEntry {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("主列表显示"))
                                .font(.headline)
                            associationRow(displayedEntry, showsIdentifier: true)
                                .padding(12)
                                .background(.primary.opacity(0.055),
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("按默认 App 汇总"))
                            .font(.headline)
                        ForEach(summaries) { summary in
                            HStack(spacing: 10) {
                                AppIcon(url: summary.application?.url, size: 28)
                                Text(summary.application?.name ?? L10n.string("未设置"))
                                Spacer()
                                Text(L10n.format("status.registeredTypeCount", summary.typeCount))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("注册文件类型"))
                            .font(.headline)
                        VStack(spacing: 0) {
                            ForEach(details.entries) { entry in
                                associationRow(entry, showsIdentifier: true)
                                    .padding(.vertical, 9)
                                if entry.id != details.entries.last?.id { Divider() }
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text(L10n.format("status.registeredTypeCount", details.entries.count))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("完成")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 540)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .sheet(item: $typeBeingChanged) { type in
            ApplicationPickerSheet(type: type)
                .environmentObject(store)
        }
    }

    private func associationRow(_ entry: FileTypeAssociationEntry,
                                showsIdentifier: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.type.specificDisplayName)
                    if entry.isDisplayedType {
                        Text(L10n.string("主列表"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                if showsIdentifier {
                    Text(entry.type.contentTypeIdentifier)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            let application = currentApplication(for: entry)
            AppIcon(url: application?.url, size: 26)
            Text(application?.name ?? L10n.string("未设置"))
                .frame(width: 125, alignment: .leading)
                .foregroundStyle(application == nil ? .secondary : .primary)
            Button(L10n.string("更改…")) {
                typeBeingChanged = entry.type
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func currentApplication(for entry: FileTypeAssociationEntry) -> ApplicationInfo? {
        store.defaultApplication(for: entry.type) ?? entry.defaultApplication
    }
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

    private var otherRegisteredTypeCount: Int {
        store.registeredFileTypes(forExtension: type.extensionName).filter {
            $0.contentTypeIdentifier != type.contentTypeIdentifier
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.format("picker.changeTypeDefaultTitle", type.dottedExtension))
                        .font(.title2.weight(.semibold))
                    Text(L10n.string("本次仅修改以下文件类型"))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(type.specificDisplayName).fontWeight(.medium)
                        Text(type.contentTypeIdentifier)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if otherRegisteredTypeCount > 0 {
                        Text(L10n.string("此扩展名的其他注册类型不会被修改。"))
                            .font(.caption).foregroundStyle(.secondary)
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
                        Text(L10n.format("picker.setAppForType", app.name, type.specificDisplayName))
                            .font(.headline)
                        Text(L10n.string("只会修改上方标明的文件类型。"))
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
                        applySelection()
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                            Text(L10n.string("正在设置…"))
                        } else {
                            Text(L10n.string("设为此类型默认"))
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
        .alert(L10n.string("无法使用所选 App"), isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button(L10n.string("好"), role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
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
