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
        Text(mode.displayName).tag(mode)
      }
    }
    .pickerStyle(.inline)
  }
}
