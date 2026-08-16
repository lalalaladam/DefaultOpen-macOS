import AppKit
import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DefaultOpenAppDelegate: NSObject, NSApplicationDelegate {
    private let store = AssociationStore()
    private let languageSettings = LanguageSettings.shared
    private var mainWindowController: NSWindowController?
    private var aboutWindowController: AboutWindowController?
    private var activationRefreshTask: Task<Void, Never>?
    private var applicationDirectoryRefreshTask: Task<Void, Never>?
    private var removalStabilizationTask: Task<Void, Never>?
    private var requiresApplicationRescan = false
    private let applicationDirectoryMonitor = ApplicationDirectoryMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange(_:)),
            name: LanguageSettings.changedNotification,
            object: nil
        )
        setupMainMenu()
        removeLegacySpotlightItems()
        showMainWindow()
        applicationDirectoryMonitor.start { [weak self] in
            DispatchQueue.main.async {
                self?.scheduleApplicationDirectoryRefresh()
            }
        }
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(applicationEnvironmentDidChange(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(applicationEnvironmentDidChange(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(applicationEnvironmentDidChange(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleExternalRefresh(after: .milliseconds(350))
    }

    private func scheduleExternalRefresh(after delay: Duration, rescanApplications: Bool = false) {
        requiresApplicationRescan = requiresApplicationRescan || rescanApplications
        activationRefreshTask?.cancel()
        activationRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let shouldRescanApplications = requiresApplicationRescan
            requiresApplicationRescan = false
            if shouldRescanApplications {
                await store.scanApplications()
            } else {
                await store.refreshAfterActivation()
            }
        }
    }

    private func scheduleApplicationDirectoryRefresh() {
        applicationDirectoryRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let removedApplication = await store.refreshAfterApplicationDirectoryChange()
            guard !Task.isCancelled, removedApplication else { return }
            scheduleRemovalStabilization()
        }
    }

    private func scheduleRemovalStabilization() {
        removalStabilizationTask?.cancel()
        removalStabilizationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled, let self else { return }
            await store.scanApplications()

            try? await Task.sleep(for: .milliseconds(2_500))
            guard !Task.isCancelled else { return }
            await store.scanApplications()
        }
    }

    @objc private func applicationEnvironmentDidChange(_ notification: Notification) {
        if notification.name == NSWorkspace.didLaunchApplicationNotification,
           let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
           application.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        scheduleExternalRefresh(after: .milliseconds(750), rescanApplications: true)
        if notification.name == NSWorkspace.didUnmountNotification {
            scheduleRemovalStabilization()
        }
    }

    private func removeLegacySpotlightItems() {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [
            "com.lalalaladam.DefaultOpen.application",
            "com.lalalaladam.DefaultOpen.search-aliases.v2"
        ]) { error in
            if let error {
                NSLog("DefaultOpen could not remove its two legacy Spotlight items: %@",
                      error.localizedDescription)
            } else {
                NSLog("DefaultOpen removed its two legacy Spotlight items.")
            }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")
        let appMenuItem = NSMenuItem(title: "DefaultOpen", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "DefaultOpen")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let aboutItem = NSMenuItem(
            title: languageSettings.string("About DefaultOpen"),
            action: #selector(showDefaultOpenCustomAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: languageSettings.string("Settings…"),
            action: #selector(showLanguageSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: languageSettings.string("Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: languageSettings.string("Services"))
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(title: languageSettings.string("Hide DefaultOpen"),
                                  action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: languageSettings.string("Hide Others"),
                                        action: #selector(NSApplication.hideOtherApplications(_:)),
                                        keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(title: languageSettings.string("Show All"),
                                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: languageSettings.string("Quit DefaultOpen"),
                                  action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        addEditMenu(to: mainMenu)
        addViewMenu(to: mainMenu)
        addWindowMenu(to: mainMenu)
        NSApp.mainMenu = mainMenu
    }

    private func addEditMenu(to mainMenu: NSMenu) {
        let root = NSMenuItem(title: languageSettings.string("Edit"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: languageSettings.string("Edit"))
        root.submenu = menu
        mainMenu.addItem(root)
        addResponderItem(languageSettings.string("Undo"), action: Selector(("undo:")), key: "z", to: menu)
        addResponderItem(languageSettings.string("Redo"), action: Selector(("redo:")), key: "Z", to: menu)
        menu.addItem(.separator())
        addResponderItem(languageSettings.string("Cut"), action: #selector(NSText.cut(_:)), key: "x", to: menu)
        addResponderItem(languageSettings.string("Copy"), action: #selector(NSText.copy(_:)), key: "c", to: menu)
        addResponderItem(languageSettings.string("Paste"), action: #selector(NSText.paste(_:)), key: "v", to: menu)
        addResponderItem(languageSettings.string("Select All"), action: #selector(NSText.selectAll(_:)), key: "a", to: menu)
    }

    private func addViewMenu(to mainMenu: NSMenu) {
        let root = NSMenuItem(title: languageSettings.string("View"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: languageSettings.string("View"))
        root.submenu = menu
        mainMenu.addItem(root)
        let sidebar = NSMenuItem(title: languageSettings.string("Toggle Sidebar"), action: Selector(("toggleSidebar:")), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        sidebar.target = nil
        menu.addItem(sidebar)
    }

    private func addWindowMenu(to mainMenu: NSMenu) {
        let root = NSMenuItem(title: languageSettings.string("Window"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: languageSettings.string("Window"))
        root.submenu = menu
        mainMenu.addItem(root)
        addResponderItem(languageSettings.string("Close"), action: #selector(NSWindow.performClose(_:)), key: "w", to: menu)
        addResponderItem(languageSettings.string("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), key: "m", to: menu)
        addResponderItem(languageSettings.string("Zoom"), action: #selector(NSWindow.performZoom(_:)), key: "", to: menu)
        NSApp.windowsMenu = menu
    }

    private func addResponderItem(_ title: String, action: Selector, key: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        menu.addItem(item)
    }

    private func showMainWindow() {
        var needsInitialReveal = false
        if mainWindowController == nil {
            let rootView = ContentView()
                .environmentObject(store)
                .environmentObject(languageSettings)
                .environment(\.locale, languageSettings.language.locale)
                .frame(minWidth: 1180, minHeight: 680)
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1440, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "DefaultOpen"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.animationBehavior = .none
            window.alphaValue = 0
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 1180, height: 680)
            window.contentViewController = hostingController
            window.contentView?.layoutSubtreeIfNeeded()
            window.center()
            mainWindowController = NSWindowController(window: window)
            needsInitialReveal = true
        }
        mainWindowController?.showWindow(nil)
        if needsInitialReveal {
            guard let window = mainWindowController?.window else { return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            prepareInitialReveal(of: window, remainingPasses: 2)
            return
        }
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func prepareInitialReveal(of window: NSWindow, remainingPasses: Int) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            if remainingPasses > 1 {
                self.prepareInitialReveal(of: window, remainingPasses: remainingPasses - 1)
            } else {
                self.lowerWindowControls(in: window)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1
                }
            }
        }
    }

    private func lowerWindowControls(in window: NSWindow) {
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            var frame = button.frame
            frame.origin.y -= 7
            button.setFrameOrigin(frame.origin)
        }
    }

    @objc func showDefaultOpenCustomAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController(languageSettings: languageSettings)
        }
        aboutWindowController?.rebuildContent()
        aboutWindowController?.present()
    }

    @objc private func showLanguageSettings(_ sender: Any?) {
        showMainWindow()
        NotificationCenter.default.post(name: LanguageSettings.showSettingsNotification, object: nil)
    }

    @objc private func languageDidChange(_ notification: Notification) {
        setupMainMenu()
        aboutWindowController?.rebuildContent()
    }
}

private final class ApplicationDirectoryMonitor {
    private let queue = DispatchQueue(label: "com.lalalaladam.DefaultOpen.application-monitor")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingUpdate: DispatchWorkItem?
    private var changeHandler: (() -> Void)?

    func start(changeHandler: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.changeHandler = changeHandler
            self.rebuildSources()
        }
    }

    private func rebuildSources() {
        sources.forEach { $0.cancel() }
        sources.removeAll()

        for directory in monitoredDirectories() {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.directoryDidChange() }
            source.setCancelHandler { close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }

    private func directoryDidChange() {
        pendingUpdate?.cancel()
        let update = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebuildSources()
            self.changeHandler?()
        }
        pendingUpdate = update
        queue.asyncAfter(deadline: .now() + .milliseconds(500), execute: update)
    }

    private func monitoredDirectories() -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        return roots + roots.flatMap { childDirectories(in: $0, remainingDepth: 2) }
    }

    private func childDirectories(in directory: URL, remainingDepth: Int) -> [URL] {
        guard remainingDepth > 0,
              let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return children.flatMap { child -> [URL] in
            guard child.pathExtension.lowercased() != "app",
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { return [] }
            return [child] + childDirectories(in: child, remainingDepth: remainingDepth - 1)
        }
    }
}

final class AboutWindowController: NSWindowController {
    private let languageSettings: LanguageSettings
#if DEBUG
    private static let contentSize = NSSize(width: 600, height: 528)
#else
    private static let contentSize = NSSize(width: 540, height: 428)
#endif

    init(languageSettings: LanguageSettings) {
        self.languageSettings = languageSettings
        let size = Self.contentSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = size
        window.contentMaxSize = size
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func rebuildContent() {
        guard let window else { return }
        let size = Self.contentSize
        window.title = languageSettings.string("About DefaultOpen")
        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        content.material = .underWindowBackground
        content.blendingMode = .behindWindow
        content.state = .active
        var top = size.height - 42

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.frame = NSRect(x: (size.width - 96) / 2, y: top - 96, width: 96, height: 96)
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)
        top -= 108

        let name = label("DefaultOpen", size: 24, weight: .semibold)
        name.alignment = .center
        place(name, in: content, top: &top, height: 30, gap: 6)

        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        let standardVersion = label("Version \(version) (Build \(build))", color: .secondaryLabelColor)
        standardVersion.alignment = .center
        place(standardVersion, in: content, top: &top, height: 18, gap: 18)

#if DEBUG
        let metadata = info["DefaultOpenDebugMetadata"] as? [String: Any] ?? [:]
        let debugText = [
            "Version: v\(version)",
            "Build: \(build)",
            "Commit: \(metadata["GitCommit"] as? String ?? "—")",
            "Status: \(metadata["TreeStatus"] as? String ?? "—")",
            "Build Time: \(metadata["BuildTimestamp"] as? String ?? "—")"
        ].joined(separator: "\n")
        let debugMetadata = label(debugText, size: 12, color: .secondaryLabelColor)
        debugMetadata.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        debugMetadata.alignment = .center
        place(debugMetadata, in: content, top: &top, height: 82, width: 330, gap: 18)
#endif

        let separator = NSBox(frame: NSRect(x: 32, y: top - 1, width: size.width - 64, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)
        top -= 19

        let projectTitle = label(languageSettings.string("about.projectTitle"), size: 12)
        projectTitle.alignment = .center
        projectTitle.isSelectable = false
        place(projectTitle, in: content, top: &top, height: 16, gap: 8)

        let repositoryButton = NSButton(
            title: "github.com/lalalaladam/DefaultOpen-macOS",
            target: self,
            action: #selector(openProjectRepository(_:))
        )
        repositoryButton.isBordered = false
        repositoryButton.font = .systemFont(ofSize: 12)
        repositoryButton.contentTintColor = .linkColor
        repositoryButton.alignment = .center
        repositoryButton.focusRingType = .none
        repositoryButton.frame = NSRect(x: 32, y: top - 18, width: size.width - 64, height: 18)
        content.addSubview(repositoryButton)
        top -= 26

        let technology = label(
            languageSettings.string("about.technology"),
            size: 12,
            color: .secondaryLabelColor
        )
        technology.alignment = .center
        technology.isSelectable = false
        place(technology, in: content, top: &top, height: 18, gap: 8)

        let projectDescription = label(
            languageSettings.string("about.description"),
            size: 12,
            color: .secondaryLabelColor
        )
        projectDescription.alignment = .center
        projectDescription.isSelectable = false
        projectDescription.maximumNumberOfLines = 0
        projectDescription.lineBreakMode = .byWordWrapping
        projectDescription.preferredMaxLayoutWidth = size.width - 64
        place(projectDescription, in: content, top: &top, height: 36, width: size.width - 64)

        window.contentView = content
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.center()
    }

    func present() {
        guard let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc private func openProjectRepository(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/lalalaladam/DefaultOpen-macOS") else { return }
        NSWorkspace.shared.open(url)
    }

    private func label(_ text: String, size: CGFloat = 13,
                       weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isSelectable = true
        return field
    }

    private func place(_ field: NSTextField, in content: NSView, top: inout CGFloat,
                       height: CGFloat, width: CGFloat? = nil, gap: CGFloat = 0) {
        let fieldWidth = width ?? content.frame.width - 64
        field.frame = NSRect(x: (content.frame.width - fieldWidth) / 2,
                             y: top - height, width: fieldWidth, height: height)
        content.addSubview(field)
        top -= height + gap
    }
}
