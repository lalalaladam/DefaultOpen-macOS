import SwiftUI

struct DefaultAppsView: View {
    @EnvironmentObject private var store: AssociationStore
    @EnvironmentObject private var languageSettings: LanguageSettings
    @State private var presentedCategory: DefaultAppCategory?
    @State private var editorRequest: DefaultAppCategoryEditorRequest?
    @State private var categoryPendingDeletion: DefaultAppCategory?
    @State private var refreshID = UUID()

    private var categories: [DefaultAppCategory] {
        _ = languageSettings.language
        return DefaultAppCategory.all + store.customDefaultAppCategories
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("默认 App")).font(.title2.weight(.semibold))
                    Text(L10n.string("一次设置一组常用文件格式或网页链接的默认应用"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editorRequest = DefaultAppCategoryEditorRequest(category: nil)
                } label: {
                    Label(L10n.string("新建组合…"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            Divider().opacity(0.45)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                    ForEach(categories) { category in
                        DefaultAppCategoryCard(category: category) {
                            presentedCategory = category
                        } editAction: {
                            editorRequest = DefaultAppCategoryEditorRequest(category: category)
                        } duplicateAction: {
                            editorRequest = DefaultAppCategoryEditorRequest(category: category, duplicatesCategory: true)
                        } deleteAction: {
                            categoryPendingDeletion = category
                        }
                        .environmentObject(store)
                    }
                }
                .id(refreshID)
                .padding(22)
            }
        }
        .sheet(item: $presentedCategory) { category in
            DefaultAppPickerSheet(category: category) {
                refreshID = UUID()
            }
            .environmentObject(store)
        }
        .sheet(item: $editorRequest) { request in
            DefaultAppCategoryEditorSheet(request: request) { id, title, subtitle, symbol, extensions in
                if store.saveCustomDefaultAppCategory(id: id, title: title, subtitle: subtitle,
                                                      symbol: symbol, extensions: extensions) {
                    editorRequest = nil
                    refreshID = UUID()
                    return true
                }
                return false
            }
        }
        .confirmationDialog(L10n.string("删除自定义组合？"), isPresented: Binding(
            get: { categoryPendingDeletion != nil },
            set: { if !$0 { categoryPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let category = categoryPendingDeletion {
                Button(L10n.format("action.deleteGroup", category.title), role: .destructive) {
                    store.removeCustomDefaultAppCategory(category)
                    categoryPendingDeletion = nil
                    refreshID = UUID()
                }
            }
            Button(L10n.string("取消"), role: .cancel) { categoryPendingDeletion = nil }
        } message: {
            Text(L10n.string("只会删除本应用保存的组合，不会撤销已经设置的系统文件关联。"))
        }
    }
}

private struct DefaultAppCategoryCard: View {
    @EnvironmentObject private var store: AssociationStore
    let category: DefaultAppCategory
    let changeAction: () -> Void
    let editAction: () -> Void
    let duplicateAction: () -> Void
    let deleteAction: () -> Void

    private var status: DefaultAppCategoryStatus {
        store.defaultAppStatus(for: category)
    }

    private var displayedSubtitle: String {
        if !category.subtitle.isEmpty { return category.subtitle }
        if category.coreExtensions.isEmpty { return L10n.string("尚未添加扩展名") }
        return category.coreExtensions.map { "." + $0 }.joined(separator: L10n.string("list.separator"))
    }

    private var hasTargets: Bool {
        !category.coreExtensions.isEmpty || !category.urlSchemes.isEmpty
    }

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: category.symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(category.title).font(.title3.weight(.semibold))
                    if category.isCustom {
                        Text(L10n.string("自定义"))
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(displayedSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(displayedSubtitle)
                currentLabel
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Button(L10n.string("更改…"), action: changeAction)
                    .buttonStyle(.bordered)
                    .disabled(!hasTargets)
                Menu {
                    if category.isCustom {
                        Button(L10n.string("编辑组合…"), action: editAction)
                    }
                    Button(L10n.string("复制为自定义组合…"), action: duplicateAction)
                    if category.isCustom {
                        Divider()
                        Button(L10n.string("删除组合…"), role: .destructive, action: deleteAction)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help(LanguageSettings.shared.string(category.isCustom ? "管理自定义组合" : "复制内置组合"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.08))
        }
    }

    @ViewBuilder private var currentLabel: some View {
        if !hasTargets {
            EmptyView()
        } else if status.isUnified, let app = status.unifiedApplication {
            HStack(spacing: 6) {
                AppIcon(url: app.url, size: 20)
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(L10n.string("当前默认"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .font(.body.weight(.medium))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label(L10n.string("尚未统一"), systemImage: "exclamationmark.circle")
                    .font(.body.weight(.medium)).foregroundStyle(.orange)
                ForEach(status.assignments.prefix(2)) { assignment in
                    Text(L10n.format(
                        "status.assignment",
                        assignment.application.name,
                        assignment.targets.joined(separator: L10n.string("list.separator"))
                    ))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if status.assignments.count > 2 {
                    Text(L10n.format("status.moreApps", status.assignments.count - 2))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !status.missingTargets.isEmpty {
                    Text(L10n.format("status.notSet", status.missingTargets.joined(separator: L10n.string("list.separator"))))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct DefaultAppCategoryEditorRequest: Identifiable {
    let id = UUID()
    let category: DefaultAppCategory?
    var duplicatesCategory = false
}

private struct DefaultAppCategoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AssociationStore
    let request: DefaultAppCategoryEditorRequest
    let onSave: (String?, String, String, String, [String]) -> Bool

    @State private var title: String
    @State private var subtitle: String
    @State private var symbol: String
    @State private var extensionDraft: String
    @State private var extensionNames: [String]
    @State private var choosingFileTypes = false
    @State private var scrollTarget: String?
    @State private var scrollRequestID = UUID()
    @State private var confirmingSaveWithDraft = false
    @FocusState private var focusedField: EditorField?

    private enum EditorField {
        case initial, title, subtitle, extensions
    }

    private static let symbols = [
        "folder", "doc", "doc.text", "chevron.left.forwardslash.chevron.right",
        "curlybraces", "paintbrush", "photo", "music.note", "play.rectangle",
        "archivebox", "shippingbox", "star"
    ]

    init(request: DefaultAppCategoryEditorRequest,
         onSave: @escaping (String?, String, String, String, [String]) -> Bool) {
        self.request = request
        self.onSave = onSave
        let category = request.category
        _title = State(initialValue: request.duplicatesCategory
                       ? L10n.format("group.copyName", category?.title ?? "") : category?.title ?? "")
        _subtitle = State(initialValue: category?.subtitle ?? "")
        _symbol = State(initialValue: category?.symbol ?? "folder")
        _extensionDraft = State(initialValue: "")
        _extensionNames = State(initialValue: category?.coreExtensions ?? [])
    }

    private var editingID: String? {
        request.duplicatesCategory ? nil : request.category?.id
    }

    private var normalizedExtensions: [String] {
        extensionNames.uniquedPreservingOrder()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(.tint).frame(width: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LanguageSettings.shared.string(editingID == nil ? "新建自定义组合" : "编辑自定义组合"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.string("把一组文件扩展名统一设置为同一个默认 App"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            Form {
                TextField(L10n.string("组合名称"), text: $title,
                          prompt: Text(L10n.string("例如：代码文件")))
                    .focused($focusedField, equals: .title)
                TextField(L10n.string("说明（可选）"), text: $subtitle,
                          prompt: Text(L10n.string("例如：常用源码与配置文件")))
                    .focused($focusedField, equals: .subtitle)
                Picker(L10n.string("图标"), selection: $symbol) {
                    ForEach(Self.symbols, id: \.self) { name in
                        Label(name, systemImage: name).tag(name)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    Text(L10n.string("扩展名"))
                        .frame(width: 88, alignment: .leading)
                        .padding(.top, 6)
                    ZStack(alignment: .topLeading) {
                        if extensionDraft.isEmpty {
                            Text(L10n.string("例如：swift, js, ts, py, json"))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 7)
                                .allowsHitTesting(false)
                        }
                        NativeMultilineTextEditor(text: $extensionDraft)
                            .focused($focusedField, equals: .extensions)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .topLeading)
                    .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(.primary.opacity(0.16))
                    }
                }
                HStack {
                    Button(L10n.string("添加")) { addDraftExtensions() }
                        .disabled(parsedExtensions(from: extensionDraft).isEmpty)
                    Spacer()
                    if !extensionNames.isEmpty {
                        Button(L10n.string("清空标签"), role: .destructive) {
                            extensionNames.removeAll()
                        }
                    }
                }
                Text(L10n.string("可直接输入或粘贴多个扩展名，使用逗号、空格、分号或换行分隔；句点会自动移除，重复项会自动合并。"))
                    .font(.caption).foregroundStyle(.secondary)
                if !normalizedExtensions.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: 7) {
                                ForEach(normalizedExtensions, id: \.self) { extensionName in
                                    HStack(spacing: 4) {
                                        Text(".\(extensionName)").font(.callout.monospaced())
                                        Button {
                                            removeExtension(extensionName)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help(L10n.format("action.removeExtension", extensionName))
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(.secondary.opacity(0.12), in: Capsule())
                                    .id(extensionName)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: scrollRequestID) { _, _ in
                            guard let latestExtension = scrollTarget else { return }
                            withAnimation {
                                proxy.scrollTo(latestExtension, anchor: .trailing)
                            }
                        }
                    }
                }
                HStack {
                    Button {
                        choosingFileTypes = true
                    } label: {
                        Label(L10n.string("从所有类型选择…"), systemImage: "checklist")
                    }
                    Spacer()
                    Text(L10n.format("status.extensionCount", normalizedExtensions.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(L10n.string("保存组合不会立即修改任何系统文件关联。"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("保存")) {
                    if parsedExtensions(from: extensionDraft).isEmpty {
                        save()
                    } else {
                        confirmingSaveWithDraft = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 600, height: 520)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .focusable()
        .focused($focusedField, equals: .initial)
        .defaultFocus($focusedField, .initial)
        .alert(L10n.string("还有未添加的扩展名"), isPresented: $confirmingSaveWithDraft) {
            Button(L10n.string("返回添加"), role: .cancel) { focusedField = .extensions }
            Button(L10n.string("忽略并保存")) { save() }
        } message: {
            Text(L10n.string("输入框中的扩展名尚未添加，不会保存到组合中。"))
        }
        .sheet(isPresented: $choosingFileTypes) {
            DefaultAppFileTypeSelectionSheet(initiallySelected: Set(normalizedExtensions)) { selected in
                extensionNames = selected.sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
                extensionDraft = ""
                scrollTarget = extensionNames.last
                scrollRequestID = UUID()
                choosingFileTypes = false
            }
            .environmentObject(store)
        }
    }

    private func removeExtension(_ extensionName: String) {
        extensionNames.removeAll { $0 == extensionName }
    }

    private func parsedExtensions(from text: String) -> [String] {
        text.components(separatedBy: Self.extensionSeparators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func addDraftExtensions() {
        let additions = parsedExtensions(from: extensionDraft)
        guard !additions.isEmpty else { return }
        let previous = Set(extensionNames)
        extensionNames = (extensionNames + additions).uniquedPreservingOrder()
        extensionDraft = ""
        scrollTarget = additions.last(where: { !previous.contains($0) })
        if scrollTarget != nil { scrollRequestID = UUID() }
        focusedField = .extensions
    }

    private func save() {
        if onSave(editingID, title, subtitle, symbol, normalizedExtensions) {
            dismiss()
        }
    }

    private static let extensionSeparators = CharacterSet(charactersIn: ",，;； \n\t")
}

private struct DefaultAppFileTypeSelectionSheet: View {
    @EnvironmentObject private var store: AssociationStore
    @Environment(\.dismiss) private var dismiss
    let onDone: (Set<String>) -> Void

    @State private var searchText = ""
    @State private var showsAllTypes = true
    @State private var selected: Set<String>

    init(initiallySelected: Set<String>, onDone: @escaping (Set<String>) -> Void) {
        self.onDone = onDone
        _selected = State(initialValue: initiallySelected)
    }

    private var rows: [FileTypeInfo] {
        let source = showsAllTypes ? store.allFileTypes : store.fileTypes
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let extensionQuery = query.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let filtered = query.isEmpty ? source : source.filter {
            $0.extensionName.localizedCaseInsensitiveContains(extensionQuery)
                || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.contentTypeIdentifier.localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted {
            $0.extensionName.localizedStandardCompare($1.extensionName) == .orderedAscending
        }
    }

    private var allVisibleSelected: Bool {
        !rows.isEmpty && rows.allSatisfy { selected.contains($0.extensionName.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("选择文件类型")).font(.title2.weight(.semibold))
                    Text(L10n.string("勾选要加入自定义组合的扩展名"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L10n.string("显示范围"), selection: $showsAllTypes) {
                    Text(L10n.string("常用类型")).tag(false)
                    Text(L10n.string("所有类型")).tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                SearchBox(prompt: "搜索扩展名、类型或 UTType", text: $searchText)
                    .frame(width: 250)
            }
            .padding(20)
            Divider()

            HStack {
                Button(LanguageSettings.shared.string(allVisibleSelected ? "取消选择搜索结果" : "全选搜索结果")) {
                    let visible = Set(rows.map { $0.extensionName.lowercased() })
                    if allVisibleSelected {
                        selected.subtract(visible)
                    } else {
                        selected.formUnion(visible)
                    }
                }
                .disabled(rows.isEmpty)
                Button(L10n.string("清除选择")) { selected.removeAll() }.disabled(selected.isEmpty)
                Spacer()
                if store.isLoadingFileTypes {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("正在载入所有类型…")).foregroundStyle(.secondary)
                } else {
                    Text(L10n.format("status.resultCount", rows.count)).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()

            if rows.isEmpty && store.isLoadingFileTypes {
                ProgressView(L10n.string("正在扫描系统声明的文件类型…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView(
                    L10n.format("search.noResults", searchText),
                    systemImage: "magnifyingglass",
                    description: Text(L10n.string("请尝试其他搜索关键词。"))
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { type in
                    Button {
                        toggle(type.extensionName)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(type.extensionName.lowercased())
                                  ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected.contains(type.extensionName.lowercased())
                                                 ? Color.accentColor : Color.secondary)
                            Text(type.dottedExtension)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .frame(width: 90, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.displayName).foregroundStyle(.primary)
                                Text(type.contentTypeIdentifier)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .scrollContentBackground(.hidden)
            }

            Divider()
            HStack {
                Text(L10n.format("status.selectedCount", selected.count))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("使用所选类型")) { onDone(selected) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 760, height: 650)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .task {
            if !store.hasLoadedAllFileTypes { await store.loadAllFileTypes() }
        }
    }

    private func toggle(_ extensionName: String) {
        let normalized = extensionName.lowercased()
        if selected.contains(normalized) {
            selected.remove(normalized)
        } else {
            selected.insert(normalized)
        }
    }
}

private struct DefaultAppPickerSheet: View {
    @EnvironmentObject private var store: AssociationStore
    @Environment(\.dismiss) private var dismiss
    let category: DefaultAppCategory
    let didChange: () -> Void
    @State private var includesOptional = false
    @State private var candidates: [DefaultAppCandidate] = []
    @State private var selectedCandidateID: DefaultAppCandidate.ID?
    @State private var customApplicationURL: URL?
    @State private var isApplying = false
    @State private var resultMessage: String?
    @State private var progressText: String?
    @State private var validationMessage: String?

    private var selectedCandidate: DefaultAppCandidate? {
        candidates.first { $0.id == selectedCandidateID }
    }

    private var currentStatus: DefaultAppCategoryStatus {
        store.defaultAppStatus(for: category)
    }

    private var optionalStatus: DefaultAppCategoryStatus {
        store.optionalDefaultAppStatus(for: category)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: category.symbol)
                    .font(.system(size: 25)).foregroundStyle(.tint).frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.title).font(.title2.weight(.semibold))
                    Text(targetDescription).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(L10n.string("当前状态：")).foregroundStyle(.secondary)
                    if let app = currentStatus.unifiedApplication {
                        AppIcon(url: app.url, size: 20)
                        Text(app.name).fontWeight(.medium)
                    } else {
                        Text(L10n.string("尚未统一")).fontWeight(.medium).foregroundStyle(.orange)
                    }
                    Spacer()
                }
                if !currentStatus.isUnified {
                    ForEach(currentStatus.assignments) { assignment in
                        Text(L10n.format(
                            "status.assignment",
                            assignment.application.name,
                            assignment.targets.joined(separator: L10n.string("list.separator"))
                        ))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !currentStatus.missingTargets.isEmpty {
                        Text(L10n.format("status.notSet", currentStatus.missingTargets.joined(separator: L10n.string("list.separator"))))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if category.hasOptionalExtensions {
                    Divider().padding(.vertical, 3)
                    HStack(spacing: 8) {
                        Text(L10n.string("扩展格式状态：")).foregroundStyle(.secondary)
                        if let app = optionalStatus.unifiedApplication {
                            AppIcon(url: app.url, size: 18)
                            Text(app.name).fontWeight(.medium)
                            Text(optionalDescription).foregroundStyle(.secondary)
                        } else {
                            Text(L10n.string("尚未统一"))
                                .fontWeight(.medium).foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    if !optionalStatus.isUnified {
                        ForEach(optionalStatus.assignments) { assignment in
                            Text(L10n.format(
                                "status.assignment",
                                assignment.application.name,
                                assignment.targets.joined(separator: L10n.string("list.separator"))
                            ))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if !optionalStatus.missingTargets.isEmpty {
                            Text(L10n.format(
                                "status.notSet",
                                optionalStatus.missingTargets.joined(separator: L10n.string("list.separator"))
                            ))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 10)

            if category.hasOptionalExtensions {
                Divider()
                Toggle(isOn: $includesOptional) {
                    VStack(alignment: .leading, spacing: 2) {
                    Text(LanguageSettings.shared.string(
                        category.urlSchemes.isEmpty
                            ? "同时设为扩展格式的默认 App"
                            : "同时设为本地网页文件的默认 App"
                    ))
                        Text(optionalDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .onChange(of: includesOptional) { _, _ in reloadCandidates() }
            }

            Divider()
            if candidates.isEmpty {
                ContentUnavailableView(L10n.string("没有找到可用的应用"), systemImage: "app.badge.checkmark",
                                       description: Text(L10n.string("系统没有注册能够处理这些类型的应用。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(candidates) { candidate in
                    Button {
                        selectedCandidateID = candidate.id
                        resultMessage = nil
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedCandidateID == candidate.id
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selectedCandidateID == candidate.id
                                                 ? Color.accentColor : Color.secondary)
                            AppIcon(url: candidate.application.url, size: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.application.name).foregroundStyle(.primary)
                                Text(candidate.application.bundleIdentifier)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if !candidate.currentTargets.isEmpty && !candidate.isCurrentDefault {
                                    Text(L10n.format("status.currentTargets", candidate.currentTargets.joined(separator: L10n.string("list.separator"))))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                                dimensions[.leading]
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                if candidate.isCurrentDefault {
                                    Label(L10n.string("当前默认"), systemImage: "checkmark.circle.fill")
                                        .font(.callout.weight(.medium)).foregroundStyle(.green)
                                }
                                Text(L10n.format("status.supportedFraction", candidate.supportedCount, candidate.totalCount))
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isApplying)
                }
                .scrollContentBackground(.hidden)
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let candidate = selectedCandidate {
                    Text(L10n.format("picker.setCategory", candidate.application.name, category.title))
                        .font(.headline)
                    Text(L10n.format("picker.willChange", candidate.supportedTargets.joined(separator: L10n.string("list.separator"))))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    let estimatedChanges = candidate.supportedTargets.filter {
                        !candidate.currentTargets.contains($0)
                    }.count
                    Text(L10n.format("picker.estimatedChanges", estimatedChanges))
                        .font(.caption).foregroundStyle(.secondary)
                    if !candidate.unsupportedTargets.isEmpty {
                        Text(L10n.format("picker.unsupportedTargets", candidate.unsupportedTargets.joined(separator: L10n.string("list.separator"))))
                            .font(.callout).foregroundStyle(.orange).lineLimit(2)
                    }
                } else {
                    Text(L10n.string("请先选择一个应用。点击应用不会立即修改系统设置。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let resultMessage {
                    Text(resultMessage).font(.callout.weight(.medium)).foregroundStyle(.green)
                }
                if let progressText {
                    Text(progressText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        chooseOtherApplication()
                    } label: {
                        Label(L10n.string("选择其他 App…"), systemImage: "folder")
                    }
                    .disabled(isApplying)
                    Spacer()
                    Button(L10n.string("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isApplying)
                    Button {
                        applySelection()
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                            Text(L10n.string("正在设置…"))
                        } else {
                            Text(L10n.format("action.setAsCategory", category.title))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCandidate == nil || isApplying)
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 680)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .onAppear { reloadCandidates() }
        .alert(L10n.string("无法使用所选 App"), isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button(L10n.string("好"), role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private var targetDescription: String {
        if !category.urlSchemes.isEmpty { return L10n.string("处理 HTTP 和 HTTPS 网页链接") }
        return category.coreExtensions.map { "." + $0 }.joined(separator: L10n.string("list.separator"))
    }

    private var optionalDescription: String {
        category.optionalExtensions.map { "." + $0 }.joined(separator: L10n.string("list.separator"))
    }

    private func reloadCandidates() {
        candidates = store.defaultAppCandidates(for: category, includingOptional: includesOptional)
        if let customApplicationURL {
            do {
                let candidate = try store.validatedDefaultAppCandidate(
                    at: customApplicationURL,
                    for: category,
                    includingOptional: includesOptional
                )
                insertCustomCandidate(candidate)
            } catch {
                self.customApplicationURL = nil
            }
        }
        if let selectedCandidateID,
           !candidates.contains(where: { $0.id == selectedCandidateID }) {
            self.selectedCandidateID = nil
        }
    }

    private func chooseOtherApplication() {
        guard let url = chooseApplicationURL() else { return }
        do {
            let candidate = try store.validatedDefaultAppCandidate(
                at: url,
                for: category,
                includingOptional: includesOptional
            )
            customApplicationURL = url
            insertCustomCandidate(candidate)
            selectedCandidateID = candidate.id
            resultMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func insertCustomCandidate(_ candidate: DefaultAppCandidate) {
        candidates.removeAll { $0.id == candidate.id }
        candidates.append(candidate)
        candidates.sort {
            if $0.supportedCount != $1.supportedCount {
                return $0.supportedCount > $1.supportedCount
            }
            return $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
        }
    }

    private func applySelection() {
        guard let candidate = selectedCandidate else { return }
        isApplying = true
        resultMessage = nil
        progressText = nil
        Task { @MainActor in
            await Task.yield()
            if let result = await store.setDefault(candidate.application, for: category,
                                                   includingOptional: includesOptional,
                                                   progress: { current, total, target in
                progressText = L10n.format("progress.setting", current, total, target)
            }) {
                didChange()
                let skipped = result.skippedTargets.isEmpty
                    ? "" : L10n.format("result.skipped", result.skippedTargets.joined(separator: L10n.string("list.separator")))
                let unchanged = result.unchangedTargets.isEmpty
                    ? "" : L10n.format("result.unchanged", result.unchangedTargets.count)
                resultMessage = L10n.format("result.changed", result.changedTargets.count, unchanged, skipped)
                progressText = nil
                try? await Task.sleep(for: .milliseconds(850))
                dismiss()
            } else {
                isApplying = false
            }
        }
    }
}

private extension Sequence where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
