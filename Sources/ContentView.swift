import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var section: SidebarSection? = .fileTypes

    var body: some View {
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()

            NavigationSplitView {
                List(SidebarSection.allCases, selection: $section) { item in
                    Label(item.rawValue, systemImage: item.symbol)
                        .tag(item)
                }
                .scrollContentBackground(.hidden)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            } detail: {
                Group {
                    switch section ?? .fileTypes {
                    case .fileTypes: FileTypesView()
                    case .applications: ApplicationsView()
                    }
                }
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
