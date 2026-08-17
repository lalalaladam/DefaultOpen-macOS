import AppKit
import SwiftUI

struct ApplicationsView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var searchText = ""
    @State private var effectiveSearchText = ""
    @State private var selectedAppID: String?
    @State private var showsExtensionSearchProgress = false

    private var searchResults: [ApplicationSearchResult] {
        let query = effectiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.applications.compactMap {
            ApplicationSearchResult(
                application: $0,
                verifiedFileTypes: store.verifiedFileTypes(for: $0),
                query: query
            )
        }
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
            }
    }

    private var searchResultIDs: [ApplicationInfo.ID] { searchResults.map(\.application.id) }

    private var isLoadingExtensionSearch: Bool {
        store.isLoadingApplications(matchingExtensionSearch: effectiveSearchText)
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
        .task(id: effectiveSearchText) {
            if store.applications.isEmpty { await store.scanApplications() }
            guard !effectiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            await store.loadApplications(matchingExtensionSearch: effectiveSearchText)
        }
        .task(id: isLoadingExtensionSearch) {
            guard isLoadingExtensionSearch else {
                showsExtensionSearchProgress = false
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, isLoadingExtensionSearch else { return }
            showsExtensionSearchProgress = true
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
            SearchBox(prompt: "搜索应用或扩展名",
                      text: $searchText,
                      effectiveText: $effectiveSearchText,
                      debounceMilliseconds: 400)
            ZStack {
                if showsExtensionSearchProgress {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 16, height: 16)
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
                        Text(app.name)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(result.subtitle).font(.caption2)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help("\(app.name)\n\(result.subtitle)")
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ApplicationPressSelectingButtonStyle {
                selectedAppID = app.id
            })
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .scrollContentBackground(.hidden)
        .frame(minWidth: 195, idealWidth: 215, maxWidth: 250)
    }

    @ViewBuilder private var detail: some View {
        if let result = searchResults.first(where: { $0.application.id == selectedAppID }) {
            ApplicationDetailView(application: result.application,
                                  matchingExtensions: result.matchingExtensions,
                                  exactMatchingExtension: result.exactMatchingExtension)
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

private struct ApplicationPressSelectingButtonStyle: ButtonStyle {
    let onPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { onPress() }
            }
    }
}

private struct ApplicationDetailView: View {
    @EnvironmentObject private var store: AssociationStore
    let application: ApplicationInfo
    let matchingExtensions: Set<String>
    let exactMatchingExtension: String?
    @State private var selected = Set<String>()
    @State private var sortColumn: ExtensionSortColumn = .source
    @State private var sortAscending = true
    @State private var showsVolumeParts = false
    @State private var pendingDefaultChange: PendingDefaultChange?

    private var rows: [ApplicationExtensionRow] {
        store.verifiedFileTypes(for: application).map { fileType in
            let current = store.defaultApplication(for: fileType)
            return ApplicationExtensionRow(
                fileType: fileType,
                currentDefault: current,
                isApplicationDefault: current?.bundleIdentifier == application.bundleIdentifier,
                isVolumePart: isVolumePartExtension(fileType.extensionName),
                capabilityEvidence: store.capabilityEvidence(for: application, fileType: fileType)
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

    private var selectedRows: [ApplicationExtensionRow] {
        rows.filter { selected.contains($0.id) }
    }

    private var selectedRowsAreAllCurrentDefaults: Bool {
        !selectedRows.isEmpty && selectedRows.allSatisfy(\.isApplicationDefault)
    }

    private var selectedRowsHavePendingChanges: Bool {
        selectedRows.contains {
            !$0.isApplicationDefault && store.modificationRisk(for: $0.fileType) != .protected
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider().opacity(0.45)
            if rows.isEmpty {
                ContentUnavailableView(
                    L10n.string("没有可设置的扩展名"),
                    systemImage: "doc.badge.ellipsis",
                    description: Text(L10n.string("macOS 没有确认这个 App 能打开其声明的扩展名。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                extensionTable
            }
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
            if !selected.isEmpty {
                Button(L10n.string(selectedRowsAreAllCurrentDefaults
                                   ? "已是默认" : "将所选扩展名设为默认")) {
                    makeSelectedDefault()
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!selectedRowsHavePendingChanges)
            }
        }
        .padding(20)
    }

    private var extensionTable: some View {
        GeometryReader { proxy in
            let sourceWidth: CGFloat = 72
            let actionWidth: CGFloat = 80
            let informationWidth = max(352, proxy.size.width - sourceWidth - actionWidth - 76)
            let extensionWidth = max(112, informationWidth * 0.20)
            let typeWidth = max(90, informationWidth * 0.45)
            let defaultAppWidth = max(150, informationWidth - extensionWidth - typeWidth)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    sortableHeader("扩展名", column: .extensionName, width: extensionWidth)
                    sortableHeader("文件类型 / UTType", column: .typeName, width: typeWidth)
                    sortableHeader("来源", column: .source, width: sourceWidth)
                    sortableHeader("当前默认 App", column: .defaultAppName, width: defaultAppWidth)
                    Color.clear.frame(width: actionWidth)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 12).padding(.trailing, 24).frame(height: 30)
                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleRows) { row in
                            extensionRow(row, extensionWidth: extensionWidth, typeWidth: typeWidth,
                                         sourceWidth: sourceWidth,
                                         defaultAppWidth: defaultAppWidth,
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
                              typeWidth: CGFloat,
                              sourceWidth: CGFloat,
                              defaultAppWidth: CGFloat, actionWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text(row.fileType.dottedExtension)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.fileType.dottedExtension)
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

            CapabilitySourceBadge(evidence: row.capabilityEvidence,
                                  requestedIdentifier: row.fileType.contentTypeIdentifier)
                .frame(width: sourceWidth, alignment: .leading)

            HStack(spacing: 7) {
                AppIcon(url: row.currentDefault?.url, size: 25)
                Text(row.currentDefault?.name ?? L10n.string("未设置")).lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.currentDefault?.name ?? L10n.string("未设置"))
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
        .padding(.leading, 12).padding(.trailing, 24).frame(height: 52)
        .background(selected.contains(row.id) ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectRow(row.id) }
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
        let lhsIsBestMatch = lhs.id == exactMatchingExtension
        let rhsIsBestMatch = rhs.id == exactMatchingExtension
        if lhsIsBestMatch != rhsIsBestMatch { return lhsIsBestMatch }

        let lhsMatch = matchingExtensions.contains(lhs.id)
        let rhsMatch = matchingExtensions.contains(rhs.id)
        if lhsMatch != rhsMatch { return lhsMatch }

        let comparison: ComparisonResult
        switch sortColumn {
        case .source:
            if lhs.capabilityEvidence.source != rhs.capabilityEvidence.source {
                let ordered = lhs.capabilityEvidence.source < rhs.capabilityEvidence.source
                return sortAscending ? ordered : !ordered
            }
            comparison = lhs.fileType.extensionName.localizedStandardCompare(rhs.fileType.extensionName)
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
        pendingDefaultChange = PendingDefaultChange(types: [row.fileType])
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
        pendingDefaultChange = PendingDefaultChange(types: types)
    }

    private var confirmationMessage: String {
        guard let change = pendingDefaultChange else { return "" }
        let extensions = change.types.map(\.dottedExtension)
            .joined(separator: L10n.string("list.separator"))
        var message = L10n.format("application.confirmExtensions", application.name, extensions)
        let evidence = change.types.map {
            store.capabilityEvidence(for: application, fileType: $0)
        }
        let sourceCounts = ApplicationCapabilitySourceCounts(evidence)
        if sourceCounts.hasNonExplicit {
            message += "\n\n" + sourceCounts.summary
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

private struct ApplicationSearchResult: Identifiable {
    let application: ApplicationInfo
    let subtitle: String
    let rank: Int
    let matchingExtensions: Set<String>
    let exactMatchingExtension: String?
    var id: String { application.id }

    init?(application: ApplicationInfo, verifiedFileTypes: [FileTypeInfo], query: String) {
        self.application = application
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            subtitle = application.bundleIdentifier
            rank = 10
            matchingExtensions = []
            exactMatchingExtension = nil
            return
        }

        let extensionQuery = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        var exactMatches = Set<String>()
        var prefixMatches = Set<String>()
        for fileType in verifiedFileTypes {
            let extensionName = fileType.extensionName.lowercased()
            if extensionName == extensionQuery {
                exactMatches.insert(extensionName)
            } else if extensionName.hasPrefix(extensionQuery) {
                prefixMatches.insert(extensionName)
            }
        }
        let matchedExtensions = exactMatches.union(prefixMatches)

        let nameMatches = application.name.localizedCaseInsensitiveContains(normalized)
            || application.bundleIdentifier.localizedCaseInsensitiveContains(normalized)
            || application.searchAliases.contains { $0.localizedCaseInsensitiveContains(normalized) }
        guard nameMatches || !matchedExtensions.isEmpty else { return nil }
        matchingExtensions = matchedExtensions
        exactMatchingExtension = exactMatches.sorted().first
        if let exact = exactMatches.sorted().first {
            subtitle = L10n.format("支持打开 %@", "." + exact)
            rank = 0
        } else if nameMatches {
            subtitle = application.bundleIdentifier
            rank = 1
        } else if let first = matchedExtensions.sorted().first {
            subtitle = L10n.format("支持打开 %@", "." + first)
            rank = 2
        } else { return nil }
    }
}

private enum ExtensionSortColumn { case source, extensionName, typeName, defaultAppName }

private struct ApplicationExtensionRow: Identifiable {
    let fileType: FileTypeInfo
    let currentDefault: ApplicationInfo?
    let isApplicationDefault: Bool
    let isVolumePart: Bool
    let capabilityEvidence: ApplicationCapabilityEvidence
    var id: String { fileType.extensionName.lowercased() }
}

private struct PendingDefaultChange {
    let types: [FileTypeInfo]
}

private func isVolumePartExtension(_ extensionName: String) -> Bool {
    let characters = Array(extensionName.lowercased())
    guard characters.count == 3 else { return false }
    if characters.allSatisfy(\.isNumber) { return true }
    guard characters[1].isNumber, characters[2].isNumber else { return false }
    return characters[0] == "z" || characters[0] == "r"
}
