import SwiftUI
import UserNotifications

@main
struct DriveAgentApp: App {
    @StateObject private var controller = DriveController()
    // The notification center holds its delegate weakly, so this has to outlive everything.
    private static let notifications = NotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = Self.notifications
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(controller)
                .environment(\.layoutDirection, .rightToLeft)
                .preferredColorScheme(.dark)
        }
    }
}
