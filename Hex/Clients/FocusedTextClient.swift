import AppKit
import Carbon.HIToolbox
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import os

/// The text of the focused editable field in the frontmost app.
struct FocusedText: Equatable, Sendable {
	var bundleID: String?
	var value: String
}

/// Reads the focused text field through Accessibility, for Prompt-mode merges and for capturing what a
/// dictation became when Enter is pressed. Returns nil for secure fields, while Secure Input is on,
/// without the Accessibility grant, and for elements that aren't editable text.
@DependencyClient
struct FocusedTextClient {
	var read: @Sendable () -> FocusedText? = { nil }
}

extension FocusedTextClient: DependencyKey {
	/// Each read is capped so a hung app can't stall the event tap that calls it on Enter.
	static let messagingTimeout: Float = 0.25
	static let maxCharacters = 200_000

	static var liveValue: Self {
		let electronEnabled = OSAllocatedUnfairLock<Set<pid_t>>(initialState: [])

		func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
			var value: CFTypeRef?
			guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
			return value
		}

		return Self(read: {
			guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
			      let app = NSWorkspace.shared.frontmostApplication
			else { return nil }
			let pid = app.processIdentifier
			let appElement = AXUIElementCreateApplication(pid)
			AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
			// Electron apps (T3 Code, VS Code, Slack…) only build their accessibility tree when asked.
			if electronEnabled.withLock({ $0.insert(pid).inserted }) {
				AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
			}
			guard let focusedRef = attribute(appElement, kAXFocusedUIElementAttribute),
			      CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
			else { return nil }
			let focused = focusedRef as! AXUIElement
			AXUIElementSetMessagingTimeout(focused, messagingTimeout)
			if attribute(focused, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return nil }
			// Editable text has a selection range; buttons and static text don't.
			guard attribute(focused, kAXSelectedTextRangeAttribute) != nil,
			      let value = attribute(focused, kAXValueAttribute) as? String,
			      value.count <= maxCharacters
			else { return nil }
			return FocusedText(bundleID: app.bundleIdentifier, value: value)
		})
	}

	static var testValue: Self { Self(read: { nil }) }
}

extension DependencyValues {
	var focusedText: FocusedTextClient {
		get { self[FocusedTextClient.self] }
		set { self[FocusedTextClient.self] = newValue }
	}
}
