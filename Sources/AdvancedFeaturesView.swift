import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AdvancedFeaturesView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var extensionQuery = ""
    @State private var checkedExtension: String?
    @State private var matches: [FallbackTypeMatch] = []
    @State private var typeBeingChanged: FileTypeInfo?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            FileSpecificAssociationView()
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: store.defaultAppRevision) { _, _ in
            if let checkedExtension {
                loadExtension(checkedExtension, synchronizeQuery: false)
            }
        }
        .sheet(item: $typeBeingChanged) { type in
            ApplicationPickerSheet(type: type, scope: .contentType).environmentObject(store)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("指定文件的打开方式"))
                    .font(.title2.weight(.semibold))
                Text(L10n.string("为单个或多个具体文件指定默认 App，不影响其他同扩展名文件。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var extensionAnalysisHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title3).foregroundStyle(.purple)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("分析扩展名与系统类型"))
                    .font(.headline)
                Text(L10n.string("修改 UTType 级默认 App，可能影响多个同类型文件。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField(L10n.string("输入扩展名并按回车，例如 docx"), text: $extensionQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { checkExtension() }
            Button(L10n.string("检查")) { checkExtension() }
                .buttonStyle(.borderedProminent)
                .disabled(normalizedExtension.isEmpty)
        }
    }

    @ViewBuilder private var results: some View {
        if matches.isEmpty, let checkedExtension {
            ContentUnavailableView(
                L10n.string("没有找到可单独修改的类型"),
                systemImage: "checkmark.circle",
                description: Text(L10n.format("advanced.noFallbackTypes", "." + checkedExtension))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if matches.isEmpty {
            ContentUnavailableView(
                L10n.string("输入扩展名开始检查"),
                systemImage: "wrench.and.screwdriver",
                description: Text(L10n.string("输入扩展名并按回车，查看其系统类型和默认 App。"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                let rowContentWidth = max(460, proxy.size.width - 258)
                let typeWidth = rowContentWidth * 0.58
                let defaultAppWidth = rowContentWidth - typeWidth

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.format("advanced.fallbackTypes", "." + (checkedExtension ?? ""),
                                             matches.count))
                                .font(.headline)
                            Text(L10n.string(matches.count == 1
                                             ? "macOS 只为这个扩展名返回了一个可修改的系统类型。"
                                             : "首选类型通常决定文件的双击打开方式。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 4)

                        ForEach(matches) { match in
                            matchRow(match, typeWidth: typeWidth, defaultAppWidth: defaultAppWidth)
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private func matchRow(_ match: FallbackTypeMatch, typeWidth: CGFloat,
                          defaultAppWidth: CGFloat) -> some View {
        HStack(spacing: 14) {
            Image(systemName: match.isPreferred ? "checkmark.circle.fill" : "doc.circle")
                .font(.title3)
                .foregroundStyle(match.isPreferred ? Color.accentColor : Color.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(match.displayName).font(.headline)
                    if match.isPreferred {
                        Text(L10n.string("普通设置使用"))
                            .font(.caption2.weight(.medium)).foregroundStyle(.tint)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.12), in: Capsule())
                    }
                }
                Text(match.fileType.contentTypeIdentifier)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .frame(width: typeWidth, alignment: .leading)

            HStack(spacing: 7) {
                AppIcon(url: match.defaultApplication?.url, size: 26)
                    .frame(width: 26)
                Text(match.defaultApplication?.name ?? L10n.string("未设置"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(match.defaultApplication?.name ?? L10n.string("未设置"))
                Group {
                    if let application = match.defaultApplication {
                        if let evidence = store.capabilityEvidenceIfAvailable(
                            for: application,
                            fileType: match.fileType
                        ) {
                            CapabilitySourceBadge(
                                evidence: evidence,
                                requestedIdentifier: match.fileType.contentTypeIdentifier
                            )
                        }
                    }
                }
                .frame(width: 52, alignment: .leading)
            }
            .frame(width: defaultAppWidth, alignment: .leading)

            HStack {
                Button(L10n.string(match.isPreferred || matches.count == 1
                                   ? "更改默认 App…" : "单独更改…")) {
                    typeBeingChanged = match.fileType
                }
                .buttonStyle(.bordered)
                .disabled(!match.canChange)
                .help(L10n.string(match.canChange
                                  ? "只修改这个系统类型的默认 App。"
                                  : "这个类型当前没有可用 App，或不能安全修改。"))
            }
            .frame(width: 126, alignment: .trailing)
        }
        .padding(14)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var normalizedExtension: String {
        extensionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private func checkExtension() {
        let extensionName = normalizedExtension
        guard !extensionName.isEmpty else { return }
        loadExtension(extensionName, synchronizeQuery: true)
    }

    private func loadExtension(_ extensionName: String, synchronizeQuery: Bool) {
        if synchronizeQuery { extensionQuery = extensionName }
        checkedExtension = extensionName

        let preferred = store.inferredFileType(forExtension: extensionName)
        var fileTypes: [FileTypeInfo] = []
        if let preferred { fileTypes.append(preferred) }
        fileTypes += store.registeredFileTypes(forExtension: extensionName).filter { candidate in
            return !fileTypes.contains { $0.contentTypeIdentifier == candidate.contentTypeIdentifier }
        }

        store.refreshDefaults(for: fileTypes)
        matches = fileTypes.compactMap { fileType in
            guard let type = UTType(fileType.contentTypeIdentifier) else { return nil }
            let capableApplications = store.capableApplications(for: fileType)
            return FallbackTypeMatch(
                fileType: fileType,
                displayName: type.localizedDescription ?? fileType.specificDisplayName,
                defaultApplication: store.defaultApplication(for: fileType),
                isPreferred: fileType.contentTypeIdentifier == preferred?.contentTypeIdentifier,
                canChange: !capableApplications.isEmpty
                    && store.modificationRisk(for: fileType) != .protected
            )
        }
        Task { await store.loadDefaultApplicationCapabilityMetadata() }
    }
}

private struct FileSpecificAssociationView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var files: [URL] = []
    @State private var applications: [ApplicationInfo] = []
    @State private var manuallySelectedApplication: ApplicationInfo?
    @State private var selectedApplicationID: ApplicationInfo.ID?
    @State private var currentApplications: [URL: ApplicationInfo] = [:]
    @State private var statuses: [URL: FileAssociationStatus] = [:]
    @State private var showsFileDetails = false
    @State private var showsAllCurrentApps = false
    @State private var showsTargetApplicationPicker = false
    @State private var isTargeted = false
    @State private var isApplying = false
    @State private var confirmsApplication = false
    private let launchServices = LaunchServicesClient()

    private var selectedApplication: ApplicationInfo? {
        applications.first { $0.id == selectedApplicationID }
    }

    private var unsupportedFiles: [URL] {
        guard let selectedApplication else { return [] }
        return files.filter { url in
            !launchServices.capableApplications(forFileAt: url).contains {
                $0.bundleIdentifier == selectedApplication.bundleIdentifier
            }
        }
    }

    private var confirmationTitle: String {
        let applicationName = selectedApplication?.name ?? "—"
        return unsupportedFiles.isEmpty
            ? L10n.format("fileAssociation.confirmTitle", applicationName)
            : L10n.format("fileAssociation.riskConfirmTitle", applicationName)
    }

    private var confirmationMessage: String {
        unsupportedFiles.isEmpty
            ? L10n.format("fileAssociation.confirmCount", files.count)
            : L10n.format("fileAssociation.riskCount", unsupportedFiles.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !files.isEmpty {
                HStack {
                    Text(L10n.format("fileAssociation.selectedCount", files.count))
                        .font(.headline)
                    Spacer()
                    Button(L10n.string("清除")) { clearFiles() }
                        .disabled(isApplying)
                }
            }

            dropTarget
            if !files.isEmpty { selectionControls }

            if !files.isEmpty {
                Divider().opacity(0.45)
                currentAppSummary
                fileDetails
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.14))
        }
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
        .confirmationDialog(confirmationTitle,
                            isPresented: $confirmsApplication,
                            titleVisibility: .visible) {
            Button(unsupportedFiles.isEmpty
                   ? L10n.string("更改") : L10n.string("仍然更改")) {
                applySelection()
            }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var dropTarget: some View {
        Button {
            Task { @MainActor in addFiles(await chooseFileURLs()) }
        } label: {
            VStack(spacing: files.isEmpty ? 12 : 7) {
                Image(systemName: isTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                    .font(.system(size: files.isEmpty ? 38 : 28, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(spacing: 3) {
                    Text(files.isEmpty
                         ? L10n.string("拖入一个或多个文件")
                         : L10n.string("拖入或点击添加更多文件"))
                        .font(files.isEmpty ? .headline : .callout.weight(.semibold))
                    Text(L10n.string("或点击选择文件…"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .frame(minHeight: files.isEmpty ? 150 : 92)
            .background(isTargeted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 1, dash: [5]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isApplying)
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("目标 App"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ZStack {
                Button {
                    showsTargetApplicationPicker.toggle()
                } label: {
                    HStack(spacing: 7) {
                        AppIcon(url: selectedApplication?.url, size: 22)
                        Text(selectedApplication?.name
                             ?? L10n.string("选择兼容所有文件的 App"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 26)
                }
                .buttonStyle(.bordered)
                .frame(width: 220)
                .help(selectedApplication?.name
                      ?? L10n.string("选择兼容所有文件的 App"))
                .disabled(applications.isEmpty || isApplying)
                .popover(isPresented: $showsTargetApplicationPicker, arrowEdge: .bottom) {
                    targetApplicationPicker
                }

                HStack {
                    Spacer()
                    Button(L10n.string("选择其他 App…")) { chooseOtherApplication() }
                        .buttonStyle(.bordered)
                        .disabled(isApplying)
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Text(L10n.string("目标 App 将应用到全部所选文件。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    confirmsApplication = true
                } label: {
                    if isApplying {
                        ProgressView().controlSize(.small)
                        Text(L10n.string("正在设置…"))
                    } else {
                        Text(L10n.format("fileAssociation.applyCount", files.count))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedApplication == nil || isApplying)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var targetApplicationPicker: some View {
        let listHeight = min(CGFloat(applications.count) * 38, 304)
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(applications) { application in
                    Button {
                        selectedApplicationID = application.id
                        showsTargetApplicationPicker = false
                    } label: {
                        HStack(spacing: 8) {
                            AppIcon(url: application.url, size: 20)
                            Text(application.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(application.name)
                            Spacer()
                            if selectedApplicationID == application.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .background(selectedApplicationID == application.id
                                    ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .padding(8)
        .frame(width: 280, height: max(62, listHeight + 16))
    }

    private var currentAppSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.string("当前打开方式"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Array(currentApplicationGroups.prefix(3))) { group in
                    currentAppBadge(group)
                }
                if currentApplicationGroups.count > 3 {
                    Button(L10n.format("fileAssociation.moreApps",
                                       currentApplicationGroups.count - 3)) {
                        showsAllCurrentApps = true
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .popover(isPresented: $showsAllCurrentApps, arrowEdge: .bottom) {
                        allCurrentAppsPopover
                    }
                }
                Spacer()
            }
        }
    }

    private func currentAppBadge(_ group: CurrentApplicationGroup) -> some View {
        HStack(spacing: 5) {
            AppIcon(url: group.applicationURL, size: 18)
            Text(group.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 120, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text("\(group.count)").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.primary.opacity(0.06), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .help(group.name)
    }

    private var allCurrentAppsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("所有当前打开方式"))
                .font(.headline)
            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(currentApplicationGroups) { group in
                        HStack(spacing: 8) {
                            AppIcon(url: group.applicationURL, size: 24)
                            Text(group.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(group.name)
                            Spacer()
                            Text(L10n.format("fileAssociation.fileCount", group.count))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 240)
            Divider()
            Text(L10n.format("fileAssociation.appKindCount", currentApplicationGroups.count))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var fileDetails: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showsFileDetails.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsFileDetails ? 90 : 0))
                    Text(L10n.format("fileAssociation.showFiles", files.count))
                        .font(.callout.weight(.medium))
                    Spacer()
                    if !statuses.isEmpty { statusSummary }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsFileDetails {
                VStack(spacing: 0) {
                    fileTableHeader
                    Divider().opacity(0.45)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(files, id: \.self) { file in
                                fileRow(file)
                                if file != files.last { Divider().opacity(0.35) }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                .padding(.top, 8)
            }
        }
    }

    private var fileTableHeader: some View {
        HStack(spacing: 10) {
            Text(L10n.string("文件"))
            Spacer()
            Text(L10n.string("当前打开方式"))
                .frame(width: 150, alignment: .leading)
            if !statuses.isEmpty {
                Text(L10n.string("状态"))
                    .frame(width: 105, alignment: .leading)
            }
            Color.clear.frame(width: 14, height: 1)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 2).padding(.vertical, 4)
    }

    private func fileRow(_ file: URL) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(file.deletingLastPathComponent().path)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 5) {
                AppIcon(url: currentApplications[file]?.url, size: 18)
                Text(currentApplications[file]?.name ?? L10n.string("未设置"))
                    .lineLimit(1)
            }
            .font(.caption).frame(width: 150, alignment: .leading)
            if !statuses.isEmpty {
                statusLabel(for: file).frame(width: 105, alignment: .leading)
            }
            Button { removeFile(file) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).disabled(isApplying)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func statusLabel(for file: URL) -> some View {
        if let status = statuses[file] {
            Label(status.label, systemImage: status.symbol)
                .font(.caption).foregroundStyle(status.color)
                .help(status.errorMessage ?? status.label)
        } else {
            Text("—").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var statusSummary: some View {
        let confirmed = statuses.values.filter { $0 == .confirmed }.count
        let pending = statuses.values.filter(\.isInProgress).count
        let failed = statuses.count - confirmed - pending
        return Text(L10n.format("fileAssociation.statusSummary", confirmed, pending, failed))
            .font(.caption).foregroundStyle(.secondary)
    }

    private var currentApplicationGroups: [CurrentApplicationGroup] {
        Dictionary(grouping: files) {
            currentApplications[$0]?.bundleIdentifier ?? ""
        }.map { identifier, groupFiles in
            let application = groupFiles.compactMap { currentApplications[$0] }.first
            return CurrentApplicationGroup(
                id: identifier,
                name: application?.name ?? L10n.string("未设置"),
                applicationURL: application?.url,
                count: groupFiles.count
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func addFiles(_ urls: [URL]) {
        let valid = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
        }
        var seen = Set(files.map { $0.standardizedFileURL })
        files += valid.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        statuses = [:]
        refreshCurrentApplications()
        reloadApplications()
    }

    private func clearFiles() {
        files = []
        applications = []
        manuallySelectedApplication = nil
        selectedApplicationID = nil
        currentApplications = [:]
        statuses = [:]
        showsFileDetails = false
        showsTargetApplicationPicker = false
    }

    private func removeFile(_ file: URL) {
        files.removeAll { $0 == file }
        currentApplications.removeValue(forKey: file)
        statuses.removeValue(forKey: file)
        reloadApplications()
    }

    private func refreshCurrentApplications(for targetFiles: [URL]? = nil) {
        for file in targetFiles ?? files {
            if let application = launchServices.defaultApplication(forFileAt: file) {
                currentApplications[file] = application
            } else {
                currentApplications.removeValue(forKey: file)
            }
        }
    }

    private func reloadApplications() {
        guard let first = files.first else {
            applications = []
            selectedApplicationID = nil
            return
        }
        var common = Dictionary(uniqueKeysWithValues: launchServices
            .capableApplications(forFileAt: first).map { ($0.bundleIdentifier, $0) })
        for file in files.dropFirst() {
            let identifiers = Set(launchServices.capableApplications(forFileAt: file)
                .map(\.bundleIdentifier))
            common = common.filter { identifiers.contains($0.key) }
        }
        applications = Array(common.values).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if let manuallySelectedApplication,
           common[manuallySelectedApplication.bundleIdentifier] == nil {
            applications.append(manuallySelectedApplication)
        }
        if !applications.contains(where: { $0.id == selectedApplicationID }) {
            selectedApplicationID = nil
        }
    }

    private func chooseOtherApplication() {
        Task { @MainActor in
            guard let url = await chooseApplicationURL() else { return }
            do {
                let application = try launchServices.applicationInfo(at: url)
                manuallySelectedApplication = application
                reloadApplications()
                selectedApplicationID = application.id
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func applySelection() {
        guard let application = selectedApplication else { return }
        isApplying = true
        statuses = Dictionary(uniqueKeysWithValues: files.map { ($0, .waiting) })
        showsFileDetails = true
        Task { @MainActor in
            for file in files {
                statuses[file] = .setting
                do {
                    try await launchServices.setDefaultAwaitingConsent(application, forFileAt: file)
                    statuses[file] = .verifying
                } catch {
                    statuses[file] = .failed(error.localizedDescription)
                }
            }

            await verifyAppliedApplication(application)
            isApplying = false
            let confirmed = statuses.values.filter { $0 == .confirmed }.count
            store.successMessage = L10n.format("fileAssociation.verifiedResult", confirmed,
                                               statuses.count - confirmed)
        }
    }

    private func verifyAppliedApplication(_ application: ApplicationInfo) async {
        let delays: [Duration] = [.zero, .milliseconds(300), .milliseconds(700), .seconds(1)]
        for delay in delays {
            if delay != .zero { try? await Task.sleep(for: delay) }
            let unresolved = files.filter { statuses[$0] == .verifying }
            guard !unresolved.isEmpty else { break }
            refreshCurrentApplications(for: unresolved)
            for file in unresolved where currentApplications[file]?.bundleIdentifier
                == application.bundleIdentifier {
                statuses[file] = .confirmed
            }
        }
        for file in files where statuses[file] == .verifying {
            statuses[file] = .unconfirmed
        }
    }
}

private struct CurrentApplicationGroup: Identifiable {
    let id: String
    let name: String
    let applicationURL: URL?
    let count: Int
}

private enum FileAssociationStatus: Equatable {
    case waiting
    case setting
    case verifying
    case confirmed
    case unconfirmed
    case failed(String)

    var isInProgress: Bool { self == .waiting || self == .setting || self == .verifying }

    var label: String {
        switch self {
        case .waiting: L10n.string("等待中")
        case .setting: L10n.string("正在设置")
        case .verifying: L10n.string("正在验证")
        case .confirmed: L10n.string("已确认生效")
        case .unconfirmed: L10n.string("未确认生效")
        case .failed: L10n.string("设置失败")
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "clock"
        case .setting, .verifying: "arrow.trianglehead.2.clockwise"
        case .confirmed: "checkmark.circle.fill"
        case .unconfirmed: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .waiting, .setting, .verifying: .secondary
        case .confirmed: .green
        case .unconfirmed: .orange
        case .failed: .red
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

private struct FallbackTypeMatch: Identifiable {
    let fileType: FileTypeInfo
    let displayName: String
    let defaultApplication: ApplicationInfo?
    let isPreferred: Bool
    let canChange: Bool
    var id: String { fileType.contentTypeIdentifier }
}
