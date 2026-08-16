import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
func chooseApplicationURL() async -> URL? {
    let panel = NSOpenPanel()
    panel.title = L10n.string("选择 App")
    panel.prompt = L10n.string("选择")
    panel.message = L10n.string("请选择一个能够处理目标类型的 App。")
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.applicationBundle]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.treatsFilePackagesAsDirectories = false
    guard let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
        return nil
    }
    return await withCheckedContinuation { continuation in
        panel.beginSheetModal(for: parentWindow) { response in
            continuation.resume(returning: response == .OK ? panel.url : nil)
        }
    }
}

@MainActor
func chooseFileURLs() async -> [URL] {
    let panel = NSOpenPanel()
    panel.title = L10n.string("选择文件")
    panel.prompt = L10n.string("选择")
    panel.message = L10n.string("选择一个或多个要单独设置打开方式的文件。")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = true
    guard let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
        return []
    }
    return await withCheckedContinuation { continuation in
        panel.beginSheetModal(for: parentWindow) { response in
            continuation.resume(returning: response == .OK ? panel.urls : [])
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

struct NativeMultilineTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 5, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        scrollView.documentView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
        context.coordinator.updateScrollerVisibility()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.textView?.string != text {
            context.coordinator.textView?.string = text
        }
        DispatchQueue.main.async {
            context.coordinator.updateScrollerVisibility()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            updateScrollerVisibility()
        }

        func updateScrollerVisibility() {
            guard let scrollView, let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = layoutManager.usedRect(for: textContainer).height
                + textView.textContainerInset.height * 2
            scrollView.hasVerticalScroller = contentHeight > scrollView.contentSize.height + 0.5
        }
    }
}

struct IsolatedScrollEvents: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.hostView = view
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var hostView: NSView?
        private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let hostView,
                      let window = hostView.window,
                      event.window === window,
                      let scrollView = hostView.enclosingScrollView else { return event }
                let location = scrollView.convert(event.locationInWindow, from: nil)
                guard scrollView.bounds.contains(location) else { return event }
                scrollView.verticalScrollElasticity = .none
                let clipView = scrollView.contentView
                guard let documentView = scrollView.documentView else { return nil }
                let documentHeight = documentView.bounds.height
                let viewportHeight = clipView.bounds.height
                let maximumY = max(0, documentHeight - viewportHeight)
                let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                let proposedY = clipView.bounds.origin.y - event.scrollingDeltaY * multiplier
                let constrainedY = min(max(proposedY, 0), maximumY)
                if abs(constrainedY - clipView.bounds.origin.y) > 0.01 {
                    clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: constrainedY))
                    scrollView.reflectScrolledClipView(clipView)
                }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}

struct TranslucentRow: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.17) : Color.white.opacity(0.035))
            }
            .contentShape(Rectangle())
    }
}

struct SearchBox: View {
    @EnvironmentObject private var languageSettings: LanguageSettings
    let prompt: String
    @Binding var text: String
    @Binding var effectiveText: String
    var debounceMilliseconds = 180

    var body: some View {
        NativeSearchField(prompt: languageSettings.string(prompt),
                          text: $text,
                          effectiveText: $effectiveText,
                          debounceMilliseconds: debounceMilliseconds)
            .frame(width: 220, height: 28)
    }
}

private struct NativeSearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    @Binding var effectiveText: String
    let debounceMilliseconds: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text,
                    effectiveText: $effectiveText,
                    debounceMilliseconds: debounceMilliseconds)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.controlSize = .regular
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        field.placeholderString = prompt
        context.coordinator.debounceMilliseconds = debounceMilliseconds
        if field.stringValue != text {
            field.stringValue = text
            context.coordinator.commitImmediately(text)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String
        @Binding private var effectiveText: String
        private var pendingUpdate: DispatchWorkItem?
        var debounceMilliseconds: Int

        init(text: Binding<String>, effectiveText: Binding<String>, debounceMilliseconds: Int) {
            _text = text
            _effectiveText = effectiveText
            self.debounceMilliseconds = debounceMilliseconds
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text = field.stringValue
            pendingUpdate?.cancel()
            guard let editor = field.currentEditor() as? NSTextView,
                  !editor.hasMarkedText() else { return }
            if field.stringValue.isEmpty {
                commitImmediately("")
                return
            }
            let value = field.stringValue
            let update = DispatchWorkItem { [weak self] in
                self?.effectiveText = value
            }
            pendingUpdate = update
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(debounceMilliseconds),
                execute: update
            )
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            commitImmediately(field.stringValue)
        }

        func commitImmediately(_ value: String) {
            pendingUpdate?.cancel()
            pendingUpdate = nil
            effectiveText = value
        }
    }
}
