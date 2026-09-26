import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showForm = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome").font(.largeTitle.bold())
            Text("Upload files to your own storage, then instantly copy a shareable URL.")
                .multilineTextAlignment(.center)
            Text("No account. No proprietary cloud. Your files stay yours.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Connect Storage") { showForm = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(width: 420, height: 300)
        .sheet(isPresented: $showForm) {
            DestinationFormView(existing: nil) { config, credentials in
                var config = config
                config.isDefault = true
                appState.destinationStore.add(config)
                try? KeychainService.save(credentials, for: config.id)
                showForm = false
                dismissWindow(id: "onboarding")
            }
        }
    }
}
