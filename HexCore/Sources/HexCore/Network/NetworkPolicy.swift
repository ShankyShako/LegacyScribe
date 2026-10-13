import Foundation
import os

/// The one switch every network request in the process answers to. In Private mode nothing leaves the Mac,
/// not even a request to localhost (Ollama, a custom server): speech-to-text and the on-device model run
/// in-process and open no socket.
///
/// Two layers enforce it. Features check `isPrivate` first and skip anything that would need the network
/// (cloud rewrite endpoints, update checks). Underneath, `install()` puts `NetworkPolicyURLProtocol` in front of
/// every URLSession in the process, including the ones packages create, and it fails any request made while
/// Private mode is on.
public enum NetworkPolicy {
	private struct State {
		var isPrivate = false
		var blockedRequests = 0
	}

	private static let state = OSAllocatedUnfairLock(initialState: State())

	public static var isPrivate: Bool {
		state.withLock(\.isPrivate)
	}

	public static func setPrivate(_ isPrivate: Bool) {
		let changed = state.withLock { state in
			defer { state.isPrivate = isPrivate }
			return state.isPrivate != isPrivate
		}
		if changed {
			HexLog.network.notice("Private mode \(isPrivate ? "on: network requests are refused" : "off", privacy: .public)")
		}
	}

	/// Requests refused since launch.
	public static var blockedRequests: Int {
		state.withLock(\.blockedRequests)
	}

	/// Whether a request for `url` may go out now. Local files never touch the network.
	public static func allows(_ url: URL?) -> Bool {
		guard isPrivate else { return true }
		return isLocal(url)
	}

	static func isLocal(_ url: URL?) -> Bool {
		guard let scheme = url?.scheme?.lowercased() else { return false }
		return scheme == "file" || scheme == "data"
	}

	static func noteBlocked(_ url: URL?) {
		state.withLock { $0.blockedRequests += 1 }
		HexLog.network.notice("Private mode refused a request to \(url?.host() ?? "?", privacy: .private)")
	}

	/// Whether a rewrite endpoint may run: in Private mode only the in-process model.
	public static func allows(_ endpoint: RewriteEndpoint, privateMode: Bool) -> Bool {
		!privateMode || endpoint.provider == .onDevice
	}

	/// The error a refused request fails with; its message reaches whatever asked (a download, a check).
	/// URLSession re-creates the error from its domain, code and user info, so the message lives there.
	public struct Denied: LocalizedError, CustomNSError, Equatable {
		public static let errorDomain = "com.genovamongalo.LegacyScribe.NetworkPolicy"
		static let message = "Private mode is on, so LegacyScribe doesn't use the network. Turn it off to connect."

		public var url: URL?

		public init(url: URL?) {
			self.url = url
		}

		public var errorCode: Int { 1 }
		public var errorDescription: String? { Self.message }
		public var errorUserInfo: [String: Any] {
			var info: [String: Any] = [NSLocalizedDescriptionKey: Self.message]
			if let url { info[NSURLErrorFailingURLErrorKey] = url }
			return info
		}

		/// Whether `error` (as URLSession or a package hands it back) is a Private-mode refusal.
		public static func matches(_ error: Error) -> Bool {
			var current: NSError? = error as NSError
			while let error = current {
				if error.domain == errorDomain { return true }
				current = error.userInfo[NSUnderlyingErrorKey] as? NSError
			}
			return false
		}
	}

	/// Puts the refusing protocol in front of `URLSession.shared` and of every session built from a
	/// `.default` or `.ephemeral` configuration from now on. Call first thing at launch; safe to call again.
	public static func install() {
		_ = installOnce
	}

	private static let installOnce: Void = {
		URLProtocol.registerClass(NetworkPolicyURLProtocol.self)
		URLSessionConfiguration.swizzleForNetworkPolicy()
	}()
}

/// Claims every non-local request while Private mode is on, only to fail it. Outside Private mode it claims
/// nothing, so requests go through the system's own handlers untouched.
public final class NetworkPolicyURLProtocol: URLProtocol {
	override public class func canInit(with request: URLRequest) -> Bool {
		!NetworkPolicy.allows(request.url)
	}

	override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override public func startLoading() {
		NetworkPolicy.noteBlocked(request.url)
		client?.urlProtocol(self, didFailWithError: NetworkPolicy.Denied(url: request.url))
	}

	override public func stopLoading() {}
}

extension URLSessionConfiguration {
	/// Swaps the `.default` and `.ephemeral` class getters for versions that add `NetworkPolicyURLProtocol`.
	/// Packages (WhisperKit, FluidAudio, Hugging Face downloads, Sparkle) build their own sessions, and a
	/// registered protocol class only reaches `URLSession.shared`.
	fileprivate static func swizzleForNetworkPolicy() {
		let pairs: [(Selector, Selector)] = [
			(#selector(getter: URLSessionConfiguration.default), #selector(URLSessionConfiguration.networkPolicyDefault)),
			(#selector(getter: URLSessionConfiguration.ephemeral), #selector(URLSessionConfiguration.networkPolicyEphemeral)),
		]
		for (original, replacement) in pairs {
			guard let originalMethod = class_getClassMethod(URLSessionConfiguration.self, original),
			      let replacementMethod = class_getClassMethod(URLSessionConfiguration.self, replacement)
			else {
				HexLog.network.error("Couldn't hook URLSessionConfiguration.\(NSStringFromSelector(original), privacy: .public)")
				continue
			}
			method_exchangeImplementations(originalMethod, replacementMethod)
		}
	}

	// After the exchange, calling these names runs the original getters.
	@objc private dynamic class func networkPolicyDefault() -> URLSessionConfiguration {
		networkPolicyDefault().withNetworkPolicy()
	}

	@objc private dynamic class func networkPolicyEphemeral() -> URLSessionConfiguration {
		networkPolicyEphemeral().withNetworkPolicy()
	}

	private func withNetworkPolicy() -> URLSessionConfiguration {
		let existing = protocolClasses ?? []
		if !existing.contains(where: { $0 == NetworkPolicyURLProtocol.self }) {
			protocolClasses = [NetworkPolicyURLProtocol.self] + existing
		}
		return self
	}
}
