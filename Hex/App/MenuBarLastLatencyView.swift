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
