import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AssociationStore
    @EnvironmentObject private var languageSettings: LanguageSettings
    @State private var section: SidebarSection? = .fileTypes
    @State private var showsSettings = false

    var body: some View {
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView(selection: $section) { showsSettings = true }
                    .frame(width: 220)
                Divider().opacity(0.45)
                Group {
                    switch section ?? .fileTypes {
                    case .fileTypes: FileTypesView()
                    case .applications: ApplicationsView()
                    case .defaultApps: DefaultAppsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            }
        }
        .id(languageSettings.revision)
        .environment(\.locale, languageSettings.language.locale)
        .sheet(isPresented: $showsSettings) {
            LanguageSettingsView()
                .environmentObject(languageSettings)
                .environment(\.locale, languageSettings.language.locale)
        }
        .onReceive(NotificationCenter.default.publisher(for: LanguageSettings.showSettingsNotification)) { _ in
            showsSettings = true
        }
        .alert(L10n.string("无法完成操作"), isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) { Button(L10n.string("好"), role: .cancel) {} } message: { Text(store.errorMessage ?? "") }
        .overlay(alignment: .bottom) {
            if let message = store.successMessage {
                Text(message)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                    .padding(.bottom, 20)
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        if store.successMessage == message { store.successMessage = nil }
                    }
            }
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var languageSettings: LanguageSettings
    @Binding var selection: SidebarSection?
    let settingsAction: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(SidebarSection.allCases) { item in
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 10) {
                        SidebarSymbol(name: item.symbol)
                        Text(languageSettings.string(item.rawValue))
                            .font(.body.weight(.medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selection == item ? Color.accentColor : Color.clear)
                    }
                    .foregroundStyle(selection == item ? Color.white : Color.primary)
                }
                .buttonStyle(SidebarPressSelectingButtonStyle {
                    selection = item
                })
            }
            Spacer()
            Button(action: settingsAction) {
                HStack(spacing: 10) {
                    SidebarSymbol(name: "gearshape")
                    Text(L10n.string("设置"))
                        .font(.body.weight(.medium))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

private struct SidebarPressSelectingButtonStyle: ButtonStyle {
    let onPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { onPress() }
            }
    }
}

private struct LanguageSettingsView: View {
    @EnvironmentObject private var languageSettings: LanguageSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedLanguage: AppLanguage = .simplifiedChinese
    @State private var pendingLanguage: AppLanguage?
    @State private var languagePromptTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("设置")).font(.title2.weight(.semibold))
                    Text(L10n.string("选择 DefaultOpen 使用的界面语言"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            Form {
                Picker(L10n.string("语言"), selection: Binding(
                    get: { selectedLanguage },
                    set: { newLanguage in
                        requestLanguageChange(newLanguage)
                    }
                )) {
                    Text(L10n.string("简体中文")).tag(AppLanguage.simplifiedChinese)
                    Text(L10n.string("English")).tag(AppLanguage.english)
                }
                Text(L10n.string("选择后需要确认；系统提供的应用名称和文件类型名称仍可能跟随 macOS 语言。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 300)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .onAppear { selectedLanguage = languageSettings.language }
        .onDisappear { languagePromptTask?.cancel() }
        .alert(L10n.string("确认切换语言？"), isPresented: Binding(
            get: { pendingLanguage != nil },
            set: { if !$0 { cancelLanguageChange() } }
        )) {
            Button(L10n.string("取消"), role: .cancel) { cancelLanguageChange() }
            Button(L10n.string("切换语言")) { applyLanguageChange() }
        } message: {
            Text(languageChangeMessage)
        }
    }

    private var languageChangeMessage: String {
        guard let pendingLanguage else { return "" }
        let name = L10n.string(pendingLanguage.displayNameKey, language: languageSettings.language)
        return L10n.format("language.confirmationMessage", name)
    }

    private func requestLanguageChange(_ newLanguage: AppLanguage) {
        languagePromptTask?.cancel()
        guard newLanguage != languageSettings.language else { return }
        languagePromptTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, newLanguage != languageSettings.language else { return }
            pendingLanguage = newLanguage
        }
    }

    private func cancelLanguageChange() {
        languagePromptTask?.cancel()
        pendingLanguage = nil
        selectedLanguage = languageSettings.language
    }

    private func applyLanguageChange() {
        guard let pendingLanguage else { return }
        languagePromptTask?.cancel()
        self.pendingLanguage = nil
        languageSettings.language = pendingLanguage
        selectedLanguage = pendingLanguage
    }
}

private struct SidebarSymbol: View {
    let name: String

    var body: some View {
        Image(nsImage: NSImage(systemSymbolName: name, accessibilityDescription: nil)
              ?? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
              ?? NSImage())
            .frame(width: 22)
    }
}
