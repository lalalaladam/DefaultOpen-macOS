import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationsView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var searchText = ""
    @State private var selectedAppID: String?

    private var searchResults: [ApplicationSearchResult] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.applications.compactMap { ApplicationSearchResult(application: $0, query: query) }
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
            }
    }

    private var searchResultIDs: [ApplicationInfo.ID] { searchResults.map(\.application.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            if store.isScanning && store.applications.isEmpty {
                ProgressView(L10n.string("正在扫描应用程序及其文档类型…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.applications.isEmpty {
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        L10n.string("尚未扫描应用程序"),
                        systemImage: "square.grid.2x2",
                        description: Text(L10n.string("扫描应用 Bundle 中声明的文档格式，并补充 Launch Services 打开能力。"))
                    )
                    Button(L10n.string("开始扫描")) { Task { await store.scanApplications() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    applicationList
                    detail
                }
            }
        }
        .onChange(of: searchResultIDs) { _, resultIDs in
            guard let selectedAppID, !resultIDs.contains(selectedAppID) else { return }
            self.selectedAppID = nil
        }
        .task(id: searchText) {
            if store.applications.isEmpty { await store.scanApplications() }
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await store.loadApplications(matchingExtensionSearch: searchText)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("应用程序")).font(.title2.weight(.semibold))
                Text(L10n.string("按名称或扩展名筛选已安装的应用"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            SearchBox(prompt: "搜索应用、扩展名或 UTType", text: $searchText)
            Button { Task { await store.scanApplications() } } label: {
                Label(LanguageSettings.shared.string(store.isScanning ? "正在扫描…" : "重新扫描"),
                      systemImage: "arrow.clockwise")
                    .frame(width: 96)
            }
            .buttonStyle(.bordered)
            .disabled(store.isScanning)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var applicationList: some View {
        List(searchResults) { result in
            let app = result.application
            let isSelected = selectedAppID == app.id
            Button { selectedAppID = app.id } label: {
                HStack(spacing: 10) {
                    AppIcon(url: app.url, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).foregroundStyle(isSelected ? Color.white : Color.primary)
                        Text(result.subtitle).font(.caption2)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                            .lineLimit(1).help(result.subtitle)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .scrollContentBackground(.hidden)
        .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
    }

    @ViewBuilder private var detail: some View {
        if let result = searchResults.first(where: { $0.application.id == selectedAppID }) {
            ApplicationDetailView(application: result.application,
                                  matchingExtensions: result.matchingExtensions)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                L10n.string("选择一个应用程序"),
                systemImage: "app",
                description: Text(L10n.string("查看它支持的扩展名并修改默认打开方式。"))
            )
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ApplicationDetailView: View {
    @EnvironmentObject private var store: AssociationStore
    let application: ApplicationInfo
    let matchingExtensions: Set<String>
    @State private var selected = Set<String>()
    @State private var sortColumn: ExtensionSortColumn = .extensionName
    @State private var sortAscending = true
    @State private var showsVolumeParts = false
    @State private var showsDeclarationDetails = false
    @State private var pendingDefaultChange: PendingDefaultChange?

    private var rows: [ApplicationExtensionRow] {
        var documentsByExtension: [String: [ApplicationDocumentType]] = [:]
        for document in application.documentTypes {
            for rawExtension in document.extensions {
                let extensionName = rawExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased()
                guard !extensionName.isEmpty, extensionName != "*" else { continue }
                documentsByExtension[extensionName, default: []].append(document)
            }
        }

        return documentsByExtension.compactMap { extensionName, documents in
            guard let fileType = store.inferredFileType(forExtension: extensionName) else { return nil }
            let current = store.defaultApplication(for: fileType)
            return ApplicationExtensionRow(
                fileType: fileType,
                currentDefault: current,
                isApplicationDefault: current?.bundleIdentifier == application.bundleIdentifier,
                role: extensionRole(for: documents),
                isVolumePart: isVolumePartExtension(extensionName)
            )
        }
        .sorted(by: rowSort)
    }

    private var hiddenVolumePartCount: Int {
        guard !showsVolumeParts else { return 0 }
        return rows.filter { $0.isVolumePart && !matchingExtensions.contains($0.id) }.count
    }

    private var visibleRows: [ApplicationExtensionRow] {
        rows.filter { !$0.isVolumePart || showsVolumeParts || matchingExtensions.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider().opacity(0.45)
            if rows.isEmpty {
                ContentUnavailableView(
                    L10n.string("没有可设置的扩展名"),
                    systemImage: "doc.badge.ellipsis",
                    description: Text(L10n.string("该 App 没有可映射为系统推测 UTType 的扩展名声明。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                extensionTable
            }
        }
        .sheet(isPresented: $showsDeclarationDetails) {
            ApplicationDeclarationDetailsView(application: application)
        }
        .confirmationDialog(L10n.string("确认设为默认？"), isPresented: Binding(
            get: { pendingDefaultChange != nil },
            set: { if !$0 { pendingDefaultChange = nil } }
        ), titleVisibility: .visible) {
            Button(L10n.string("继续设置")) { applyPendingDefaultChange() }
            Button(L10n.string("取消"), role: .cancel) { pendingDefaultChange = nil }
        } message: {
            Text(confirmationMessage)
        }
        .onChange(of: application.id) { _, _ in
            selected.removeAll()
            showsVolumeParts = false
            pendingDefaultChange = nil
        }
        .task(id: application.id) {
            store.refreshDefaults(for: rows.map(\.fileType))
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 14) {
            AppIcon(url: application.url, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(application.name).font(.title2.weight(.semibold))
                Text(application.bundleIdentifier).font(.callout).foregroundStyle(.secondary)
                Text(L10n.format("application.extensionCount", rows.count))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(L10n.string("声明详情…")) { showsDeclarationDetails = true }
                .buttonStyle(.bordered)
            if !selected.isEmpty {
                Button(L10n.string("将所选扩展名设为默认")) { makeSelectedDefault() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private var extensionTable: some View {
        GeometryReader { proxy in
            let extensionWidth = min(130, max(90, proxy.size.width * 0.16))
            let defaultAppWidth = min(195, max(145, proxy.size.width * 0.24))
            let actionWidth: CGFloat = 78
            let roleWidth: CGFloat = 66
            let typeWidth = max(160, proxy.size.width - extensionWidth - defaultAppWidth
                                - actionWidth - roleWidth - 84)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    sortableHeader("扩展名", column: .extensionName, width: extensionWidth)
                    sortableHeader("文件类型 / UTType", column: .typeName, width: typeWidth)
                    Text(L10n.string("角色")).frame(width: roleWidth, alignment: .leading)
                    sortableHeader("当前默认 App", column: .defaultAppName, width: defaultAppWidth)
                    Color.clear.frame(width: actionWidth)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 30)
                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleRows) { row in
                            extensionRow(row, extensionWidth: extensionWidth, typeWidth: typeWidth,
                                         roleWidth: roleWidth, defaultAppWidth: defaultAppWidth,
                                         actionWidth: actionWidth)
                            Divider().padding(.leading, 12)
                        }
                        if hiddenVolumePartCount > 0 {
                            Button {
                                showsVolumeParts = true
                            } label: {
                                Label(L10n.format("application.showVolumeExtensions", hiddenVolumePartCount),
                                      systemImage: "chevron.down")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).frame(height: 38)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func extensionRow(_ row: ApplicationExtensionRow, extensionWidth: CGFloat,
                              typeWidth: CGFloat, roleWidth: CGFloat,
                              defaultAppWidth: CGFloat, actionWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Text(row.fileType.dottedExtension).font(.system(.callout, design: .monospaced))
                if matchingExtensions.contains(row.id) {
                    Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.orange)
                }
            }
            .frame(width: extensionWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.fileType.displayName).lineLimit(1).truncationMode(.tail)
                Text(row.fileType.contentTypeIdentifier).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: typeWidth, alignment: .leading)
            .help("\(row.fileType.displayName)\n\(row.fileType.contentTypeIdentifier)")

            roleBadge(row.role).frame(width: roleWidth, alignment: .leading)

            HStack(spacing: 7) {
                AppIcon(url: row.currentDefault?.url, size: 25)
                Text(row.currentDefault?.name ?? L10n.string("未设置")).lineLimit(1)
                if row.isApplicationDefault {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            .frame(width: defaultAppWidth, alignment: .leading)

            Button(L10n.string("设为默认")) { makeDefault(row) }
                .buttonStyle(.borderless)
                .disabled(row.isApplicationDefault || store.modificationRisk(for: row.fileType) == .protected)
                .frame(width: actionWidth)
        }
        .padding(.horizontal, 12).frame(height: 52)
        .background(selected.contains(row.id) ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectRow(row.id) }
    }

    private func roleBadge(_ role: ApplicationExtensionRole) -> some View {
        Label(L10n.string(role.title), systemImage: role.symbol)
            .font(.caption2).foregroundStyle(role == .viewer ? Color.orange : Color.secondary)
            .help(L10n.string(role.helpText))
    }

    private func sortableHeader(_ title: String, column: ExtensionSortColumn,
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
            .frame(width: width, height: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowSort(_ lhs: ApplicationExtensionRow, _ rhs: ApplicationExtensionRow) -> Bool {
        let lhsMatch = matchingExtensions.contains(lhs.id)
        let rhsMatch = matchingExtensions.contains(rhs.id)
        if lhsMatch != rhsMatch { return lhsMatch }

        let comparison: ComparisonResult
        switch sortColumn {
        case .extensionName:
            comparison = lhs.fileType.extensionName.localizedStandardCompare(rhs.fileType.extensionName)
        case .typeName:
            comparison = (lhs.fileType.displayName + lhs.fileType.contentTypeIdentifier)
                .localizedStandardCompare(rhs.fileType.displayName + rhs.fileType.contentTypeIdentifier)
        case .defaultAppName:
            comparison = (lhs.currentDefault?.name ?? "")
                .localizedStandardCompare(rhs.currentDefault?.name ?? "")
        }
        if comparison == .orderedSame {
            return lhs.fileType.extensionName.localizedStandardCompare(rhs.fileType.extensionName) == .orderedAscending
        }
        return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private func selectRow(_ id: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            selected = [id]
        }
    }

    private func makeDefault(_ row: ApplicationExtensionRow) {
        guard store.modificationRisk(for: row.fileType) != .protected else {
            store.errorMessage = L10n.string("基础 UTType 仅供查看，不能修改默认 App。")
            return
        }
        pendingDefaultChange = PendingDefaultChange(types: [row.fileType], hasViewer: row.role == .viewer)
    }

    private func makeSelectedDefault() {
        let chosenRows = rows.filter { selected.contains($0.id) }
        let types = Dictionary(grouping: chosenRows.map(\.fileType), by: \.contentTypeIdentifier)
            .compactMap(\.value.first)
        guard !types.isEmpty else { return }
        guard !types.contains(where: { store.modificationRisk(for: $0) == .protected }) else {
            store.errorMessage = L10n.string("所选项目包含只读基础 UTType，请取消选择后重试。")
            return
        }
        pendingDefaultChange = PendingDefaultChange(
            types: types,
            hasViewer: chosenRows.contains(where: { $0.role == .viewer })
        )
    }

    private var confirmationMessage: String {
        guard let change = pendingDefaultChange else { return "" }
        let extensions = change.types.map(\.dottedExtension)
            .joined(separator: L10n.string("list.separator"))
        var message = L10n.format("application.confirmExtensions", application.name, extensions)
        if change.hasViewer {
            message += "\n\n" + L10n.string("该 App 将作为查看器打开文件，可能无法编辑或保存。")
        }
        let broad = change.types.filter { store.modificationRisk(for: $0) == .broad }
        if !broad.isEmpty {
            message += "\n\n" + L10n.format(
                "typeRisk.batchConfirmation",
                Array(Set(broad.map(\.contentTypeIdentifier))).sorted()
                    .joined(separator: L10n.string("list.separator"))
            )
        }
        return message
    }

    private func applyPendingDefaultChange() {
        guard let change = pendingDefaultChange else { return }
        pendingDefaultChange = nil
        Task { await store.setDefault(application, for: change.types) }
    }
}

private struct ApplicationDeclarationDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let application: ApplicationInfo

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIcon(url: application.url, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("App 声明详情")).font(.title2.weight(.semibold))
                    Text(application.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(18)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text(L10n.string("这里显示 App 的原始格式声明和 Launch Services 能力，仅用于诊断，不决定普通界面的操作范围。"))
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(application.documentTypes) { document in
                        declarationCard(document)
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }

    private func declarationCard(_ document: ApplicationDocumentType) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(document.name).font(.headline)
                Text(L10n.string(document.source == .bundleDeclaration ? "Bundle 声明" : "Launch Services 能力"))
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
                Spacer()
                Text(roleDescription(document.role)).font(.caption).foregroundStyle(.secondary)
                if let rank = document.handlerRank {
                    Text(L10n.format("application.handlerRank", rank))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            valueSection("扩展名", values: document.extensions.map { "." + $0 })
            valueSection("App 明确声明的 UTType", values: document.declaredTypeIdentifiers,
                         annotatesResolution: true)
            valueSection("App 声明的 MIME 类型", values: document.mimeTypes)
            let inferred = document.extensions.compactMap { extensionName -> String? in
                guard let type = UTType(filenameExtension: extensionName) else { return nil }
                return ".\(extensionName) → \(type.identifier)"
            }
            valueSection("按扩展名设置时使用的系统推测类型", values: inferred)
        }
        .padding(14)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func valueSection(_ title: String, values: [String],
                                           annotatesResolution: Bool = false) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(title)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(values, id: \.self) { value in
                    HStack(spacing: 7) {
                        Text(value).font(.caption.monospaced()).textSelection(.enabled)
                        if annotatesResolution {
                            let resolved = UTType(value) != nil
                            Text(L10n.string(resolved ? "系统可解析" : "仅 App 声明，系统当前不可解析"))
                                .font(.caption2).foregroundStyle(resolved ? Color.secondary : Color.orange)
                        }
                    }
                }
            }
        }
    }

    private func roleDescription(_ role: String) -> String {
        switch role.lowercased() {
        case "editor": return L10n.string("角色：编辑器")
        case "viewer": return L10n.string("角色：查看器")
        case "shell": return L10n.string("角色：Shell")
        default: return L10n.string("角色：由 Launch Services 提供")
        }
    }
}

private struct ApplicationSearchResult: Identifiable {
    let application: ApplicationInfo
    let subtitle: String
    let rank: Int
    let matchingExtensions: Set<String>
    var id: String { application.id }

    init?(application: ApplicationInfo, query: String) {
        self.application = application
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            subtitle = application.bundleIdentifier
            rank = 10
            matchingExtensions = []
            return
        }

        let extensionQuery = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var matchedExtensions = Set<String>()
        var declarationMatch = false
        for document in application.documentTypes {
            for extensionName in document.extensions where
                extensionName.localizedCaseInsensitiveContains(extensionQuery) {
                matchedExtensions.insert(extensionName.lowercased())
            }
            declarationMatch = declarationMatch
                || document.name.localizedCaseInsensitiveContains(normalized)
                || document.mimeTypes.contains { $0.localizedCaseInsensitiveContains(normalized) }
                || document.declaredTypeIdentifiers.contains { $0.localizedCaseInsensitiveContains(normalized) }
        }

        let nameMatches = application.name.localizedCaseInsensitiveContains(normalized)
            || application.bundleIdentifier.localizedCaseInsensitiveContains(normalized)
            || application.searchAliases.contains { $0.localizedCaseInsensitiveContains(normalized) }
        guard nameMatches || declarationMatch || !matchedExtensions.isEmpty else { return nil }
        matchingExtensions = matchedExtensions
        if let exact = matchedExtensions.first(where: {
            $0.caseInsensitiveCompare(extensionQuery) == .orderedSame
        }) {
            subtitle = L10n.format("支持打开 %@", "." + exact)
            rank = 0
        } else if nameMatches {
            subtitle = application.bundleIdentifier
            rank = 1
        } else if let first = matchedExtensions.sorted().first {
            subtitle = L10n.format("支持打开 %@", "." + first)
            rank = 2
        } else {
            subtitle = L10n.string("声明信息匹配")
            rank = 3
        }
    }
}

private enum ExtensionSortColumn { case extensionName, typeName, defaultAppName }

private enum ApplicationExtensionRole: Equatable {
    case editor, viewer, system

    var title: String {
        switch self { case .editor: "Editor"; case .viewer: "Viewer"; case .system: "LS" }
    }
    var symbol: String {
        switch self { case .editor: "pencil"; case .viewer: "eye"; case .system: "arrow.up.forward.app" }
    }
    var helpText: String {
        switch self {
        case .editor: "App 声明可编辑此扩展名"
        case .viewer: "App 声明只查看此扩展名；仍可设为默认"
        case .system: "由 Launch Services 提供打开能力"
        }
    }
}

private struct ApplicationExtensionRow: Identifiable {
    let fileType: FileTypeInfo
    let currentDefault: ApplicationInfo?
    let isApplicationDefault: Bool
    let role: ApplicationExtensionRole
    let isVolumePart: Bool
    var id: String { fileType.extensionName.lowercased() }
}

private struct PendingDefaultChange {
    let types: [FileTypeInfo]
    let hasViewer: Bool
}

private func extensionRole(for documents: [ApplicationDocumentType]) -> ApplicationExtensionRole {
    if documents.contains(where: { $0.role.caseInsensitiveCompare("Editor") == .orderedSame }) {
        return .editor
    }
    if documents.contains(where: \.isViewer) { return .viewer }
    return .system
}

private func isVolumePartExtension(_ extensionName: String) -> Bool {
    let characters = Array(extensionName.lowercased())
    guard characters.count == 3 else { return false }
    if characters.allSatisfy(\.isNumber) { return true }
    guard characters[1].isNumber, characters[2].isNumber else { return false }
    return characters[0] == "z" || characters[0] == "r"
}
