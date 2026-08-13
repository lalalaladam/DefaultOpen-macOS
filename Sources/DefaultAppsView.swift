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
            VStack(alignment: .leading, spacing: 2) {
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
                if status.ignoredTypeCount > 0 {
                    Text(L10n.format("status.ignoredTypeCount", status.ignoredTypeCount))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .font(.body.weight(.medium))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label(L10n.string("尚未统一"), systemImage: "exclamationmark.circle")
                    .font(.body.weight(.medium)).foregroundStyle(.orange)
                ForEach(status.assignments.prefix(2)) { assignment in
                    let assignmentText = L10n.format(
                        "status.assignment",
                        assignment.application.name,
                        assignment.targets.joined(separator: L10n.string("list.separator"))
                    )
                    Text(assignmentText)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .help(assignmentText)
                }
                if status.assignments.count > 2 {
                    Text(L10n.format("status.moreApps", status.assignments.count - 2))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !status.missingTargets.isEmpty {
                    let missingText = L10n.format(
                        "status.notSet",
                        status.missingTargets.joined(separator: L10n.string("list.separator"))
                    )
                    Text(missingText)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .help(missingText)
                }
                if status.ignoredTypeCount > 0 {
                    Text(L10n.format("status.ignoredTypeCount", status.ignoredTypeCount))
                        .font(.callout).foregroundStyle(.secondary)
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

private struct ExtensionGroupTemplate: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let extensionList: String

    var extensions: [String] { extensionList.split(separator: " ").map(String.init) }

    static let all: [ExtensionGroupTemplate] = [
        .init(id: "image", title: "完整图片格式", subtitle: "常见、专业图像与主流 RAW 格式", symbol: "photo", extensionList: "jpg jpeg jpe jfif png apng gif bmp dib tif tiff heic heif avif webp svg svgz ico icns psd psb xcf kra ora exr hdr dds tga pcx ppm pgm pbm pnm jp2 j2k jpf jpx jpm mj2 raw dng cr2 cr3 nef nrw arw srf sr2 orf rw2 raf pef srw x3f"),
        .init(id: "video", title: "完整视频格式", subtitle: "视频容器、摄像机与流媒体格式", symbol: "play.rectangle", extensionList: "mp4 m4v mov qt mkv webm avi divx wmv asf flv f4v mpeg mpg mpe m2v mpv ts mts m2ts vob ogv 3gp 3g2 rm rmvb dv mxf roq y4m amv nsv nut h264 h265 hevc"),
        .init(id: "audio", title: "完整音频格式", subtitle: "有损、无损、工程、MIDI 与有声书格式", symbol: "music.note", extensionList: "mp3 m4a aac wav wave flac ogg oga opus aiff aif aifc alac ape wv wma ac3 eac3 dts mka amr au snd caf mid midi kar ra ram voc tta tak spx m4b dsf dff pcm"),
        .init(id: "archive", title: "完整压缩与归档", subtitle: "压缩、软件包与常见归档容器", symbol: "archivebox", extensionList: "zip zipx rar r00 r01 7z tar tgz tbz tbz2 txz gz gzip bz bz2 xz lz lzma lzh lha z cab arj ace sit sitx sea cpio pax xar war jar ear apk ipa deb rpm pkg mpkg msi crx vsix whl egg iso"),
        .init(id: "office", title: "完整办公文档", subtitle: "Office、OpenDocument、iWork、模板与旧格式", symbol: "doc.text", extensionList: "doc docx docm dot dotx dotm rtf odt ott pages wps wpd xls xlsx xlsm xlsb xlt xltx xltm ods ots numbers csv tsv ppt pptx pptm pot potx potm pps ppsx ppsm odp otp key pdf xps oxps"),
        .init(id: "source", title: "编程源码", subtitle: "主流语言、脚本与系统开发格式", symbol: "chevron.left.forwardslash.chevron.right", extensionList: "c h cc cpp cxx hpp hh hxx m mm swift rs go java kt kts scala sc py pyw pyi rb php phpt pl pm lua r dart ex exs erl hrl fs fsi fsx fsproj cs csx vb vbs groovy gvy gradle clj cljs cljc edn hs lhs ml mli nim zig sol asm s pas pp tcl jl sh bash zsh fish ps1 bat cmd"),
        .init(id: "data", title: "配置与数据", subtitle: "配置、结构化数据、数据库与交换格式", symbol: "curlybraces", extensionList: "json json5 jsonl ndjson yaml yml toml xml plist ini cfg conf config properties prop env editorconfig gitconfig gitattributes gitignore npmrc yarnrc babelrc eslintrc prettierrc lock csv tsv psv sql sqlite sqlite3 db db3 mdb accdb parquet avro orc proto graphql gql rss atom geojson kml gpx"),
        .init(id: "web", title: "Web 开发", subtitle: "现代前端框架、模板与 Web 配置", symbol: "globe", extensionList: "html htm xhtml shtml css scss sass less styl js mjs cjs jsx ts mts cts tsx vue svelte astro wasm wat php asp aspx jsp hbs handlebars mustache ejs pug jade liquid twig njk mdx map webmanifest manifest htaccess"),
        .init(id: "subtitle", title: "字幕与歌词", subtitle: "字幕、歌词与广播字幕格式", symbol: "captions.bubble", extensionList: "srt ass ssa vtt webvtt sub idx smi sami lrc ttml dfxp scc stl sbv mpl mpl2 aqt jss rt usf cap sup itt"),
        .init(id: "ebook", title: "电子书与阅读", subtitle: "电子书、漫画包与阅读器格式", symbol: "books.vertical", extensionList: "epub mobi azw azw3 azw4 kf8 kfx fb2 fb3 djvu djv chm lit pdb prc tcr lrf lrx cbz cbr cb7 cbt opf ncx ibooks kepub oxps xps"),
        .init(id: "font", title: "字体", subtitle: "桌面字体、Web 字体与传统字体资源", symbol: "textformat", extensionList: "ttf otf ttc otc woff woff2 eot dfont suit fon fnt pfa pfb pfm afm bdf pcf snf ufo sfd"),
        .init(id: "design", title: "设计与 CAD", subtitle: "平面设计、CAD、BIM 与 3D 格式", symbol: "paintbrush", extensionList: "psd psb ai ait eps epsf indd indt idml xd sketch fig afdesign afphoto afpub cdr cmx dwg dxf dwt dws step stp iges igs sat sab stl obj fbx dae 3ds blend max ma mb c4d lwo lws ply gltf glb usd usda usdc usdz 3mf skp rvt rfa ifc fcstd sldprt sldasm prt asm"),
        .init(id: "disk", title: "磁盘与虚拟机镜像", subtitle: "磁盘、光盘、虚拟机与系统镜像", symbol: "externaldrive", extensionList: "dmg iso img sparseimage sparsebundle cdr toast bin cue nrg mdf mds vhd vhdx vdi vmdk qcow qcow2 qed hdd pvm ova ovf vbox utm ipsw wim esd squashfs")
    ]
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
    @State private var extensionSearchText = ""
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
                    Menu {
                        ForEach(ExtensionGroupTemplate.all) { template in
                            Button {
                                appendTemplate(template)
                            } label: {
                                Label(L10n.string(template.title), systemImage: template.symbol)
                            }
                        }
                    } label: {
                        Label(L10n.string("从模板添加…"), systemImage: "square.stack.3d.up.badge.a")
                    }
                    Spacer()
                    if !extensionNames.isEmpty {
                        Button(L10n.string("清空标签"), role: .destructive) {
                            extensionNames.removeAll()
                            extensionSearchText = ""
                        }
                    }
                }
                Text(L10n.string("可直接输入或粘贴多个扩展名，使用逗号、空格、分号或换行分隔；句点会自动移除，重复项会自动合并。"))
                    .font(.caption).foregroundStyle(.secondary)
                if !normalizedExtensions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.format("status.extensionCount", normalizedExtensions.count))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            TextField(L10n.string("搜索标签"), text: $extensionSearchText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                        }
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 7)], alignment: .leading, spacing: 7) {
                                    ForEach(filteredExtensions, id: \.self) { extensionName in
                                        HStack(spacing: 4) {
                                            Text(".\(extensionName)").font(.callout.monospaced())
                                                .lineLimit(1)
                                                .help(".\(extensionName)")
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
                                .background(IsolatedScrollEvents())
                            }
                            .padding(.trailing, 4)
                            .frame(maxHeight: 112)
                            .onChange(of: scrollRequestID) { _, _ in
                                guard extensionSearchText.isEmpty, let latestExtension = scrollTarget else { return }
                                withAnimation {
                                    proxy.scrollTo(latestExtension, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Button {
                        choosingFileTypes = true
                    } label: {
                        Label(L10n.string("从扩展名选择…"), systemImage: "checklist")
                    }
                    Spacer()
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
            DefaultAppFileTypeSelectionSheet(initiallySelected: []) { selected in
                appendExtensionsToDraft(selected.sorted())
                choosingFileTypes = false
            }
            .environmentObject(store)
        }
    }

    private func removeExtension(_ extensionName: String) {
        extensionNames.removeAll { $0 == extensionName }
    }

    private var filteredExtensions: [String] {
        let query = extensionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return normalizedExtensions }
        return normalizedExtensions.filter { $0.localizedCaseInsensitiveContains(query) }
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

    private func appendTemplate(_ template: ExtensionGroupTemplate) {
        let recognized = store.recognizedExtensions(template.extensions)
        appendExtensionsToDraft(recognized)
    }

    private func appendExtensionsToDraft(_ candidates: [String]) {
        let existing = Set(parsedExtensions(from: extensionDraft))
        let additions = candidates.filter { !existing.contains($0) }.uniquedPreservingOrder()
        if !additions.isEmpty {
            let separator = extensionDraft.isEmpty || extensionDraft.last?.isWhitespace == true ? "" : " "
            extensionDraft += separator + additions.joined(separator: " ")
        }
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
        store.matchingCatalogFileTypes(for: searchText, includeAll: showsAllTypes).sorted {
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
                    Text(L10n.string("选择扩展名")).font(.title2.weight(.semibold))
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
                                .lineLimit(1).truncationMode(.tail)
                                .help(type.dottedExtension)
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
                Button(L10n.string("使用所选扩展名")) { onDone(selected) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 760, height: 650)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .task(id: searchText) {
            if showsAllTypes || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await store.loadAllFileTypes()
            }
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
    @State private var showsTypeDetails = false
    @State private var confirmsBroadTypeChange = false

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
                        let assignmentText = L10n.format(
                            "status.assignment",
                            assignment.application.name,
                            assignment.targets.joined(separator: L10n.string("list.separator"))
                        )
                        Text(assignmentText)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help(assignmentText)
                    }
                    if !currentStatus.missingTargets.isEmpty {
                        let missingText = L10n.format(
                            "status.notSet",
                            currentStatus.missingTargets.joined(separator: L10n.string("list.separator"))
                        )
                        Text(missingText)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help(missingText)
                    }
                }
                if currentStatus.ignoredTypeCount > 0 {
                    Text(L10n.format("status.ignoredTypeCount", currentStatus.ignoredTypeCount))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if category.hasOptionalExtensions {
                    Divider().padding(.vertical, 3)
                    HStack(spacing: 8) {
                        Text(L10n.string("扩展格式状态：")).foregroundStyle(.secondary)
                        if let app = optionalStatus.unifiedApplication {
                            AppIcon(url: app.url, size: 18)
                            Text(app.name).fontWeight(.medium)
                            Text(optionalDescription).foregroundStyle(.secondary)
                                .lineLimit(1).help(optionalDescription)
                        } else {
                            Text(L10n.string("尚未统一"))
                                .fontWeight(.medium).foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    if !optionalStatus.isUnified {
                        ForEach(optionalStatus.assignments) { assignment in
                            let assignmentText = L10n.format(
                                "status.assignment",
                                assignment.application.name,
                                assignment.targets.joined(separator: L10n.string("list.separator"))
                            )
                            Text(assignmentText)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .help(assignmentText)
                        }
                        if !optionalStatus.missingTargets.isEmpty {
                            let missingText = L10n.format(
                                "status.notSet",
                                optionalStatus.missingTargets.joined(separator: L10n.string("list.separator"))
                            )
                            Text(missingText)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .help(missingText)
                        }
                    }
                    if optionalStatus.ignoredTypeCount > 0 {
                        Text(L10n.format("status.ignoredTypeCount", optionalStatus.ignoredTypeCount))
                            .font(.caption).foregroundStyle(.secondary)
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
                ScrollViewReader { proxy in
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
                                        let targetsText = L10n.format(
                                            "status.currentTargets",
                                            candidate.currentTargets.joined(separator: L10n.string("list.separator"))
                                        )
                                        Text(targetsText)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            .help(targetsText)
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
                        .id(candidate.id)
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: selectedCandidateID) { _, candidateID in
                        guard let candidateID else { return }
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo(candidateID)
                        }
                    }
                }
            }

            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    selectionSummary
                }
                .onChange(of: showsTypeDetails) { _, showsDetails in
                    guard showsDetails else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo("type-details", anchor: .top)
                        }
                    }
                }
            }
            .frame(height: selectionSummaryHeight)

            Divider()
            actionBar
        }
        .frame(width: 620, height: 680)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .onAppear { reloadCandidates() }
        .onChange(of: store.defaultAppRevision) { _, _ in
            reloadCandidates()
            didChange()
        }
        .alert(L10n.string("无法使用所选 App"), isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button(L10n.string("好"), role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
        .confirmationDialog(L10n.string("修改较宽泛的 UTType？"),
                            isPresented: $confirmsBroadTypeChange,
                            titleVisibility: .visible) {
            Button(L10n.string("继续设置")) { applySelection() }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(L10n.format(
                "typeRisk.batchConfirmation",
                store.broadTypeIdentifiers(for: category, includingOptional: includesOptional)
                    .joined(separator: L10n.string("list.separator"))
            ))
        }
    }

    private var targetDescription: String {
        if !category.urlSchemes.isEmpty { return L10n.string("处理 HTTP 和 HTTPS 网页链接") }
        return category.coreExtensions.map { "." + $0 }.joined(separator: L10n.string("list.separator"))
    }

    private var selectionSummaryHeight: CGFloat {
        guard selectedCandidate != nil else { return 56 }
        return 138
    }

    @ViewBuilder private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let candidate = selectedCandidate {
                Text(L10n.format("picker.setCategory", candidate.application.name, category.title))
                    .font(.headline)
                let managedSupportedTargets = candidate.typeDetails.filter {
                    $0.isSupported && !$0.isIgnored
                }.map(\.label).uniquedPreservingOrder()
                let managedUnsupportedTargets = candidate.typeDetails.filter {
                    !$0.isSupported && !$0.isIgnored
                }.map(\.label).uniquedPreservingOrder()
                Text(L10n.format("picker.willChange", managedSupportedTargets.joined(separator: L10n.string("list.separator"))))
                    .font(.callout).foregroundStyle(.secondary)
                let estimatedChanges = candidate.typeDetails.filter {
                    $0.isSupported && !$0.isCurrentDefault && !$0.isIgnored
                }.count
                Text(L10n.format("picker.estimatedChanges", estimatedChanges))
                    .font(.caption).foregroundStyle(.secondary)
                if !managedUnsupportedTargets.isEmpty {
                    Text(L10n.format("picker.unsupportedTargets", managedUnsupportedTargets.joined(separator: L10n.string("list.separator"))))
                        .font(.callout).foregroundStyle(.orange)
                }
                Button {
                    showsTypeDetails.toggle()
                } label: {
                    Label(L10n.string(showsTypeDetails ? "隐藏类型详情" : "显示类型详情"),
                          systemImage: showsTypeDetails ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                if showsTypeDetails {
                    VStack(spacing: 0) {
                        ForEach(candidate.typeDetails) { detail in
                            typeDetailRow(detail)
                            if detail.id != candidate.typeDetails.last?.id { Divider() }
                        }
                    }
                    .id("type-details")
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
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private func typeDetailRow(_ detail: DefaultAppCandidateTypeDetail) -> some View {
        HStack(spacing: 8) {
            Image(systemName: detail.isIgnored ? "eye.slash.fill"
                  : detail.isSupported ? "checkmark.circle.fill" : "minus.circle.fill")
                .foregroundStyle(detail.isIgnored ? Color.secondary
                                 : detail.isSupported ? Color.green : Color.orange)
            Text(detail.label).font(.callout.monospaced())
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(detail.typeName).lineLimit(1)
                Text(detail.technicalIdentifier)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 6) {
                if detail.isCurrentDefault {
                    Text(L10n.string("当前默认")).font(.caption).foregroundStyle(.green)
                }
                if detail.isIgnored {
                    Text(L10n.string("已忽略")).font(.caption).foregroundStyle(.secondary)
                } else if !detail.isSupported {
                    Text(L10n.string("不会修改")).font(.caption).foregroundStyle(.orange)
                }
            }
            if detail.canBeIgnored {
                Button(L10n.string(detail.isIgnored ? "重新纳入" : "忽略此类型")) {
                    store.setDefaultAppType(detail.technicalIdentifier,
                                            ignored: !detail.isIgnored,
                                            for: category)
                }
                .buttonStyle(.borderless)
                .disabled(isApplying)
            }
        }
        .padding(.vertical, 5)
    }

    private var actionBar: some View {
        HStack {
            Button {
                chooseOtherApplication()
            } label: {
                Label(L10n.string("选择其他 App…"), systemImage: "folder")
            }
            .disabled(isApplying)
            Spacer()
            Button(L10n.string("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction).disabled(isApplying)
            Button {
                if store.broadTypeIdentifiers(for: category,
                                              includingOptional: includesOptional).isEmpty {
                    applySelection()
                } else {
                    confirmsBroadTypeChange = true
                }
            } label: {
                if isApplying {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("正在设置…"))
                } else {
                    Text(L10n.format("action.setAsCategory", category.title))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedCandidate?.typeDetails.contains(where: {
                $0.isSupported && !$0.isIgnored
            }) != true || isApplying)
        }
        .padding(16)
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
            showsTypeDetails = false
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
