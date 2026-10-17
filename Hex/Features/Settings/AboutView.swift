import AppKit
import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct AboutView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>
    @State private var updater = AppUpdater.shared
    @State private var showingChangelog = false
    @State private var copiedDiagnostics = false
    @Environment(\.openURL) private var openURL

    private static let privacyURL = URL(string: "https://github.com/ShankyShako/LegacyScribe/blob/main/PRIVACY.md")!

    var body: some View {
        Form {
            Section {
                feedbackRow(
                    symbol: "exclamationmark.bubble.fill", color: .red,
                    title: "Report a problem",
                    caption: "Opens a GitHub issue with your version, macOS, Mac model and speech engine filled in.",
                    button: "Report…"
                ) {
                    openURL(FeedbackReport.issueURL(kind: .problem, diagnostics: diagnostics))
                }
                feedbackRow(
                    symbol: "lightbulb.fill", color: .orange,
                    title: "Suggest a feature",
                    caption: nil,
                    button: "Suggest…"
                ) {
                    openURL(FeedbackReport.issueURL(kind: .idea, diagnostics: diagnostics))
                }
                feedbackRow(
                    symbol: "doc.on.clipboard.fill", color: .settingsTileGray,
                    title: "Copy diagnostic info",
                    caption: "The same details, to paste anywhere.",
                    button: copiedDiagnostics ? "Copied" : "Copy"
                ) {
                    copyDiagnostics()
                }
            } header: {
                // The hero is the first section's header, not a row, so it sits on the page with no card behind it.
                VStack(alignment: .leading, spacing: 0) {
                    hero
                        .textCase(nil)
                        .foregroundStyle(.primary)
                    Text("Feedback")
                }
            } footer: {
                HStack(spacing: 4) {
                    Text("Nothing you dictate is ever included.")
                        .foregroundStyle(.secondary)
                    Link("Privacy", destination: Self.privacyURL)
                }
                .font(.footnote)
            }

            Section {
                if AppUpdater.isEnabled {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Check for updates daily")
                            if let lastCheck = updater.lastCheckDate {
                                Text("Last checked \(lastCheck, format: .relative(presentation: .named)).")
                                    .settingsCaption()
                            }
                        }
                        Spacer(minLength: 12)
                        Button("Check Now") {
                            updater.checkForUpdates()
                        }
                        .disabled(!updater.canCheckForUpdates)
                        Toggle("Check for updates daily", isOn: $updater.automaticallyChecksForUpdates)
                            .labelsHidden()
                    }
                    Toggle("Download and install updates without asking", isOn: $updater.automaticallyDownloadsUpdates)
                        .disabled(!updater.automaticallyChecksForUpdates)
                } else {
                    HStack {
                        Text("Debug builds don't update themselves.")
                            .settingsCaption()
                        Spacer(minLength: 12)
                        Button("Check Now") {
                            updater.checkForUpdates()
                        }
                        .disabled(!updater.canCheckForUpdates)
                    }
                }
                HStack {
                    Text("Changelog")
                    Spacer()
                    Button("Show Changelog") {
                        showingChangelog.toggle()
                    }
                    .sheet(isPresented: $showingChangelog, onDismiss: {
                        showingChangelog = false
                    }) {
                        ChangelogView()
                    }
                }
            } header: {
                Text("Updates")
            }

            Section {
                Label {
                    HStack {
                        Text("Based on Hex by Kit Langton (MIT)")
                        Spacer()
                        Link("View Hex on GitHub", destination: URL(string: "https://github.com/kitlangton/Hex/")!)
                    }
                } icon: {
                    Image(systemName: "apple.terminal.on.rectangle")
                }
                .labelStyle(.tile(.indigo))
            }
        }
        .formStyle(.grouped)
        .enableInjection()
    }

    private var hero: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("LegacyScribe")
                .font(.system(size: 21, weight: .semibold))
            Text("Version \(Self.appVersion) (\(Self.build))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Dictation that stays on your Mac")
                .font(.system(size: 13))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private func feedbackRow(
        symbol: String, color: Color, title: String, caption: String?, button: String,
        action: @escaping () -> Void
    ) -> some View {
        Label {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let caption {
                        Text(caption).settingsCaption()
                    }
                }
                Spacer(minLength: 12)
                Button(button, action: action)
            }
        } icon: {
            Image(systemName: symbol)
        }
        .labelStyle(.tile(color))
    }

    // MARK: Diagnostics

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Versions, hardware and the speech engine's name only: never a transcript, History entry or field text.
    private var diagnostics: String {
        FeedbackReport.diagnostics(
            appVersion: Self.appVersion,
            build: Self.build,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            macModel: Self.macModel,
            memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
            engine: store.hexSettings.selectedModel
        )
    }

    private static var macModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Unknown" }
        return String(cString: buffer)
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
        copiedDiagnostics = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedDiagnostics = false
        }
    }
}
