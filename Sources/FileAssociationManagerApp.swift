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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange(_:)),
            name: LanguageSettings.changedNotification,
            object: nil
        )
        setupMainMenu()
        registerSpotlightKeywords()
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType else { return false }
        showMainWindow()
        return true
    }

    private func registerSpotlightKeywords() {
        let attributes = CSSearchableItemAttributeSet(contentType: .application)
        attributes.title = "DefaultOpen"
        attributes.displayName = languageSettings.string("DefaultOpen — 默认打开方式")
        attributes.contentDescription = languageSettings.string("管理默认应用、默认打开方式和文件关联")
        attributes.keywords = languageSettings.string("默认,默认打开,默认应用,文件关联,扩展名,打开方式")
            .components(separatedBy: ",")
        attributes.contentURL = Bundle.main.bundleURL
        let item = CSSearchableItem(
            uniqueIdentifier: "com.lalalaladam.DefaultOpen.application",
            domainIdentifier: "com.lalalaladam.DefaultOpen",
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
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
        registerSpotlightKeywords()
        aboutWindowController?.rebuildContent()
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

        let credits = label(
            languageSettings.string("about.projectInformation"),
            size: 12,
            color: .secondaryLabelColor
        )
        credits.alignment = .center
        credits.maximumNumberOfLines = 0
        credits.lineBreakMode = .byWordWrapping
        credits.preferredMaxLayoutWidth = size.width - 64
        place(credits, in: content, top: &top, height: 128, width: size.width - 64)

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
