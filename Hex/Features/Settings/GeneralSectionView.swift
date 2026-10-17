import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct GeneralSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Toggle("Open at login",
				       isOn: Binding(
				       	get: { store.hexSettings.openOnLogin },
				       	set: { store.send(.toggleOpenOnLogin($0)) }
				       ))
			} icon: {
				Image(systemName: "arrow.right.circle")
			}
			.labelStyle(.tile(.green))

			Label {
				Toggle(
					"Show Dock icon",
					isOn: Binding(
						get: { store.hexSettings.showDockIcon },
						set: { store.send(.toggleShowDockIcon($0)) }
					)
				)
			} icon: {
				Image(systemName: "dock.rectangle")
			}
			.labelStyle(.tile(.brown))

			Label {
				Toggle(
					"Use clipboard to insert",
					isOn: Binding(
						get: { store.hexSettings.useClipboardPaste },
						set: { store.send(.setUseClipboardPaste($0)) }
					)
				)
				Text("Fast, but some clipboard contents may not come back afterwards. Off, the text is typed as key presses: slower, and the clipboard is untouched.")
					.settingsCaption()
			} icon: {
				Image(systemName: "doc.on.doc.fill")
			}
			.labelStyle(.tile(.cyan))

			Label {
				Toggle(
					"Match surrounding text",
					isOn: Binding(
						get: { store.hexSettings.matchSurroundingText },
						set: { store.send(.setMatchSurroundingText($0)) }
					)
				)
				Text("Dictating into the middle of a sentence starts in lowercase and leaves off the final period, and spaces are added where words meet. Skipped in terminals.")
					.settingsCaption()
			} icon: {
				Image(systemName: "text.cursor")
			}
			.labelStyle(.tile(.purple))

			Label {
				Toggle(
					"Let links start recording",
					isOn: Binding(
						get: { store.hexSettings.urlActionsEnabled },
						set: { store.send(.setURLActionsEnabled($0)) }
					)
				)
				Text("For Shortcuts, Raycast or a Stream Deck: \(URLAction.scheme)://start, toggle and notes/start turn the microphone on. Off, only stop, cancel and mode/clean (raw, prompt, notes) work, since any web page can open such a link.")
					.settingsCaption()
			} icon: {
				Image(systemName: "link")
			}
			.labelStyle(.tile(.blue))

			Label {
				Toggle(
					"Copy to clipboard",
					isOn: Binding(
						get: { store.hexSettings.copyToClipboard },
						set: { store.send(.setCopyToClipboard($0)) }
					)
				)
				Text("Also leaves the text on the clipboard after pasting it.")
					.settingsCaption()
			} icon: {
				Image(systemName: "doc.on.clipboard")
			}
			.labelStyle(.tile(.settingsTileGray))

			Label {
				Toggle(
					"Keep the Mac awake while recording",
					isOn: Binding(
						get: { store.hexSettings.preventSystemSleep },
						set: { store.send(.togglePreventSystemSleep($0)) }
					)
				)
			} icon: {
				Image(systemName: "zzz")
			}
			.labelStyle(.tile(.indigo))

			Label {
				Toggle(
					"Keep the microphone ready",
					isOn: Binding(
						get: { store.hexSettings.superFastModeEnabled },
						set: { store.send(.toggleSuperFastMode($0)) }
					)
				)
				Text("Recording starts about 0.2 s sooner and keeps the half second before you press the key. macOS shows the microphone indicator the whole time this is on.")
					.settingsCaption()
			} icon: {
				Image(systemName: "bolt.circle")
			}
			.labelStyle(.tile(.orange))

			Label {
				HStack {
					Text("Undo a cancelled dictation")
					Spacer()
					Picker("", selection: Binding(
						get: { store.hexSettings.cancelUndoSeconds },
						set: { store.send(.setCancelUndoSeconds($0)) }
					)) {
						Text("Off").tag(0)
						Text("10 s").tag(10)
						Text("30 s").tag(30)
						Text("1 min").tag(60)
						Text("2 min").tag(120)
					}
					.pickerStyle(.menu)
					.frame(width: 120)
				}
				Text("After Esc, an Undo button shows under the indicator for this long. The recording is deleted when it goes.")
					.settingsCaption()
			} icon: {
				Image(systemName: "arrow.uturn.backward")
			}
			.labelStyle(.tile(.red))

			Label {
				HStack(alignment: .center) {
					Text("Other audio while recording")
				Spacer()
					Picker("", selection: Binding(
						get: { store.hexSettings.recordingAudioBehavior },
						set: { store.send(.setRecordingAudioBehavior($0)) }
					)) {
						Label("Pause media", systemImage: "pause")
							.tag(RecordingAudioBehavior.pauseMedia)
						Label("Mute", systemImage: "speaker.slash")
							.tag(RecordingAudioBehavior.mute)
						Label("Leave it playing", systemImage: "hand.raised.slash")
							.tag(RecordingAudioBehavior.doNothing)
					}
					.pickerStyle(.menu)
				}
			} icon: {
				Image(systemName: "speaker.wave.2")
			}
			.labelStyle(.tile(.pink))
		} header: {
			Text("General")
		}
		.enableInjection()
	}
}

extension URLAction {
	/// This build's scheme from Info.plist: `legacyscribe` (Release) or `legacyscribe-debug` (Debug).
	static var scheme: String {
		let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
		return (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "legacyscribe"
	}
}
