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
				Toggle(
					"Private Mode",
					isOn: Binding(
						get: { store.hexSettings.privateMode },
						set: { store.send(.setPrivateMode($0)) }
					)
				)
				Text("Nothing leaves this Mac: only the on-device model rewrites (other AIs are skipped and the text is pasted as heard), and there are no downloads, update checks or connection checks. Also in the menu bar menu.")
					.settingsCaption()
			} icon: {
				Image(systemName: "lock.fill")
			}

			Label {
				Toggle("Open on Login",
				       isOn: Binding(
				       	get: { store.hexSettings.openOnLogin },
				       	set: { store.send(.toggleOpenOnLogin($0)) }
				       ))
			} icon: {
				Image(systemName: "arrow.right.circle")
			}

			Label {
				Toggle(
					"Show Dock Icon",
					isOn: Binding(
						get: { store.hexSettings.showDockIcon },
						set: { store.send(.toggleShowDockIcon($0)) }
					)
				)
			} icon: {
				Image(systemName: "dock.rectangle")
			}

			Label {
				Toggle(
					"Use clipboard to insert",
					isOn: Binding(
						get: { store.hexSettings.useClipboardPaste },
						set: { store.send(.setUseClipboardPaste($0)) }
					)
				)
				Text("Use clipboard to insert text. Fast but may not restore all clipboard content.\nTurn off to use simulated keypresses. Slower, but doesn't need to restore clipboard")
			} icon: {
				Image(systemName: "doc.on.doc.fill")
			}

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

			Label {
				Toggle(
					"Copy to clipboard",
					isOn: Binding(
						get: { store.hexSettings.copyToClipboard },
						set: { store.send(.setCopyToClipboard($0)) }
					)
				)
				Text("Copy transcription text to clipboard in addition to pasting it")
			} icon: {
				Image(systemName: "doc.on.clipboard")
			}

			Label {
				Toggle(
					"Prevent System Sleep while Recording",
					isOn: Binding(
						get: { store.hexSettings.preventSystemSleep },
						set: { store.send(.togglePreventSystemSleep($0)) }
					)
				)
			} icon: {
				Image(systemName: "zzz")
			}

			Label {
				Toggle(
					"Super Fast Mode",
					isOn: Binding(
						get: { store.hexSettings.superFastModeEnabled },
						set: { store.send(.toggleSuperFastMode($0)) }
					)
				)
				Text("Keep the microphone warm and prepend a short in-memory buffer for near-instant capture. macOS will keep showing the microphone indicator while this mode is armed.")
			} icon: {
				Image(systemName: "bolt.circle")
			}

			Label {
				HStack(alignment: .center) {
					Text("Audio Behavior while Recording")
				Spacer()
					Picker("", selection: Binding(
						get: { store.hexSettings.recordingAudioBehavior },
						set: { store.send(.setRecordingAudioBehavior($0)) }
					)) {
						Label("Pause Media", systemImage: "pause")
							.tag(RecordingAudioBehavior.pauseMedia)
						Label("Mute Volume", systemImage: "speaker.slash")
							.tag(RecordingAudioBehavior.mute)
						Label("Do Nothing", systemImage: "hand.raised.slash")
							.tag(RecordingAudioBehavior.doNothing)
					}
					.pickerStyle(.menu)
				}
			} icon: {
				Image(systemName: "speaker.wave.2")
			}
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
