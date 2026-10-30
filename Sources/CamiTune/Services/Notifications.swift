import Foundation
import Combine
import UserNotifications

@MainActor
final class NotificationManager: ObservableObject {
    weak var history: UndoCoordinator?
    private static let enabledKey = "profileNotificationsEnabled"
    private let defaults: UserDefaults

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            history?.record(actionName: "Change Notifications", target: .preference(.notifications),
                before: .boolean(oldValue), after: .boolean(isEnabled))
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                Task { await requestAuthorization() }
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func requestAuthorization() async {
        guard isEnabled else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func activated(profileName: String) { post("\(profileName) activated") }
    func deactivated(profileName: String) { post("\(profileName) deactivated") }

    private func post(_ text: String) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "CamiTune"
        content.body = text
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
