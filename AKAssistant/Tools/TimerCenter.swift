import Foundation
import Observation
import UserNotifications

/// A running timer or reminder set by voice.
struct ActiveTimer: Identifiable, Equatable {
    let id = UUID()
    /// "Timer" for timers, otherwise the reminder text ("Call mom").
    let label: String
    let fireDate: Date
    let isReminder: Bool
    /// For timers: the length you asked for (used in "Your 10 minute timer is done").
    let length: TimeInterval?

    var doneMessage: String {
        if isReminder { return "Reminder: \(label)" }
        return "Your \(DurationText.spoken(length ?? 0)) timer is done."
    }
}

/// Keeps voice timers and reminders. Each one also becomes a macOS notification, so you see it
/// in Notification Center even if you're in a full-screen app.
/// Timers live in memory: quitting AK Assistant cancels them (their notifications are removed too).
@MainActor
@Observable
final class TimerCenter {
    private(set) var timers: [ActiveTimer] = []
    /// Called on the main actor when a timer or reminder goes off.
    @ObservationIgnored var onFire: ((ActiveTimer) -> Void)?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private let presenter = NotificationPresenter()
    @ObservationIgnored private var askedForNotifications = false

    @discardableResult
    func add(label: String, fireDate: Date, isReminder: Bool, length: TimeInterval?) -> ActiveTimer {
        let timer = ActiveTimer(label: label, fireDate: fireDate, isReminder: isReminder, length: length)
        timers.append(timer)
        timers.sort { $0.fireDate < $1.fireDate }
        tasks[timer.id] = Task { [weak self] in
            let wait = max(0, timer.fireDate.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.timers.removeAll { $0.id == timer.id }
            self.tasks[timer.id] = nil
            self.onFire?(timer)
        }
        scheduleNotification(for: timer)
        return timer
    }

    /// Cancels everything; returns how many were running.
    @discardableResult
    func cancelAll() -> Int {
        let count = timers.count
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: timers.map(\.id.uuidString))
        timers.removeAll()
        return count
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        timers.removeAll { $0.id == id }
    }

    /// "Your timer has 4 minutes 10 seconds left. Reminder “Call mom” at 5:00 PM."
    func statusText(now: Date = .now) -> String {
        guard !timers.isEmpty else { return "You don't have any timers or reminders running." }
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = .none
        let lines = timers.map { t -> String in
            let left = DurationText.spoken(max(1, t.fireDate.timeIntervalSince(now).rounded()))
            if t.isReminder { return "“\(t.label)” at \(time.string(from: t.fireDate)) (in \(left))." }
            return "A \(DurationText.spoken(t.length ?? 0)) timer with \(left) left."
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Notifications

    private func scheduleNotification(for timer: ActiveTimer) {
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        let content = UNMutableNotificationContent()
        content.title = timer.isReminder ? "Reminder" : "Timer done"
        content.body = timer.isReminder ? timer.label : timer.doneMessage
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, timer.fireDate.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: timer.id.uuidString, content: content, trigger: trigger)
        let ask = !askedForNotifications
        askedForNotifications = true
        Task {
            if ask { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
            try? await center.add(request)
        }
    }
}

/// Shows the banner even while AK Assistant's own window is in front.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
