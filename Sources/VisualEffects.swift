import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
func chooseApplicationURL() -> URL? {
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
    return panel.runModal() == .OK ? panel.url : nil
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

    var body: some View {
        NativeSearchField(prompt: languageSettings.string(prompt), text: $text)
            .frame(width: 220, height: 28)
    }
}

private struct NativeSearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
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
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text = field.stringValue
        }
    }
}
