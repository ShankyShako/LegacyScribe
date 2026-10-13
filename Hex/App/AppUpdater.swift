import HexCore
import Sparkle
import SwiftUI
import UserNotifications

private let updatesLogger = HexLog.updates

/// Sparkle updater with its own feed (GitHub releases, see `tools/release.sh`).
///
/// A scheduled check that finds an update doesn't pop Sparkle's window over whatever the user is
/// typing in: it posts a notification and adds an "Install Update…" row to the menu bar menu
/// (Sparkle's "gentle reminders"). Clicking either opens Sparkle's window with the release notes.
/// Checks the user starts, and an update found right at launch, still open the window directly.
///
/// Debug builds never start the updater: the feed carries Release builds, and installing one over
/// `LegacyScribe Debug.app` would swap the bundle ID and its TCC grants.
@Observable
@MainActor
final class AppUpdater: NSObject {
  static let shared = AppUpdater()

  /// Version of an update found by a scheduled check that the user hasn't looked at yet.
  private(set) var pendingVersion: String?
  private(set) var canCheckForUpdates = false

  var automaticallyChecksForUpdates: Bool {
    get {
      access(keyPath: \.automaticallyChecksForUpdates)
      return controller.updater.automaticallyChecksForUpdates
    }
    set {
      withMutation(keyPath: \.automaticallyChecksForUpdates) {
        controller.updater.automaticallyChecksForUpdates = newValue
      }
    }
  }

  var automaticallyDownloadsUpdates: Bool {
    get {
      access(keyPath: \.automaticallyDownloadsUpdates)
      return controller.updater.automaticallyDownloadsUpdates
    }
    set {
      withMutation(keyPath: \.automaticallyDownloadsUpdates) {
        controller.updater.automaticallyDownloadsUpdates = newValue
      }
    }
  }

  var lastCheckDate: Date? { controller.updater.lastUpdateCheckDate }

  static let isEnabled: Bool = {
    #if DEBUG
      false
    #else
      true
    #endif
  }()

  nonisolated private static let notificationID = "com.genovamongalo.LegacyScribe.update"

  @ObservationIgnored private var controller: SPUStandardUpdaterController!
  @ObservationIgnored private var observation: NSKeyValueObservation?

  override private init() {
    super.init()
    controller = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: self,
      userDriverDelegate: self
    )
  }

  /// Starts scheduled checks. Call once at launch; it also routes clicks on the update notification here.
  func start() {
    guard Self.isEnabled else {
      updatesLogger.info("Updater not started in a Debug build")
      return
    }
    UNUserNotificationCenter.current().delegate = self
    observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
      let canCheck = updater.canCheckForUpdates
      Task { @MainActor in self?.canCheckForUpdates = canCheck }
    }
    controller.startUpdater()
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }
}

extension AppUpdater: SPUUpdaterDelegate {
  /// No update checks in Private mode, scheduled or asked for; a check the user asks for shows why.
  nonisolated func updater(_: SPUUpdater, mayPerform _: SPUUpdateCheck) throws {
    if NetworkPolicy.isPrivate {
      throw NetworkPolicy.Denied(url: nil)
    }
  }

  nonisolated func updater(_: SPUUpdater, willScheduleUpdateCheckAfterDelay _: TimeInterval) {
    // Ask for notification permission once checks are scheduled, so the first prompt doesn't
    // appear on a fresh install before the user has seen the app.
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
      if let error {
        updatesLogger.error("Notification authorization failed: \(error.localizedDescription)")
      } else {
        updatesLogger.info("Notification authorization granted: \(granted)")
      }
    }
  }

  nonisolated func updater(_: SPUUpdater, didAbortWithError error: any Error) {
    updatesLogger.error("Update check aborted: \(error.localizedDescription)")
  }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
    _: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    // Right after launch the user is looking at the app anyway; any other time, remind gently.
    immediateFocus
  }

  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    guard !handleShowingUpdate, !state.userInitiated else { return }
    let version = update.displayVersionString
    updatesLogger.info("Update \(version, privacy: .public) found by a scheduled check")
    Task { @MainActor in self.pendingVersion = version }

    let content = UNMutableNotificationContent()
    content.title = String(localized: "LegacyScribe \(version) is available")
    content.body = String(localized: "Click to see what changed and install it.")
    let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate _: SUAppcastItem) {
    Task { @MainActor in self.clearReminder() }
  }

  nonisolated func standardUserDriverWillFinishUpdateSession() {
    Task { @MainActor in self.clearReminder() }
  }

  private func clearReminder() {
    pendingVersion = nil
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
  }
}

extension AppUpdater: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.notification.request.identifier == Self.notificationID,
       response.actionIdentifier == UNNotificationDefaultActionIdentifier
    {
      Task { @MainActor in self.checkForUpdates() }
    }
    completionHandler()
  }

  /// Show the banner even while the Settings window is in front.
  nonisolated func userNotificationCenter(
    _: UNUserNotificationCenter,
    willPresent _: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}

/// "Check for Updates…" in the menu bar menu, or "Install Update x.y…" once a scheduled check found one.
struct MenuBarUpdateButton: View {
  @State private var updater = AppUpdater.shared

  var body: some View {
    if let version = updater.pendingVersion {
      Button("Install Update \(version)…", action: updater.checkForUpdates)
    } else {
      Button("Check for Updates…", action: updater.checkForUpdates)
        .disabled(!updater.canCheckForUpdates)
    }
  }
}
