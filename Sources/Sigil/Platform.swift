import AppKit
import ServiceManagement
import UserNotifications

/// Things that only work inside a real .app bundle (notifications, login item, updates). When run with
/// `swift run` there is no bundle identifier and these quietly turn themselves off instead of crashing.
enum Platform {
    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "geliştirme"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

@MainActor
enum Notifier {
    static func requestPermission() async -> Bool {
        guard Platform.isBundled else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func authorized() async -> Bool {
        guard Platform.isBundled else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    static func post(_ title: String, _ body: String) {
        guard Platform.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// "Open at login" through SMAppService (macOS 13+). The user can also revoke it in System Settings.
enum LoginItem {
    static var isEnabled: Bool { Platform.isBundled && SMAppService.mainApp.status == .enabled }

    static var needsApproval: Bool { Platform.isBundled && SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        guard Platform.isBundled else { return }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Opens apps/links the setup screen points people to.
enum Links {
    static func open1Password() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(string: "https://1password.com/downloads/mac")!)
        }
    }

    static func openURL(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
