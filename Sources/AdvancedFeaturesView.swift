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
            searchBar
            Divider().opacity(0.45)
            results
        }
        .onChange(of: store.defaultAppRevision) { _, _ in
            if let checkedExtension {
                loadExtension(checkedExtension, synchronizeQuery: false)
            }
        }
        .sheet(item: $typeBeingChanged) { type in
            ApplicationPickerSheet(type: type).environmentObject(store)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("修复未生效的默认打开方式"))
                    .font(.title2.weight(.semibold))
                Text(L10n.string("当部分同扩展名文件仍使用原来的 App 时，可在这里检查并修改其系统类型。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
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
        .padding(18)
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
                description: Text(L10n.string("普通设置未完全生效时，这里会列出 macOS 可能使用的其他类型。"))
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
                                             : "普通设置会修改首选类型；如果个别文件仍未变化，可修改下面的其他类型。"))
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

private struct FallbackTypeMatch: Identifiable {
    let fileType: FileTypeInfo
    let displayName: String
    let defaultApplication: ApplicationInfo?
    let isPreferred: Bool
    let canChange: Bool
    var id: String { fileType.contentTypeIdentifier }
}
