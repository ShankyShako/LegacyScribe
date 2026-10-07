import ComposableArchitecture
import HexCore

extension SharedReaderKey
	where Self == InMemoryKey<DictationLatency?>.Default
{
	/// Latency breakdown of the most recent dictation, shown in the menu bar menu.
	static var lastDictationLatency: Self {
		Self[.inMemory("lastDictationLatency"), default: nil]
	}
}
