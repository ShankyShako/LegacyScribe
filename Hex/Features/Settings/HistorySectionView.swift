import ComposableArchitecture
import Inject
import SwiftUI
import HexCore

struct HistorySectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	/// Space used by `Recordings/`, read when the section appears or the retention changes.
	@State private var recordingsSizeText: String?

	var body: some View {
		Section {
			Label {
				Toggle("Save Transcription History", isOn: Binding(
					get: { store.hexSettings.saveTranscriptionHistory },
					set: { store.send(.toggleSaveTranscriptionHistory($0)) }
				))
				Text("Save transcriptions and audio recordings for later access")
					.settingsCaption()
			} icon: {
				Image(systemName: "clock.arrow.circlepath")
			}

			if store.hexSettings.saveTranscriptionHistory {
				Label {
					HStack {
						Text("Maximum History Entries")
						Spacer()
						Picker("", selection: Binding(
							get: { store.hexSettings.maxHistoryEntries ?? 0 },
							set: { newValue in
								store.send(.setMaxHistoryEntries(newValue == 0 ? nil : newValue))
							}
						)) {
							Text("Unlimited").tag(0)
							Text("50").tag(50)
							Text("100").tag(100)
							Text("200").tag(200)
							Text("500").tag(500)
							Text("1000").tag(1000)
						}
						.pickerStyle(.menu)
						.frame(width: 120)
					}
				} icon: {
					Image(systemName: "number.square")
				}

				if store.hexSettings.maxHistoryEntries != nil {
					Text("Oldest entries will be automatically deleted when limit is reached")
						.settingsCaption()
						.padding(.leading, 28)
				}

				Label {
					HStack {
						Text("Keep Recordings")
						Spacer()
						Picker("", selection: Binding(
							get: { store.hexSettings.audioRetentionDays },
							set: { store.send(.setAudioRetentionDays($0)) }
						)) {
							Text("7 days").tag(7)
							Text("14 days").tag(14)
							Text("30 days").tag(30)
							Text("90 days").tag(90)
							Text("1 year").tag(365)
							Text("Forever").tag(0)
						}
						.pickerStyle(.menu)
						.frame(width: 120)
					}
					Text("Older audio is deleted; the text stays in history. Recordings you corrected before sending are kept.\(recordingsSizeText.map { " Recordings use \($0)." } ?? "")")
						.settingsCaption()
						.task(id: store.hexSettings.audioRetentionDays) {
							let bytes = await Task.detached(priority: .utility) { AudioRetentionSweep.recordingsSize() }.value
							recordingsSizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
						}
				} icon: {
					Image(systemName: "waveform")
				}

				PasteLastTranscriptHotkeyRow(store: store)
			}
		} header: {
			Text("History")
		} footer: {
			if !store.hexSettings.saveTranscriptionHistory {
				Text("When disabled, transcriptions will not be saved and audio files will be deleted immediately after transcription.")
					.font(.footnote)
					.foregroundColor(.secondary)
			}
		}
		.enableInjection()
	}
}

private struct PasteLastTranscriptHotkeyRow: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		let pasteHotkey = store.hexSettings.pasteLastTranscriptHotkey

		VStack(alignment: .leading, spacing: 12) {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text("Paste Last Transcript")
						.font(.subheadline.weight(.semibold))
					Text("Assign a shortcut (modifier + key) to instantly paste your last transcription.")
						.settingsCaption()
				}
			} icon: {
				Image(systemName: "doc.on.clipboard")
			}

			let key = store.isSettingPasteLastTranscriptHotkey ? nil : pasteHotkey?.key
			let modifiers = store.isSettingPasteLastTranscriptHotkey ? store.currentPasteLastModifiers : (pasteHotkey?.modifiers ?? .init(modifiers: []))

			HStack {
				Spacer()
				ZStack {
					HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingPasteLastTranscriptHotkey)

					if !store.isSettingPasteLastTranscriptHotkey, pasteHotkey == nil {
						Text("Not set")
							.settingsCaption()
					}
				}
				.contentShape(Rectangle())
				.onTapGesture {
					store.send(.startSettingPasteLastTranscriptHotkey)
				}
				Spacer()
			}

			if store.isSettingPasteLastTranscriptHotkey {
				Text("Use at least one modifier (⌘, ⌥, ⇧, ⌃) plus a key.")
					.settingsCaption()
			} else if pasteHotkey != nil {
				Button {
					store.send(.clearPasteLastTranscriptHotkey)
				} label: {
					Label("Clear shortcut", systemImage: "xmark.circle")
				}
				.buttonStyle(.borderless)
				.font(.caption)
				.foregroundStyle(.secondary)
			}
		}
		.enableInjection()
	}
}
