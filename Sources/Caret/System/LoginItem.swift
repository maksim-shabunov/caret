import Foundation
import ServiceManagement

/// Launch at login, via the modern registration API.
///
/// `SMAppService` registers the bundle itself, so there is no helper app to keep
/// in step. The user can also turn it off in System Settings without telling us,
/// which is why the current status is always read back rather than remembered.
@MainActor
public enum LoginItem {

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns false if the change did not take. The most common reason is that
    /// the user has the item disabled in System Settings, which overrides us.
    @discardableResult
    public static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return true }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return true }
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
