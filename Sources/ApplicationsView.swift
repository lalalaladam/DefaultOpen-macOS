import AppKit
import SwiftUI

struct ApplicationsView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var searchText = ""
    @State private var selectedAppID: String?

    private var searchResults: [ApplicationSearchResult] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return store.applications.map { ApplicationSearchResult(application: $0) }
        }
        return store.applications.compactMap { ApplicationSearchResult(application: $0, query: query) }
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            if store.isScanning && store.applications.isEmpty {
                ProgressView(L10n.string("正在扫描应用程序及其文档类型…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.applications.isEmpty {
                VStack(spacing: 14) {
                    ContentUnavailableView(L10n.string("尚未扫描应用程序"), systemImage: "square.grid.2x2",
                                           description: Text(L10n.string("扫描应用 Bundle 中声明的文档类型与 UTType。")))
                    Button(L10n.string("开始扫描")) { Task { await store.scanApplications() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(searchResults, selection: $selectedAppID) { result in
                        let app = result.application
                        HStack(spacing: 10) {
                            AppIcon(url: app.url, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                Text(result.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 3).tag(app.id)
                    }
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
                    .background(Color.clear)

                    if let result = searchResults.first(where: { $0.application.id == selectedAppID }) {
                        ApplicationDetailView(application: result.application,
                                              searchQuery: searchText,
                                              matchingTypeIDs: result.matchingTypeIDs,
                                              bestMatchingTypeID: result.bestMatchingTypeID,
                                              matchingExtensions: result.matchingExtensions)
                            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(L10n.string("选择一个应用程序"), systemImage: "app",
                                               description: Text(L10n.string("查看它支持的文件类型并修改默认关联。")))
                            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task { if store.applications.isEmpty { await store.scanApplications() } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("应用程序")).font(.title2.weight(.semibold))
                Text(L10n.string("按名称或扩展名筛选已安装的应用")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            SearchBox(prompt: "搜索应用或扩展名", text: $searchText)
                .help(L10n.string("可按应用名称、Bundle Identifier 或扩展名筛选；完整 UTType 也可精确匹配。"))
            Button { Task { await store.scanApplications() } } label: {
                Label(
                    LanguageSettings.shared.string(store.isScanning ? "正在扫描…" : "重新扫描"),
                    systemImage: "arrow.clockwise"
                )
                    .frame(width: 96)
            }
            .buttonStyle(.bordered)
            .disabled(store.isScanning)
        }.padding(.horizontal, 22).padding(.vertical, 16)
    }
}

private struct ApplicationDetailView: View {
    @EnvironmentObject private var store: AssociationStore
    let application: ApplicationInfo
    let searchQuery: String
    let matchingTypeIDs: Set<SupportedType.ID>
    let bestMatchingTypeID: SupportedType.ID?
    let matchingExtensions: [SupportedType.ID: String]
    @State private var selected = Set<SupportedType.ID>()
    @State private var sortColumn: SupportedTypeSortColumn = .extensionName
    @State private var sortAscending = true
    @State private var pendingDefaultChange: PendingDefaultChange?

    private var rows: [SupportedTypeRow] {
        application.supportedTypes.map { type in
            let current = currentDefault(for: type)
            return SupportedTypeRow(type: type, currentDefault: current,
                                    isApplicationDefault: current?.bundleIdentifier == application.bundleIdentifier,
                                    matchingExtension: matchingExtensions[type.id])
        }.sorted { lhs, rhs in
            let lhsMatchOrder = matchOrder(for: lhs.id)
            let rhsMatchOrder = matchOrder(for: rhs.id)
            if lhsMatchOrder != rhsMatchOrder { return lhsMatchOrder < rhsMatchOrder }

            let lhsIsUnset = lhs.currentDefault == nil
            let rhsIsUnset = rhs.currentDefault == nil
            if lhsIsUnset != rhsIsUnset { return !lhsIsUnset }

            let comparison: ComparisonResult
            switch sortColumn {
            case .extensionName:
                comparison = lhs.extensionText.localizedStandardCompare(rhs.extensionText)
            case .typeName:
                comparison = lhs.typeSortText.localizedStandardCompare(rhs.typeSortText)
            case .defaultAppName:
                comparison = lhs.defaultAppName.localizedStandardCompare(rhs.defaultAppName)
            }
            if comparison == .orderedSame {
                return lhs.extensionText.localizedStandardCompare(rhs.extensionText) == .orderedAscending
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AppIcon(url: application.url, size: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(application.name).font(.title2.weight(.semibold))
                    Text(application.bundleIdentifier).font(.callout).foregroundStyle(.secondary)
                    Text(L10n.format("application.supportedTypeCount", application.supportedTypes.count))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if !selected.isEmpty {
                    Button(L10n.string("将所选类型设为默认")) { makeSelectedDefault() }.buttonStyle(.borderedProminent)
                }
            }.padding(20)
            Divider().opacity(0.45)
            supportedTypesList
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
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
            pendingDefaultChange = nil
        }
    }

    private var supportedTypesList: some View {
        GeometryReader { proxy in
            let extensionWidth = min(145, max(90, proxy.size.width * 0.18))
            let defaultAppWidth = min(195, max(145, proxy.size.width * 0.24))
            let actionWidth: CGFloat = 78
            let typeWidth = max(160, proxy.size.width - extensionWidth - defaultAppWidth - actionWidth - 72)

            VStack(spacing: 0) {
                if !matchingTypeIDs.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text(L10n.format("search.matchingTypeCount", matchingTypeIDs.count))
                        Spacer()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    Divider()
                }
                HStack(spacing: 12) {
                    sortableHeader("扩展名", column: .extensionName, width: extensionWidth)
                    sortableHeader("文件类型 / UTType", column: .typeName, width: typeWidth)
                    sortableHeader("当前默认 App", column: .defaultAppName, width: defaultAppWidth)
                    Color.clear.frame(width: actionWidth)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 30)
                Divider()

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                            HStack(spacing: 12) {
                                extensionLabel(row)
                                    .frame(width: extensionWidth, alignment: .leading)
                                    .help(row.extensionText)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(row.type.displayName).lineLimit(1).truncationMode(.tail)
                                        if row.id == bestMatchingTypeID, let matched = row.matchingExtension {
                                            Label(L10n.format("search.bestExtensionMatch", ".\(matched)"),
                                                  systemImage: "magnifyingglass")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.orange)
                                                .lineLimit(1)
                                        }
                                    }
                                    Text(row.type.contentTypeIdentifier).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                .frame(width: typeWidth, alignment: .leading)
                                .help("\(row.type.displayName)\n\(row.type.contentTypeIdentifier)")
                                HStack(spacing: 7) {
                                    AppIcon(url: row.currentDefault?.url, size: 25)
                                    Text(row.currentDefault?.name ?? L10n.string("未设置")).lineLimit(1)
                                    if row.isApplicationDefault {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                    }
                                }
                                .frame(width: defaultAppWidth, alignment: .leading)
                                Button(L10n.string("设为默认")) { makeDefault(row.type) }
                                    .buttonStyle(.borderless)
                                    .disabled(row.isApplicationDefault)
                                    .frame(width: actionWidth)
                            }
                            .padding(.horizontal, 12).frame(height: 52)
                            .background(rowBackground(row.id))
                            .contentShape(Rectangle())
                            .onTapGesture { selectRow(row.id) }
                            .id(row.id)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                    .task(id: scrollTargetID) {
                        guard let bestMatchingTypeID else { return }
                        await Task.yield()
                        withAnimation(.easeInOut(duration: 0.25)) {
                            scrollProxy.scrollTo(bestMatchingTypeID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var scrollTargetID: String {
        "\(application.id)|\(searchQuery)|\(bestMatchingTypeID ?? "")"
    }

    private func rowBackground(_ id: SupportedType.ID) -> Color {
        if selected.contains(id) { return Color.accentColor.opacity(0.18) }
        return Color.clear
    }

    @ViewBuilder
    private func extensionLabel(_ row: SupportedTypeRow) -> some View {
        HStack(spacing: 4) {
            if let matched = row.matchingExtension {
                Text(".\(matched)")
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                if !row.remainingExtensionText.isEmpty {
                    Text(row.remainingExtensionText).foregroundStyle(.secondary)
                }
            } else {
                Text(row.extensionText)
            }
        }
        .font(.system(.callout, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func matchOrder(for id: SupportedType.ID) -> Int {
        if id == bestMatchingTypeID { return 0 }
        if matchingTypeIDs.contains(id) { return 1 }
        return 2
    }

    private func selectRow(_ id: SupportedType.ID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            selected = [id]
        }
    }

    private func currentDefault(for type: SupportedType) -> ApplicationInfo? {
        guard let fileType = store.fileTypes(for: type).first else { return nil }
        return store.defaultApplication(for: fileType)
    }

    private func makeDefault(_ supportedType: SupportedType) {
        let types = store.fileTypes(for: supportedType)
        guard !types.isEmpty else {
            store.errorMessage = L10n.string("此 UTType 没有声明可用于设置关联的文件扩展名。")
            return
        }
        pendingDefaultChange = PendingDefaultChange(types: types, supportedTypeCount: 1)
    }

    private func makeSelectedDefault() {
        let types = application.supportedTypes.filter { selected.contains($0.id) }
            .flatMap { store.fileTypes(for: $0) }
        let unique = Dictionary(grouping: types, by: \FileTypeInfo.id).compactMap(\.value.first)
        guard !unique.isEmpty else {
            store.errorMessage = L10n.string("所选类型没有可用于设置关联的文件扩展名。")
            return
        }
        pendingDefaultChange = PendingDefaultChange(types: unique, supportedTypeCount: selected.count)
    }

    private var confirmationTitle: String {
        guard let change = pendingDefaultChange else { return L10n.string("确认设为默认？") }
        return L10n.string(change.supportedTypeCount == 1 ? "确认设为默认？" : "确认批量设为默认？")
    }

    private var confirmationMessage: String {
        guard let change = pendingDefaultChange else { return "" }
        let targets = change.types.map(\.dottedExtension).joined(separator: L10n.string("list.separator"))
        return L10n.format("application.confirmationMessage", application.name, targets)
    }

    private func applyPendingDefaultChange() {
        guard let change = pendingDefaultChange else { return }
        pendingDefaultChange = nil
        Task { await store.setDefault(application, for: change.types) }
    }

    private func sortableHeader(_ title: String, column: SupportedTypeSortColumn,
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
}

private enum SupportedTypeSortColumn {
    case extensionName, typeName, defaultAppName
}

private struct ApplicationSearchResult: Identifiable {
    let application: ApplicationInfo
    let subtitle: String
    let rank: SearchRank
    let matchingTypeIDs: Set<SupportedType.ID>
    let bestMatchingTypeID: SupportedType.ID?
    let matchingExtensions: [SupportedType.ID: String]

    var id: String { application.id }

    init(application: ApplicationInfo) {
        self.application = application
        subtitle = application.bundleIdentifier
        rank = SearchRank(category: .bundleOrAlias, quality: .contains)
        matchingTypeIDs = []
        bestMatchingTypeID = nil
        matchingExtensions = [:]
    }

    init?(application: ApplicationInfo, query: String) {
        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let extensionQuery = normalizedQuery.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var candidates: [(rank: SearchRank, subtitle: String, typeID: SupportedType.ID?,
                          matchedExtension: String?)] = []

        if let quality = MatchQuality.match(normalizedQuery, in: application.name) {
            candidates.append((SearchRank(category: .appName, quality: quality),
                               L10n.format("名称包含“%@”", query), nil, nil))
        }
        for type in application.supportedTypes {
            for fileExtension in type.extensions {
                if let quality = MatchQuality.matchExtension(extensionQuery, in: fileExtension) {
                    candidates.append((SearchRank(category: .fileExtension, quality: quality),
                                       L10n.format("支持打开 %@", ".\(fileExtension)"), type.id,
                                       fileExtension))
                }
            }
            if normalizedQuery.contains("."),
               type.contentTypeIdentifier.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                   locale: .current) == normalizedQuery {
                candidates.append((SearchRank(category: .utType, quality: .exact),
                                   L10n.format("支持 UTType %@", type.contentTypeIdentifier), type.id, nil))
            }
        }
        if let quality = MatchQuality.match(normalizedQuery, in: application.bundleIdentifier) {
            candidates.append((SearchRank(category: .bundleOrAlias, quality: quality),
                               L10n.format("Bundle ID 包含“%@”", query), nil, nil))
        }
        if application.searchAliases.contains(where: { MatchQuality.match(normalizedQuery, in: $0) != nil }) {
            candidates.append((SearchRank(category: .bundleOrAlias, quality: .contains),
                               L10n.format("名称别名包含“%@”", query), nil, nil))
        }

        guard let best = candidates.min(by: { $0.rank < $1.rank }) else { return nil }
        let typeMatches = candidates.filter { $0.typeID != nil }.sorted { $0.rank < $1.rank }
        let exactExtension = typeMatches.first { $0.rank.category == .fileExtension && $0.rank.quality == .exact }

        self.application = application
        rank = best.rank
        matchingTypeIDs = Set(typeMatches.compactMap(\.typeID))
        bestMatchingTypeID = (exactExtension ?? typeMatches.first)?.typeID
        matchingExtensions = Dictionary(typeMatches.compactMap { match in
            guard let typeID = match.typeID, let fileExtension = match.matchedExtension else { return nil }
            return (typeID, fileExtension)
        }, uniquingKeysWith: { first, _ in first })
        if best.rank.category == .appName, let exactExtension {
            let matchedExtension = application.supportedTypes
                .first(where: { $0.id == exactExtension.typeID })?.extensions
                .first(where: { $0.caseInsensitiveCompare(extensionQuery) == .orderedSame })
            subtitle = matchedExtension.map {
                "\(best.subtitle) · \(L10n.format("同时支持打开 %@", ".\($0)"))"
            } ?? best.subtitle
        } else {
            subtitle = best.subtitle
        }
    }
}

private struct SearchRank: Comparable {
    let category: SearchCategory
    let quality: MatchQuality

    static func < (lhs: SearchRank, rhs: SearchRank) -> Bool {
        lhs.category == rhs.category ? lhs.quality < rhs.quality : lhs.category < rhs.category
    }
}

private enum SearchCategory: Int, Comparable {
    case appName, fileExtension, utType, bundleOrAlias
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

private enum MatchQuality: Int, Comparable {
    case exact, prefix, contains
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func match(_ query: String, in candidate: String) -> MatchQuality? {
        guard !query.isEmpty else { return nil }
        let value = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if value == query { return .exact }
        if value.hasPrefix(query) { return .prefix }
        if value.contains(query) { return .contains }
        return nil
    }

    static func matchExtension(_ query: String, in candidate: String) -> MatchQuality? {
        guard !query.isEmpty else { return nil }
        let value = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if value == query { return .exact }
        if value.hasPrefix(query) { return .prefix }
        return nil
    }
}

private struct PendingDefaultChange {
    let types: [FileTypeInfo]
    let supportedTypeCount: Int
}

private struct SupportedTypeRow: Identifiable {
    let type: SupportedType
    let currentDefault: ApplicationInfo?
    let isApplicationDefault: Bool
    let matchingExtension: String?
    var id: String { type.id }
    var extensionText: String { orderedExtensions.isEmpty ? "—" : orderedExtensions.map { "." + $0 }.joined(separator: ", ") }
    var remainingExtensionText: String {
        orderedExtensions.dropFirst().map { "." + $0 }.joined(separator: ", ")
    }
    var displayName: String { type.displayName }
    var typeSortText: String { "\(type.displayName) \(type.contentTypeIdentifier)" }
    var defaultAppName: String { currentDefault?.name ?? "" }

    private var orderedExtensions: [String] {
        guard let matchingExtension,
              let matchIndex = type.extensions.firstIndex(where: {
                  $0.caseInsensitiveCompare(matchingExtension) == .orderedSame
              }) else { return type.extensions }
        var result = type.extensions
        let match = result.remove(at: matchIndex)
        result.insert(match, at: 0)
        return result
    }
}
