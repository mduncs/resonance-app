import Foundation
import UserNotifications

enum NotificationError: Error, Sendable {
    case notAuthorized
    case denied
    case requestFailed(Error)
    case postFailed(Error)
}

typealias NotificationResult<T> = Result<T, NotificationError>

@MainActor
final class NotificationService: ObservableObject {
    private lazy var center = UNUserNotificationCenter.current()
    private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private var showNotifications: Bool {
        UserDefaults.standard.bool(forKey: "showNotifications")
    }

    private var showLyricsInNotifications: Bool {
        UserDefaults.standard.bool(forKey: "showLyricsInNotifications")
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async -> NotificationResult<Bool> {
        // Check current status first
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus

        switch authorizationStatus {
        case .authorized, .provisional:
            return .success(true)
        case .denied:
            return .failure(.denied)
        case .notDetermined:
            return await requestAuthorization()
        @unknown default:
            return await requestAuthorization()
        }
    }

    private func requestAuthorization() async -> NotificationResult<Bool> {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            authorizationStatus = granted ? .authorized : .denied
            return .success(granted)
        } catch {
            return .failure(.requestFailed(error))
        }
    }

    // MARK: - Post Notification

    func postTrackChange(song: Song, firstLyricsLine: String? = nil) async -> NotificationResult<Void> {
        guard showNotifications else {
            return .success(())
        }

        // Ensure we have authorization
        let authResult = await requestAuthorizationIfNeeded()
        switch authResult {
        case .failure(let error):
            return .failure(error)
        case .success(let granted):
            if !granted {
                return .failure(.notAuthorized)
            }
        }

        let content = UNMutableNotificationContent()
        content.title = song.title
        content.subtitle = song.artist

        // Body: lyrics line if enabled and available, otherwise album name
        if showLyricsInNotifications, let lyrics = firstLyricsLine, !lyrics.isEmpty {
            content.body = lyrics
        } else {
            content.body = song.album
        }

        // Use song ID for deduplication - newer notification replaces older
        let identifier = "track-change-\(song.id)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Immediate delivery
        )

        do {
            try await center.add(request)
            return .success(())
        } catch {
            return .failure(.postFailed(error))
        }
    }

    // MARK: - Cleanup

    func removeAllPendingNotifications() {
        center.removeAllPendingNotificationRequests()
    }

    func removeAllDeliveredNotifications() {
        center.removeAllDeliveredNotifications()
    }
}
