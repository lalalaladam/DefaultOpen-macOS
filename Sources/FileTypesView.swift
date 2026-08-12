import SwiftUI
import UniformTypeIdentifiers

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
    @State private var expandedExtensions = Set<String>()
    @State private var managingCustomExtensions = false
    @State private var typePendingDeletion: FileTypeInfo?
    @State private var typePendingAddition: FileTypeInfo?

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

    private var groups: [FileTypeGroup] {
        Dictionary(grouping: rows, by: { $0.extensionName.lowercased() }).values.map {
            FileTypeGroup(rows: $0)
        }.sorted { lhs, rhs in
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
                    highlightedTypeID = store.fileTypes.first {
                        $0.extensionName.caseInsensitiveCompare(normalized) == .orderedSame
                    }?.id
                    expandedExtensions.insert(normalized)
                    let addedTypeID = highlightedTypeID
                    newExtension = ""
                    Task { await store.loadAllFileTypes() }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        if highlightedTypeID == addedTypeID { highlightedTypeID = nil }
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
            let query = searchText.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased()
            if !query.isEmpty {
                expandedExtensions.formUnion(groups.map(\.id))
            }
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
                    sortableHeader("当前默认 App", column: .defaultAppName, width: defaultAppWidth)
                    Color.clear.frame(width: actionWidth)
                }
                .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 34)
                Divider()

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(groups) { group in
                                FileTypeGroupView(
                                    group: group,
                                    isExpanded: expandedExtensions.contains(group.id),
                                    extensionWidth: extensionWidth,
                                    typeWidth: typeWidth,
                                    defaultAppWidth: defaultAppWidth,
                                    actionWidth: actionWidth,
                                    highlightedTypeID: highlightedTypeID,
                                    toggleExpanded: { toggleExpanded(group.id) },
                                    changeType: { presentedType = $0 },
                                    addType: { typePendingAddition = $0 },
                                    deleteType: { typePendingDeletion = $0 }
                                )
                                .environmentObject(store)
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

    private func toggleExpanded(_ extensionName: String) {
        if expandedExtensions.contains(extensionName) {
            expandedExtensions.remove(extensionName)
        } else {
            expandedExtensions.insert(extensionName)
        }
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

private struct FileTypeGroup: Identifiable {
    let rows: [FileTypeRow]
    init(rows: [FileTypeRow]) {
        let roots = rows.filter { row in
            guard let type = UTType(row.type.contentTypeIdentifier) else { return true }
            return !rows.contains { candidate in
                guard candidate.id != row.id,
                      let parent = UTType(candidate.type.contentTypeIdentifier) else { return false }
                return type.conforms(to: parent)
            }
        }.sorted {
            $0.type.contentTypeIdentifier.localizedStandardCompare(
                $1.type.contentTypeIdentifier
            ) == .orderedAscending
        }
        self.rows = rows.sorted { lhs, rhs in
            let lhsOrder = Self.order(for: lhs, roots: roots, allRows: rows)
            let rhsOrder = Self.order(for: rhs, roots: roots, allRows: rows)
            if lhsOrder.root != rhsOrder.root { return lhsOrder.root < rhsOrder.root }
            if lhsOrder.depth != rhsOrder.depth { return lhsOrder.depth < rhsOrder.depth }
            return lhs.type.contentTypeIdentifier.localizedStandardCompare(
                rhs.type.contentTypeIdentifier
            ) == .orderedAscending
        }
    }
    var id: String { extensionName }
    var extensionName: String { rows[0].extensionName.lowercased() }
    var displayName: String { rows[0].displayName }
    var defaultAppName: String { unifiedApplication?.name ?? "" }
    var relationshipGroupCount: Int {
        rows.filter { row in
            guard let type = UTType(row.type.contentTypeIdentifier) else { return true }
            return !rows.contains { candidate in
                guard candidate.id != row.id,
                      let parent = UTType(candidate.type.contentTypeIdentifier) else { return false }
                return type.conforms(to: parent)
            }
        }.count
    }
    var unifiedApplication: ApplicationInfo? {
        let applications = rows.compactMap(\.defaultApplication)
        guard applications.count == rows.count,
              Set(applications.map(\.bundleIdentifier)).count == 1 else { return nil }
        return applications[0]
    }

    private static func order(for row: FileTypeRow, roots: [FileTypeRow],
                              allRows: [FileTypeRow]) -> (root: Int, depth: Int) {
        guard let type = UTType(row.type.contentTypeIdentifier) else {
            return (roots.count, 0)
        }
        let rootIndex = roots.firstIndex { root in
            guard let rootType = UTType(root.type.contentTypeIdentifier) else { return false }
            return row.id == root.id || type.conforms(to: rootType)
        } ?? roots.count
        let depth = allRows.filter { candidate in
            guard candidate.id != row.id,
                  let ancestor = UTType(candidate.type.contentTypeIdentifier) else { return false }
            return type.conforms(to: ancestor)
        }.count
        return (rootIndex, depth)
    }
}

private struct FileTypeGroupView: View {
    @EnvironmentObject private var store: AssociationStore
    let group: FileTypeGroup
    let isExpanded: Bool
    let extensionWidth: CGFloat
    let typeWidth: CGFloat
    let defaultAppWidth: CGFloat
    let actionWidth: CGFloat
    let highlightedTypeID: FileTypeInfo.ID?
    let toggleExpanded: () -> Void
    let changeType: (FileTypeInfo) -> Void
    let addType: (FileTypeInfo) -> Void
    let deleteType: (FileTypeInfo) -> Void

    private var relationships: [String: FileTypeRelationship] {
        let identifiers = Set(group.rows.map { $0.type.contentTypeIdentifier })
        return Dictionary(uniqueKeysWithValues: group.rows.map { row in
            let type = UTType(row.type.contentTypeIdentifier)
            let parents = group.rows.filter { candidate in
                guard candidate.id != row.id,
                      let parent = UTType(candidate.type.contentTypeIdentifier),
                      type?.conforms(to: parent) == true else { return false }
                return !group.rows.contains { middle in
                    guard middle.id != row.id,
                          middle.id != candidate.id,
                          identifiers.contains(middle.type.contentTypeIdentifier),
                          let middleType = UTType(middle.type.contentTypeIdentifier) else { return false }
                    return type?.conforms(to: middleType) == true && middleType.conforms(to: parent)
                }
            }
            let hasChildren = group.rows.contains { candidate in
                guard let type,
                      candidate.id != row.id,
                      let child = UTType(candidate.type.contentTypeIdentifier) else { return false }
                return child.conforms(to: type)
            }
            return (row.id, FileTypeRelationship(parentCount: parents.count, hasChildren: hasChildren))
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggleExpanded) {
                HStack(spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text("." + group.extensionName)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                    }
                    .frame(width: extensionWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.displayName).lineLimit(1)
                        Text(L10n.format("status.typeAndGroupCount",
                                         group.rows.count, group.relationshipGroupCount))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: typeWidth, alignment: .leading)
                    if let application = group.unifiedApplication {
                        DefaultAppLabel(application: application)
                            .frame(width: defaultAppWidth, alignment: .leading)
                    } else {
                        Label(L10n.string("尚未统一"), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .frame(width: defaultAppWidth, alignment: .leading)
                    }
                    Color.clear.frame(width: actionWidth)
                }
                .padding(.horizontal, 12).frame(height: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(group.id)

            if isExpanded {
                ForEach(group.rows) { row in
                    let relationship = relationships[row.id]
                        ?? FileTypeRelationship(parentCount: 0, hasChildren: false)
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text(relationship.parentCount > 0 ? "└" : "•")
                                .foregroundStyle(.tertiary)
                            Text(relationship.parentCount > 0
                                 ? L10n.string("子类型")
                                 : L10n.string(relationship.hasChildren ? "基础类型" : "独立类型"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 18)
                        .frame(width: extensionWidth, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(row.type.specificDisplayName).lineLimit(1).truncationMode(.tail)
                                if store.isCustomFileType(row.type) {
                                    Text(L10n.string("自定义")).font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                if row.isUnregistered {
                                    Text(L10n.string(row.defaultApplication == nil ? "未收录" : "已关联，未收录"))
                                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                }
                            }
                            Text(row.type.contentTypeIdentifier)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(width: typeWidth, alignment: .leading)
                        .help("\(row.type.specificDisplayName)\n\(row.type.contentTypeIdentifier)")
                        DefaultAppLabel(application: row.defaultApplication)
                            .frame(width: defaultAppWidth, alignment: .leading)
                        HStack(spacing: 6) {
                            if row.isUnregistered, row.defaultApplication != nil {
                                Button(L10n.string("加入自定义")) { addType(row.type) }
                                    .buttonStyle(.bordered).controlSize(.regular)
                            }
                            Button(L10n.string("更改…")) { changeType(row.type) }
                                .buttonStyle(.bordered).controlSize(.regular)
                        }
                        .frame(width: actionWidth, alignment: .trailing)
                    }
                    .padding(.horizontal, 12).frame(height: 58)
                    .background(row.id == highlightedTypeID ? Color.accentColor.opacity(0.14) : .clear)
                    .id(row.id)
                    .contextMenu {
                        if store.isCustomFileType(row.type) {
                            Button(L10n.string("删除自定义扩展名…"), role: .destructive) {
                                deleteType(row.type)
                            }
                        }
                    }
                    Divider().padding(.leading, extensionWidth + 30)
                }
            }
            Divider()
        }
    }
}

private struct FileTypeRelationship {
    let parentCount: Int
    let hasChildren: Bool
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
                    Text(type.contentTypeIdentifier)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                    Text(L10n.string("先选择一个 App，再确认设为默认")).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            Divider()
            if applications.isEmpty {
                ContentUnavailableView(L10n.string("未找到可用的应用"), systemImage: "app.badge.checkmark",
                                       description: Text(L10n.string("Launch Services 没有注册可打开此文件类型的应用。")))
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
                                Label(L10n.string("当前默认"), systemImage: "checkmark.circle.fill")
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
                    Text(type.contentTypeIdentifier)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                } else {
                    Text(L10n.string("请先选择一个 App。点击应用不会立即修改系统设置。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
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
                            Text(L10n.string("设为默认"))
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
