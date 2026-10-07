import ComposableArchitecture
import HexCore
import SwiftUI

/// Disabled menu row showing how long the last dictation took from hotkey release to paste.
struct MenuBarLastLatencyView: View {
  @Shared(.lastDictationLatency) var lastDictationLatency: DictationLatency?

  var body: some View {
    if let latency = lastDictationLatency {
      Text("Last: \(latency.summary)")
    }
  }
}

/// Rewrite mode as a checkmarked list in the menu bar menu.
struct MenuBarRewriteModePicker: View {
  @Shared(.hexSettings) var hexSettings: HexSettings

  var body: some View {
    Picker("Rewrite", selection: Binding(
      get: { hexSettings.rewriteMode },
      set: { mode in $hexSettings.withLock { $0.rewriteMode = mode } }
    )) {
      ForEach(RewriteMode.allCases, id: \.self) { mode in
        Text("\(mode.displayName)   \(mode.shortcutDescription)").tag(mode)
      }
    }
    .pickerStyle(.inline)
  }
}

/// Helix icon, plus a letter when the rewrite mode isn't the default (R = Raw, P = Prompt).
struct MenuBarIconLabel: View {
  @Shared(.hexSettings) var hexSettings: HexSettings

  var body: some View {
    HStack(spacing: 2) {
      if let image = NSImage(named: "HexIcon").map({
        let ratio = $0.size.height / $0.size.width
        $0.size.height = 18
        $0.size.width = 18 / ratio
        return $0
      }) {
        Image(nsImage: image)
      } else {
        Image(systemName: "waveform")
      }
      if let badge = hexSettings.rewriteMode.menuBarBadge {
        Text(badge)
      }
    }
  }
}
