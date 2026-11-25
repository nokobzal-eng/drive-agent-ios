import UIKit
import UserNotifications

/// Opens another app. iOS only allows that from the foreground, so in the background this posts
/// a notification that opens the same link when tapped.
@MainActor
enum Opener {
    enum Outcome {
        case opened
        case notified
        case failed
    }

    nonisolated static let urlKey = "url"

    static func open(_ url: URL, title: String, body: String) async -> Outcome {
        if UIApplication.shared.applicationState == .active {
            return await UIApplication.shared.open(url) ? .opened : .failed
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [urlKey: url.absoluteString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return .notified
        } catch {
            return .failed
        }
    }

    /// Israeli local numbers (05x…) become international (9725x…); other formats are kept.
    static func internationalNumber(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter(\.isNumber)
        if digits.isEmpty { return nil }
        if trimmed.hasPrefix("+") { return digits }
        if digits.hasPrefix("00") { return String(digits.dropFirst(2)) }
        if digits.hasPrefix("0") { return "972" + String(digits.dropFirst()) }
        return digits
    }

    static func whatsAppURL(number: String, text: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "whatsapp"
        parts.host = "send"
        parts.queryItems = [URLQueryItem(name: "phone", value: number), URLQueryItem(name: "text", value: text)]
        // URLComponents leaves "+" alone, and WhatsApp would read it as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let link = info[Opener.urlKey] as? String
        Task { @MainActor in
            if let link, let url = URL(string: link) { await UIApplication.shared.open(url) }
            completionHandler()
        }
    }
}
