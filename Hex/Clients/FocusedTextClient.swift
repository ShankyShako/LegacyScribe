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
	/// The insertion point (start of the selection) as a UTF-16 offset into `value`, when the app reports it.
	var cursor: Int?
	/// The selection's length in UTF-16 units; 0 when nothing is selected.
	var selectionLength: Int = 0

	/// The text before the cursor and after the selection (which a paste replaces); nil without a cursor.
	var surroundings: (before: String, after: String)? {
		guard let cursor else { return nil }
		let utf16 = value.utf16
		guard cursor >= 0, cursor + selectionLength <= utf16.count,
		      let start = utf16.index(utf16.startIndex, offsetBy: cursor, limitedBy: utf16.endIndex)
		        .flatMap({ $0.samePosition(in: value) }),
		      let end = utf16.index(utf16.startIndex, offsetBy: cursor + max(selectionLength, 0), limitedBy: utf16.endIndex)
		        .flatMap({ $0.samePosition(in: value) })
		else { return nil }
		return (String(value[..<start]), String(value[end...]))
	}

	/// The selected text; nil when nothing is selected or the range doesn't fit `value`.
	var selectedText: String? {
		guard let cursor, selectionLength > 0, cursor >= 0 else { return nil }
		let utf16 = value.utf16
		guard let start = utf16.index(utf16.startIndex, offsetBy: cursor, limitedBy: utf16.endIndex),
		      let end = utf16.index(start, offsetBy: selectionLength, limitedBy: utf16.endIndex),
		      let from = start.samePosition(in: value), let to = end.samePosition(in: value)
		else { return nil }
		return String(value[from ..< to])
	}
}

/// Reads the focused text field through Accessibility, for Prompt-mode merges and for capturing what a
/// dictation became when Enter is pressed. Returns nil for secure fields, while Secure Input is on,
/// without the Accessibility grant, and for elements that aren't editable text.
@DependencyClient
struct FocusedTextClient {
	var read: @Sendable () -> FocusedText? = { nil }
	/// The app in front now (Undo pastes only into the app a dictation was for).
	var frontmostBundleID: @Sendable () -> String? = { nil }
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
			guard let rangeRef = attribute(focused, kAXSelectedTextRangeAttribute),
			      let value = attribute(focused, kAXValueAttribute) as? String,
			      value.count <= maxCharacters
			else { return nil }
			var range = CFRange()
			let hasRange = CFGetTypeID(rangeRef) == AXValueGetTypeID() && AXValueGetValue(rangeRef as! AXValue, .cfRange, &range)
			return FocusedText(
				bundleID: app.bundleIdentifier,
				value: value,
				cursor: hasRange ? range.location : nil,
				selectionLength: hasRange ? range.length : 0
			)
		}, frontmostBundleID: {
			NSWorkspace.shared.frontmostApplication?.bundleIdentifier
		})
	}

	static var testValue: Self { Self(read: { nil }, frontmostBundleID: { nil }) }
}

extension DependencyValues {
	var focusedText: FocusedTextClient {
		get { self[FocusedTextClient.self] }
		set { self[FocusedTextClient.self] = newValue }
	}
}
