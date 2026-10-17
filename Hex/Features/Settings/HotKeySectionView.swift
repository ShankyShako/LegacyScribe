import ComposableArchitecture
import HexCore
import Inject
import Sauce
import SwiftUI

struct HotKeySectionView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Section("Shortcut") {
            let hotKey = store.hexSettings.hotkey
            let key = store.isSettingHotKey ? nil : hotKey.key
            let modifiers = store.isSettingHotKey ? store.currentModifiers : hotKey.modifiers

            Label {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Push to talk")
                        Text("Hold to speak. Click the key to change it.")
                            .settingsCaption()
                    }
                    Spacer(minLength: 12)
                    HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingHotKey)
                        .animation(.spring(), value: key)
                        .animation(.spring(), value: modifiers)
                        .fixedSize()
                        .scaleEffect(Self.scale(modifiers: modifiers, key: key))
                        .frame(
                            width: Self.keysWidth(modifiers: modifiers, key: key, isSetting: store.isSettingHotKey)
                                * Self.scale(modifiers: modifiers, key: key),
                            height: 64 * Self.scale(modifiers: modifiers, key: key)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.send(.startSettingHotKey)
                        }
                        .help("Click, then press the keys you want")
                }
            } icon: {
                Image(systemName: "keyboard")
            }
            .labelStyle(.tile(.settingsTileGray))

            if !store.isSettingHotKey,
               hotKey.key == nil,
               !hotKey.modifiers.isEmpty {
                ModifierSideControls(
                    modifiers: hotKey.modifiers,
                    onSelect: { kind, side in
                        store.send(.setModifierSide(kind, side))
                    }
                )
                .padding(.leading, 34)
                .transition(.opacity)
            }

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(
                        "Double-tap to lock",
                        isOn: Binding(
                            get: { store.hexSettings.doubleTapLockEnabled },
                            set: { store.send(.setDoubleTapLockEnabled($0)) }
                        )
                    )
                    Text("Tap twice to keep recording hands-free.")
                        .settingsCaption()
                }
            } icon: {
                Image(systemName: "hand.tap")
            }
            .labelStyle(.tile(.orange))

            // Double-tap only mode applies to key+modifier combinations.
            if hotKey.key != nil {
                Label {
                    Toggle(
                        "Use double-tap only",
                        isOn: Binding(
                            get: { store.hexSettings.useDoubleTapOnly },
                            set: { store.send(.setUseDoubleTapOnly($0)) }
                        )
                    )
                        .disabled(!store.hexSettings.doubleTapLockEnabled)
                } icon: {
                    Image(systemName: "hand.tap.fill")
                }
                .labelStyle(.tile(.orange))
            }

            // Minimum key time (for modifier-only shortcuts)
            if store.hexSettings.hotkey.key == nil {
                Label {
                    HStack(spacing: 10) {
                        Text("Ignore quick taps")
                        Spacer(minLength: 12)
                        Slider(
                            value: Binding(
                                get: { store.hexSettings.minimumKeyTime },
                                set: { store.send(.setMinimumKeyTime($0)) }
                            ),
                            in: 0.0 ... 2.0,
                            step: 0.1
                        ) {
                            Text("Ignore taps shorter than \(store.hexSettings.minimumKeyTime, specifier: "%.1f") seconds")
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Text("\(store.hexSettings.minimumKeyTime, specifier: "%.1f") s")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                } icon: {
                    Image(systemName: "clock")
                }
                .labelStyle(.tile(.green))
            }
        }
        .enableInjection()
    }

    private static let keyScale: CGFloat = 0.7

    /// The key cap is shrunk to sit in a row; while waiting for keys it keeps its full size so the prompt reads.
    private static func scale(modifiers: Modifiers, key: Key?) -> CGFloat {
        modifiers.isEmpty && key == nil ? 1 : keyScale
    }

    /// Width of `HotKeyView` at full size: 48 pt keys, 6 pt apart, 8 pt padding on each side.
    private static func keysWidth(modifiers: Modifiers, key: Key?, isSetting: Bool) -> CGFloat {
        var count = modifiers.isHyperkey ? 1 : modifiers.sorted.count
        if key != nil { count += 1 }
        if count == 0 { return isSetting ? 190 : 64 }
        return CGFloat(count) * 48 + CGFloat(count - 1) * 6 + 16
    }
}

private struct ModifierSideControls: View {
    @ObserveInjection var inject
    var modifiers: Modifiers
    var onSelect: (Modifier.Kind, Modifier.Side) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(modifiers.kinds, id: \.self) { kind in
                if kind.supportsSideSelection {
                    let binding = Binding<Modifier.Side>(
                        get: { modifiers.side(for: kind) ?? .either },
                        set: { onSelect(kind, $0) }
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("\(kind.displayName) key side", selection: binding) {
                            ForEach(Modifier.Side.allCases, id: \.self) { side in
                                Text(side.displayName)
                                    .tag(side)
                                    .disabled(!kind.supportsSideSelection && side != .either)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
        .enableInjection()
    }
}
