import ComposableArchitecture
import Inject
import SwiftUI

struct AboutView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>
    @State private var showingChangelog = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Label("Version", systemImage: "info.circle")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                }
                HStack {
                    Label("Changelog", systemImage: "doc.text")
                    Spacer()
                    Button("Show Changelog") {
                        showingChangelog.toggle()
                    }
                    .buttonStyle(.bordered)
                    .sheet(isPresented: $showingChangelog, onDismiss: {
                        showingChangelog = false
                    }) {
                        ChangelogView()
                    }
                }
                HStack {
                    Label("Based on Hex by Kit Langton (MIT)", systemImage: "apple.terminal.on.rectangle")
                    Spacer()
                    Link("View Hex on GitHub", destination: URL(string: "https://github.com/kitlangton/Hex/")!)
                }
            }
        }
        .formStyle(.grouped)
        .enableInjection()
    }
}
