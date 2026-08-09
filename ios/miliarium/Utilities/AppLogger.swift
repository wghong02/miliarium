import OSLog

/// Centralised `Logger` instances — one per backend layer.
///
/// Usage:
/// ```swift
/// AppLogger.activity.error("deleteActivity failed: \(error)")
/// AppLogger.progressStore.debug("createProgress succeeded id=\(id)")
/// ```
///
/// Logs are visible in Xcode's console and in Console.app
/// (filter by subsystem `miliarium.miliarium`).
enum AppLogger {
    // Computed vars avoid the @MainActor-isolation inference that the compiler
    // applies to static stored properties whose type isn't Sendable. Logger is
    // a trivial two-string struct so the per-call creation cost is negligible.
    private static var subsystem: String { "miliarium.miliarium" }

    static var activity:           Logger { Logger(subsystem: subsystem, category: "ActivityService") }
    static var activityCollection: Logger { Logger(subsystem: subsystem, category: "ActivityCollectionService") }
    static var invitation:         Logger { Logger(subsystem: subsystem, category: "InvitationService") }
    static var user:               Logger { Logger(subsystem: subsystem, category: "UserService") }
    static var auth:               Logger { Logger(subsystem: subsystem, category: "AuthViewModel") }
    static var invitationVM:       Logger { Logger(subsystem: subsystem, category: "InvitationViewModel") }
    static var progressStore:      Logger { Logger(subsystem: subsystem, category: "ProgressStore") }
    static var notification:       Logger { Logger(subsystem: subsystem, category: "NotificationService") }
    static var media:              Logger { Logger(subsystem: subsystem, category: "MediaService") }
}
