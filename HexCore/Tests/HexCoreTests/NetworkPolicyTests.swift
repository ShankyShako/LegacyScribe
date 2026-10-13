import Foundation
@testable import HexCore
import Testing

/// Toggles the process-wide switch, so the cases run one at a time.
@Suite(.serialized)
struct NetworkPolicyTests {
	init() {
		NetworkPolicy.install()
	}

	/// Port 9 (discard) on localhost: with Private off nothing listens, so a request there fails fast
	/// with a connection error rather than `Denied`.
	let url = URL(string: "http://127.0.0.1:9/v1/models")!

	func deniedError(_ session: URLSession) async -> Error? {
		do {
			_ = try await session.data(from: url)
			return nil
		} catch {
			return error
		}
	}

	@Test
	func privateModeRefusesEverySessionKind() async {
		NetworkPolicy.setPrivate(true)
		defer { NetworkPolicy.setPrivate(false) }
		let before = NetworkPolicy.blockedRequests

		let custom = URLSessionConfiguration.ephemeral
		custom.timeoutIntervalForRequest = 2
		for session in [URLSession.shared, URLSession(configuration: .default), URLSession(configuration: custom)] {
			let error = await deniedError(session)
			#expect(error.map(NetworkPolicy.Denied.matches) == true)
			#expect(error?.localizedDescription.hasPrefix("Private mode is on") == true)
		}
		#expect(NetworkPolicy.blockedRequests == before + 3)
	}

	@Test
	func outsidePrivateModeNothingIsClaimed() {
		NetworkPolicy.setPrivate(false)
		#expect(!NetworkPolicyURLProtocol.canInit(with: URLRequest(url: url)))
		#expect(URLSessionConfiguration.default.protocolClasses?.first == NetworkPolicyURLProtocol.self)
	}

	@Test
	func localFilesStayReadable() {
		NetworkPolicy.setPrivate(true)
		defer { NetworkPolicy.setPrivate(false) }
		#expect(NetworkPolicy.allows(URL(fileURLWithPath: "/tmp/a.wav")))
		#expect(!NetworkPolicy.allows(URL(string: "https://huggingface.co")))
		#expect(!NetworkPolicy.allows(URL(string: "http://localhost:11434/api/chat")))
	}

	@Test
	func onlyTheOnDeviceModelRewritesInPrivateMode() {
		#expect(NetworkPolicy.allows(.preset(.onDevice), privateMode: true))
		#expect(!NetworkPolicy.allows(.preset(.ollama), privateMode: true))
		#expect(!NetworkPolicy.allows(.preset(.groq), privateMode: true))
		#expect(NetworkPolicy.allows(.preset(.groq), privateMode: false))
	}
}
