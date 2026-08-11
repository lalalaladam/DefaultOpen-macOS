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
        .alert("无法完成操作", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(store.errorMessage ?? "") }
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
                .buttonStyle(.plain)
            }
            Spacer()
            Button(action: settingsAction) {
                HStack(spacing: 10) {
                    SidebarSymbol(name: "gearshape")
                    Text("设置")
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

private struct LanguageSettingsView: View {
    @EnvironmentObject private var languageSettings: LanguageSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置").font(.title2.weight(.semibold))
                    Text("选择 DefaultOpen 使用的界面语言")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            Form {
                Picker("语言", selection: $languageSettings.language) {
                    Text("跟随系统").tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    Text("English").tag(AppLanguage.english)
                }
                Text("切换会立即应用；系统提供的应用名称和文件类型名称仍可能跟随 macOS 语言。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 300)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
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
