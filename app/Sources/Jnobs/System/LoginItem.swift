import Foundation
import ServiceManagement
import os

/// Register / unregister the app as a login item via SMAppService (macOS 13+).
enum LoginItem {
    private static let log = Logger(subsystem: "net.jfound.jnobs", category: "LoginItem")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                    log.info("registered as login item")
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    log.info("unregistered login item")
                }
            }
        } catch {
            log.error("login item toggle failed: \(String(describing: error), privacy: .public)")
        }
    }
}
