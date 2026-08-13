import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AdvancedFeaturesView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var mode: AdvancedMode = .extensionAnalysis
    @State private var extensionQuery = ""
    @State private var analyzedExtension: String?
    @State private var analyses: [UTTypeAnalysis] = []
    @State private var inspectedFile: InspectedFile?
    @State private var inspectionError: String?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            Picker(L10n.string("高级功能模式"), selection: $mode) {
                Text(L10n.string("按扩展名分析")).tag(AdvancedMode.extensionAnalysis)
                Text(L10n.string("检查实际文件")).tag(AdvancedMode.fileInspection)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 360)
            .padding(.vertical, 14)
            Divider().opacity(0.45)

            switch mode {
            case .extensionAnalysis: extensionAnalysis
            case .fileInspection: fileInspection
            }
        }
        .alert(L10n.string("无法检查文件"), isPresented: Binding(
            get: { inspectionError != nil },
            set: { if !$0 { inspectionError = nil } }
        )) {
            Button(L10n.string("好"), role: .cancel) {}
        } message: {
            Text(inspectionError ?? "")
        }
        .onChange(of: store.defaultAppRevision) { _, _ in
            if analyzedExtension != nil { analyzeExtension() }
            if let url = inspectedFile?.url { inspectFile(at: url) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("高级功能")).font(.title2.weight(.semibold))
                Text(L10n.string("分析 UTType、文件类型和实际打开方式"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var extensionAnalysis: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(L10n.string("输入扩展名，例如 md"), text: $extensionQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { analyzeExtension() }
                Button(L10n.string("分析")) { analyzeExtension() }
                    .buttonStyle(.borderedProminent)
                    .disabled(normalizedExtension.isEmpty)
            }
            .padding(18)

            Divider()
            if analyses.isEmpty, let analyzedExtension {
                ContentUnavailableView(
                    L10n.format("advanced.noRegisteredTypes", "." + analyzedExtension),
                    systemImage: "questionmark.folder",
                    description: Text(L10n.string("系统没有返回与这个扩展名明确关联的已声明 UTType。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if analyses.isEmpty {
                ContentUnavailableView(
                    L10n.string("输入扩展名开始分析"),
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(L10n.string("结果会列出所有注册 UTType、遵循关系、默认 App 和可用 App。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(L10n.format("advanced.registeredTypes", "." + normalizedExtension,
                                             analyses.count))
                                .font(.headline)
                            Spacer()
                            Text(L10n.string("此页面仅用于诊断，不会修改系统设置。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        RegisteredUTTypeRelationshipsView(
                            identifiers: analyses.map(\.identifier)
                        )
                        ForEach(analyses) { analysis in
                            analysisCard(analysis)
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private var fileInspection: some View {
        VStack(spacing: 0) {
            fileDropArea.padding(18)
            Divider()
            if let inspectedFile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        fileSummary(inspectedFile)
                        analysisCard(inspectedFile.analysis)
                    }
                    .padding(18)
                }
            } else {
                ContentUnavailableView(
                    L10n.string("选择一个实际文件"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(L10n.string("比较文件自身的 UTType、UTType 默认 App 与双击时实际使用的 App。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var fileDropArea: some View {
        HStack(spacing: 14) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.ellipsis")
                .font(.system(size: 28)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("拖入文件，或从磁盘选择"))
                    .font(.headline)
                Text(L10n.string("只读取文件元数据，不会打开或修改文件。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.string("选择文件…")) { chooseFile() }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(isDropTargeted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [6]))
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url else { return }
                Task { @MainActor in inspectFile(at: url) }
            }
            return true
        }
    }

    private func fileSummary(_ file: InspectedFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.url.lastPathComponent).font(.headline)
                    Text(file.url.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Divider()
            diagnosticRow(title: "系统识别的 UTType", value: file.analysis.identifier)
            diagnosticRow(title: "双击时实际使用的 App", value: file.actualApplicationName)
            diagnosticRow(title: "UTType 默认 App", value: file.analysis.defaultApplicationName)
            Label(
                L10n.string(file.openingMethodsMatch
                            ? "实际打开方式与 UTType 默认 App 一致。"
                            : "实际打开方式与 UTType 默认 App 不同，可能存在单文件绑定或系统解析差异。"),
                systemImage: file.openingMethodsMatch ? "checkmark.circle.fill" : "info.circle.fill"
            )
            .font(.callout)
            .foregroundStyle(file.openingMethodsMatch ? Color.green : Color.orange)
        }
        .padding(16)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func diagnosticRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.string(title)).foregroundStyle(.secondary).frame(width: 190, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }

    private func analysisCard(_ analysis: UTTypeAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(analysis.displayName).font(.headline)
                    Text(analysis.identifier).font(.callout.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                riskBadge(analysis.risk)
            }
            HStack(spacing: 22) {
                metadataLabel("扩展名", value: analysis.extensions)
                metadataLabel("MIME 类型", value: analysis.mimeTypes)
                metadataLabel("默认 App", value: analysis.defaultApplicationName)
                metadataLabel("可用 App", value: L10n.format("advanced.appCount", analysis.capableAppCount))
            }
            Divider()
            Text(L10n.string("UTType 遵循关系（由具体到宽泛）"))
                .font(.callout.weight(.semibold))
            UTTypeHierarchyRelationshipsView(identifier: analysis.identifier)
        }
        .padding(16)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func riskBadge(_ risk: FileTypeModificationRisk) -> some View {
        switch risk {
        case .normal:
            Text(L10n.string("具体类型")).foregroundStyle(.secondary)
        case .broad:
            Label(L10n.string("较宽泛类型"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .protected:
            Label(L10n.string("只读基础类型"), systemImage: "lock.fill")
                .foregroundStyle(.orange)
        }
    }

    private func metadataLabel(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).lineLimit(1).help(value)
        }
    }

    private var normalizedExtension: String {
        extensionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private func analyzeExtension() {
        let ext = normalizedExtension
        guard !ext.isEmpty else { return }
        extensionQuery = ext
        analyzedExtension = ext
        let types = store.registeredFileTypes(forExtension: ext)
        store.refreshDefaults(for: types)
        analyses = types.compactMap(makeAnalysis)
    }

    private func makeAnalysis(for fileType: FileTypeInfo) -> UTTypeAnalysis? {
        guard let type = UTType(fileType.contentTypeIdentifier) else { return nil }
        return UTTypeAnalysis(
            identifier: type.identifier,
            displayName: type.localizedDescription ?? fileType.specificDisplayName,
            extensions: type.tags[.filenameExtension]?.map { "." + $0 }.joined(separator: ", ")
                ?? fileType.dottedExtension,
            mimeTypes: type.tags[.mimeType]?.joined(separator: ", ") ?? "—",
            defaultApplicationName: store.defaultApplication(for: fileType)?.name ?? L10n.string("未设置"),
            defaultApplicationBundleID: store.defaultApplication(for: fileType)?.bundleIdentifier,
            capableAppCount: store.capableApplications(for: fileType).count,
            risk: store.modificationRisk(for: fileType)
        )
    }

    private func chooseFile() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.title = L10n.string("选择要检查的文件")
            panel.prompt = L10n.string("检查")
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.treatsFilePackagesAsDirectories = false
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            let response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            if response == .OK, let url = panel.url { inspectFile(at: url) }
        }
    }

    private func inspectFile(at url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let type = values.contentType else {
                throw AdvancedInspectionError.noContentType
            }
            let ext = url.pathExtension.lowercased()
            let fileType = FileTypeInfo(extensionName: ext,
                                        contentTypeIdentifier: type.identifier,
                                        displayName: type.localizedDescription ?? type.identifier)
            store.refreshDefaults(for: [fileType])
            guard let analysis = makeAnalysis(for: fileType) else {
                throw AdvancedInspectionError.noContentType
            }
            let actualURL = NSWorkspace.shared.urlForApplication(toOpen: url)
            let actualBundleID = actualURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
            inspectedFile = InspectedFile(
                url: url,
                analysis: analysis,
                actualApplicationName: actualURL.map(applicationName) ?? L10n.string("未设置"),
                openingMethodsMatch: actualBundleID != nil
                    && actualBundleID == analysis.defaultApplicationBundleID
            )
        } catch {
            inspectionError = error.localizedDescription
        }
    }

    private func applicationName(at url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
    }
}

private enum AdvancedMode: Hashable {
    case extensionAnalysis
    case fileInspection
}

private struct UTTypeAnalysis: Identifiable {
    let identifier: String
    let displayName: String
    let extensions: String
    let mimeTypes: String
    let defaultApplicationName: String
    let defaultApplicationBundleID: String?
    let capableAppCount: Int
    let risk: FileTypeModificationRisk
    var id: String { identifier }
}

private struct InspectedFile {
    let url: URL
    let analysis: UTTypeAnalysis
    let actualApplicationName: String
    let openingMethodsMatch: Bool
}

private enum AdvancedInspectionError: LocalizedError {
    case noContentType

    var errorDescription: String? {
        L10n.string("无法取得这个文件的 UTType。")
    }
}
