import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var section: SidebarSection? = .fileTypes

    var body: some View {
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView(selection: $section)
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
    @Binding var selection: SidebarSection?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(SidebarSection.allCases) { item in
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 10) {
                        SidebarSymbol(name: item.symbol)
                        Text(item.rawValue)
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
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
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
