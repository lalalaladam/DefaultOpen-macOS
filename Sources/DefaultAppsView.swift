import SwiftUI

struct DefaultAppsView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var presentedCategory: DefaultAppCategory?
    @State private var editorRequest: DefaultAppCategoryEditorRequest?
    @State private var categoryPendingDeletion: DefaultAppCategory?
    @State private var refreshID = UUID()

    private var categories: [DefaultAppCategory] {
        DefaultAppCategory.all + store.customDefaultAppCategories
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("默认 App").font(.title2.weight(.semibold))
                    Text("一次设置一组常用文件格式或网页链接的默认应用")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editorRequest = DefaultAppCategoryEditorRequest(category: nil)
                } label: {
                    Label("新建组合…", systemImage: "plus")
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
        .confirmationDialog("删除自定义组合？", isPresented: Binding(
            get: { categoryPendingDeletion != nil },
            set: { if !$0 { categoryPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let category = categoryPendingDeletion {
                Button("删除“\(category.title)”", role: .destructive) {
                    store.removeCustomDefaultAppCategory(category)
                    categoryPendingDeletion = nil
                    refreshID = UUID()
                }
            }
            Button("取消", role: .cancel) { categoryPendingDeletion = nil }
        } message: {
            Text("只会删除本应用保存的组合，不会撤销已经设置的系统文件关联。")
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

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: category.symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(category.title).font(.headline)
                    if category.isCustom {
                        Text("自定义")
                            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(category.subtitle).font(.caption).foregroundStyle(.secondary)
                currentLabel
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Button("更改…", action: changeAction).buttonStyle(.bordered)
                Menu {
                    if category.isCustom {
                        Button("编辑组合…", action: editAction)
                    }
                    Button("复制为自定义组合…", action: duplicateAction)
                    if category.isCustom {
                        Divider()
                        Button("删除组合…", role: .destructive, action: deleteAction)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help(category.isCustom ? "管理自定义组合" : "复制内置组合")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.08))
        }
    }

    @ViewBuilder private var currentLabel: some View {
        if status.isUnified, let app = status.unifiedApplication {
            HStack(spacing: 6) {
                AppIcon(url: app.url, size: 20)
                Text(app.name).lineLimit(1)
                Text("当前默认").foregroundStyle(.secondary)
            }
            .font(.callout.weight(.medium))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label("尚未统一", systemImage: "exclamationmark.circle")
                    .font(.callout.weight(.medium)).foregroundStyle(.orange)
                ForEach(status.assignments.prefix(2)) { assignment in
                    Text("\(assignment.application.name)：\(assignment.targets.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if status.assignments.count > 2 {
                    Text("另有 \(status.assignments.count - 2) 个 App…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !status.missingTargets.isEmpty {
                    Text("未设置：\(status.missingTargets.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
    @State private var extensionText: String
    @State private var choosingFileTypes = false

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
                       ? "\(category?.title ?? "") 副本" : category?.title ?? "")
        _subtitle = State(initialValue: category?.subtitle ?? "")
        _symbol = State(initialValue: category?.symbol ?? "folder")
        _extensionText = State(initialValue: category?.coreExtensions.joined(separator: ", ") ?? "")
    }

    private var editingID: String? {
        request.duplicatesCategory ? nil : request.category?.id
    }

    private var normalizedExtensions: [String] {
        extensionText.components(separatedBy: CharacterSet(charactersIn: ",，;； \n\t"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased() }
            .filter { !$0.isEmpty }
            .uniquedPreservingOrder()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(.tint).frame(width: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(editingID == nil ? "新建自定义组合" : "编辑自定义组合")
                        .font(.title2.weight(.semibold))
                    Text("把一组文件扩展名统一设置为同一个默认 App")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            Form {
                TextField("组合名称", text: $title, prompt: Text("例如：代码文件"))
                TextField("说明", text: $subtitle, prompt: Text("例如：常用源码与配置文件"))
                Picker("图标", selection: $symbol) {
                    ForEach(Self.symbols, id: \.self) { name in
                        Label(name, systemImage: name).tag(name)
                    }
                }
                TextField("扩展名", text: $extensionText,
                          prompt: Text("例如：swift, js, ts, py, json"), axis: .vertical)
                    .lineLimit(3...6)
                Text("可用逗号、空格或换行分隔；句点会自动移除，重复项会自动合并。")
                    .font(.caption).foregroundStyle(.secondary)
                if !normalizedExtensions.isEmpty {
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
                                    .help("移除 .\(extensionName)")
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                HStack {
                    Button {
                        choosingFileTypes = true
                    } label: {
                        Label("从所有类型选择…", systemImage: "checklist")
                    }
                    Spacer()
                    Text("已包含 \(normalizedExtensions.count) 个扩展名")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("保存组合不会立即修改任何系统文件关联。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if onSave(editingID, title, subtitle, symbol, normalizedExtensions) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || normalizedExtensions.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 600, height: 520)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .sheet(isPresented: $choosingFileTypes) {
            DefaultAppFileTypeSelectionSheet(initiallySelected: Set(normalizedExtensions)) { selected in
                extensionText = selected.sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }.joined(separator: ", ")
                choosingFileTypes = false
            }
            .environmentObject(store)
        }
    }

    private func removeExtension(_ extensionName: String) {
        extensionText = normalizedExtensions.filter { $0 != extensionName }.joined(separator: ", ")
    }
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
                    Text("选择文件类型").font(.title2.weight(.semibold))
                    Text("勾选要加入自定义组合的扩展名")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("显示范围", selection: $showsAllTypes) {
                    Text("常用类型").tag(false)
                    Text("所有类型").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                SearchBox(prompt: "搜索扩展名、类型或 UTType", text: $searchText)
                    .frame(width: 250)
            }
            .padding(20)
            Divider()

            HStack {
                Button(allVisibleSelected ? "取消选择搜索结果" : "全选搜索结果") {
                    let visible = Set(rows.map { $0.extensionName.lowercased() })
                    if allVisibleSelected {
                        selected.subtract(visible)
                    } else {
                        selected.formUnion(visible)
                    }
                }
                .disabled(rows.isEmpty)
                Button("清除选择") { selected.removeAll() }.disabled(selected.isEmpty)
                Spacer()
                if store.isLoadingFileTypes {
                    ProgressView().controlSize(.small)
                    Text("正在载入所有类型…").foregroundStyle(.secondary)
                } else {
                    Text("找到 \(rows.count) 项").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()

            if rows.isEmpty && store.isLoadingFileTypes {
                ProgressView("正在扫描系统声明的文件类型…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: searchText)
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
                Text("已选择 \(selected.count) 项")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("使用所选类型") { onDone(selected) }
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
                    Text("当前状态：").foregroundStyle(.secondary)
                    if let app = currentStatus.unifiedApplication {
                        AppIcon(url: app.url, size: 20)
                        Text(app.name).fontWeight(.medium)
                    } else {
                        Text("尚未统一").fontWeight(.medium).foregroundStyle(.orange)
                    }
                    Spacer()
                }
                if !currentStatus.isUnified {
                    ForEach(currentStatus.assignments) { assignment in
                        Text("\(assignment.application.name)：\(assignment.targets.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !currentStatus.missingTargets.isEmpty {
                        Text("未设置：\(currentStatus.missingTargets.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 10)

            if category.hasOptionalExtensions {
                Divider()
                Toggle(isOn: $includesOptional) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.urlSchemes.isEmpty ? "包括扩展格式" : "同时设置本地网页文件")
                        Text(optionalDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .onChange(of: includesOptional) { _, _ in reloadCandidates() }
            }

            Divider()
            if candidates.isEmpty {
                ContentUnavailableView("没有找到可用的应用", systemImage: "app.badge.checkmark",
                                       description: Text("系统没有注册能够处理这些类型的应用。"))
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
                                    Text("当前负责：\(candidate.currentTargets.joined(separator: "、"))")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                if candidate.isCurrentDefault {
                                    Label("当前默认", systemImage: "checkmark.circle.fill")
                                        .font(.callout.weight(.medium)).foregroundStyle(.green)
                                }
                                Text("支持 \(candidate.supportedCount)/\(candidate.totalCount)")
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(isApplying)
                }
                .scrollContentBackground(.hidden)
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let candidate = selectedCandidate {
                    Text("将 \(candidate.application.name) 设为\(category.title)")
                        .font(.headline)
                    Text("将修改：\(candidate.supportedTargets.joined(separator: "、"))")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    let estimatedChanges = candidate.supportedTargets.filter {
                        !candidate.currentTargets.contains($0)
                    }.count
                    Text("预计需要修改 \(estimatedChanges) 项；macOS 可能逐项询问确认。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !candidate.unsupportedTargets.isEmpty {
                        Text("不会修改（应用未声明支持）：\(candidate.unsupportedTargets.joined(separator: "、"))")
                            .font(.callout).foregroundStyle(.orange).lineLimit(2)
                    }
                } else {
                    Text("请先选择一个应用。点击应用不会立即修改系统设置。")
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
                        Label("选择其他 App…", systemImage: "folder")
                    }
                    .disabled(isApplying)
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isApplying)
                    Button {
                        applySelection()
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                            Text("正在设置…")
                        } else {
                            Text("设为\(category.title)")
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
        .alert("无法使用所选 App", isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private var targetDescription: String {
        if !category.urlSchemes.isEmpty { return "处理 HTTP 和 HTTPS 网页链接" }
        return category.coreExtensions.map { "." + $0 }.joined(separator: "、")
    }

    private var optionalDescription: String {
        category.optionalExtensions.map { "." + $0 }.joined(separator: "、")
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
                progressText = "正在设置 \(current)/\(total)：\(target)"
            }) {
                didChange()
                let skipped = result.skippedTargets.isEmpty
                    ? "" : "；跳过：\(result.skippedTargets.joined(separator: "、"))"
                let unchanged = result.unchangedTargets.isEmpty
                    ? "" : "；无需修改 \(result.unchangedTargets.count) 项"
                resultMessage = "已修改 \(result.changedTargets.count) 项\(unchanged)\(skipped)"
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
