//
//  InvisibleWindow.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AppKit
import Observation
import SwiftUI

/// The screen the invisible window covers and the part of it the menu bar and Dock leave free, in the window's
/// top-left coordinates. The live caption maps its fractional spot into `visibleRect`.
@MainActor @Observable
final class VisibleScreen {
  static let shared = VisibleScreen()

  /// The window's size: the screen's full frame.
  private(set) var size: CGSize = .zero
  /// `screen.frame` minus `screen.visibleFrame`: what the menu bar (top) and Dock (a side) take.
  private(set) var inset = EdgeInsets()

  var visibleRect: CGRect {
    let size = size == .zero ? (NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)) : size
    return CGRect(
      x: inset.leading,
      y: inset.top,
      width: max(1, size.width - inset.leading - inset.trailing),
      height: max(1, size.height - inset.top - inset.bottom)
    )
  }

  func adopt(_ screen: NSScreen) {
    let frame = screen.frame
    let visible = screen.visibleFrame
    adopt(
      size: frame.size,
      inset: EdgeInsets(
        top: max(0, frame.maxY - visible.maxY),
        leading: max(0, visible.minX - frame.minX),
        bottom: max(0, visible.minY - frame.minY),
        trailing: max(0, frame.maxX - visible.maxX)
      )
    )
  }

  func adopt(size newSize: CGSize, inset newInset: EdgeInsets) {
    // Only a real change notifies: this runs on every mouse move (the Dock can resize or hide meanwhile).
    if size != newSize { size = newSize }
    if inset != newInset { inset = newInset }
  }
}

/// This allows us to render SwiftUI views anywhere on the screen, without dealing with the awkward
/// rendering issues that come with normal MacOS windows. Essentially, we create one giant invisible
/// window that covers the entire screen, and render our SwiftUI views into it.
///
/// I'm pretty sure this is what CleanShot X and other apps do to render their floating widgets.
/// But if there's a better way to do this, I'd love to know!
class InvisibleWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// The window `fromView` made for the indicator.
  static weak var shared: InvisibleWindow?

  /// The one part of the window that takes clicks (the Undo pill), in the content view's top-left
  /// coordinates. The window takes the mouse only while the pointer is over it, so the rest of the
  /// screen stays click-through.
  var clickableRect: CGRect? {
    didSet { updateClickThrough() }
  }

  private var currentScreen: NSScreen?
  private var mouseMonitor: Any?
  private var localMouseMonitor: Any?

  init() {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let styleMask: NSWindow.StyleMask = [.fullSizeContentView, .borderless, .utilityWindow, .nonactivatingPanel]

    super.init(contentRect: screen.frame,
               styleMask: styleMask,
               backing: .buffered,
               defer: false)

    level = .statusBar
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false // Prevent hiding when app loses focus
    canHide = false
    collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]

    // Set initial frame
    updateToScreenWithMouse()

    // Start observing screen changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenDidChange),
      name: NSWindow.didChangeScreenNotification,
      object: nil
    )

    // Also observe screen parameters for resolution changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenDidChange),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )

    // Monitor mouse movements to detect screen boundary crossings
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
      self?.checkForScreenChange()
      self?.updateClickThrough()
    }
    // While the window takes the mouse, moves come here instead; leaving the pill makes it click-through again.
    acceptsMouseMovedEvents = true
    localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
      self?.updateClickThrough()
      return event
    }
  }

  private func updateClickThrough() {
    guard let rect = clickableRect, !rect.isEmpty else {
      if !ignoresMouseEvents { ignoresMouseEvents = true }
      return
    }
    // The window covers its screen, so content coordinates are offsets from its top-left corner.
    let onScreen = CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    let over = onScreen.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    if ignoresMouseEvents == over { ignoresMouseEvents = !over }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
    }
    if let monitor = localMouseMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }

  private func updateToScreenWithMouse() {
    let mouseLocation = NSEvent.mouseLocation
    guard let screenWithMouse = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else { return }
    currentScreen = screenWithMouse
    setFrame(screenWithMouse.frame, display: true)
    VisibleScreen.shared.adopt(screenWithMouse)
  }

  private func checkForScreenChange() {
    let mouseLocation = NSEvent.mouseLocation
    guard let newScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else { return }
    
    VisibleScreen.shared.adopt(newScreen)
    // Only update if screen actually changed
    if newScreen !== currentScreen {
      currentScreen = newScreen
      setFrame(newScreen.frame, display: true)
      VisibleScreen.shared.adopt(newScreen)
    }
  }

  @objc private func screenDidChange(_: Notification) {
    updateToScreenWithMouse()
  }
}

extension InvisibleWindow: NSWindowDelegate {
  static func fromView<V: View>(_ view: V) -> InvisibleWindow {
    let window = InvisibleWindow()
    window.contentView = FirstClickHostingView(rootView: view)
    window.delegate = window
    shared = window
    return window
  }
}

/// The Undo button must work on the first click, while another app is active.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
