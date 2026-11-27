import AppKit
import CairnCore
@preconcurrency import UserNotifications

/// Notifications for installs and removals: on this Mac ("VLC was installed:
/// add it to your other Macs?") and from the others ("Studio Mac installed VLC:
/// install it here?"). Each is posted once; answering one, here or in the Sync
/// tab, takes it away.
@MainActor
final class SyncNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SyncNotifier()

    enum Kind: String, CaseIterable {
        case askAdd, askRemove, incomingAdd, incomingRemove, incomingRemoveByHand, summary
    }

    enum Action: String {
        case share, keep, install, skip, uninstall, open
    }

    /// Answers from notifications (set by the app model).
    var handle: ((Kind, String, Action) -> Void)?

    /// Show these notifications at all (Settings).
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }
    static let enabledKey = "syncNotifications"
    private static let postedKey = "syncNotified"

    /// Notifications need a bundled app (not `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? .current() : nil
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        func action(_ a: Action, _ title: String, _ options: UNNotificationActionOptions = []) -> UNNotificationAction {
            UNNotificationAction(identifier: a.rawValue, title: title, options: options)
        }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Kind.askAdd.rawValue,
                                   actions: [action(.share, "Add to Other Macs"), action(.keep, "This Mac Only")],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.askRemove.rawValue,
                                   actions: [action(.share, "Remove from Other Macs"), action(.keep, "This Mac Only")],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.incomingAdd.rawValue,
                                   actions: [action(.install, "Install"), action(.skip, "Not on This Mac")],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.incomingRemove.rawValue,
                                   actions: [action(.uninstall, "Uninstall", .destructive), action(.keep, "Keep It")],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.incomingRemoveByHand.rawValue,
                                   actions: [action(.keep, "Keep It")], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.summary.rawValue,
                                   actions: [action(.open, "Show in Cairn", .foreground)], intentIdentifiers: []),
        ])
    }

    private struct Note {
        var kind: Kind
        var id: String
        var stamp: String
        var title: String
        var body: String
    }

    /// Posts what's new in a sync plan (each once).
    func post(_ plan: SyncPlan) {
        guard enabled, let center else { return }
        var notes: [Note] = []
        for a in plan.asks {
            notes.append(a.isRemoval
                ? Note(kind: .askRemove, id: a.id, stamp: "-", title: "\(a.title) was removed",
                       body: "Remove it from your other Macs too? Each one asks before removing anything.")
                : Note(kind: .askAdd, id: a.id, stamp: a.value?.hash ?? "", title: "\(a.title) was installed",
                       body: "Add it to your other Macs too? Each one asks before installing anything."))
        }
        for i in plan.incoming where i.current == nil && SyncEngine.asksFirst(i.id) {
            notes.append(Note(kind: .incomingAdd, id: i.id, stamp: "\(i.entry.updated.timeIntervalSince1970)",
                              title: "\(Self.mac(i.entry.device)) installed \(i.title)",
                              body: "Install it on this Mac too? " + Self.installText(i.entry.value)))
        }
        for r in plan.removedElsewhere where SyncEngine.asksFirst(r.id) {
            let removal = r.current.flatMap { SoftwareRemover().removal(for: $0) }
            notes.append(Note(kind: removal == nil ? .incomingRemoveByHand : .incomingRemove, id: r.id,
                              stamp: "\(r.entry.updated.timeIntervalSince1970)",
                              title: "\(Self.mac(r.entry.device)) removed \(r.title)",
                              body: removal.map { "Uninstall it here too? Cairn would \($0.summary)." }
                                  ?? "Cairn can't remove it for you. Remove it yourself if you like."))
        }
        var posted = UserDefaults.standard.stringArray(forKey: Self.postedKey) ?? []
        let fresh = notes.filter { !posted.contains(Self.key($0)) }
        guard !fresh.isEmpty else { return }
        posted += fresh.map(Self.key)
        UserDefaults.standard.set(Array(posted.suffix(300)), forKey: Self.postedKey)

        // A pile at once (a first sync, a new Mac) is one notification, not dozens.
        let toPost = fresh.count > 4
            ? [Note(kind: .summary, id: "summary", stamp: "", title: "\(fresh.count) app changes are waiting",
                    body: "Apps and packages installed or removed on your Macs. Choose what to do in Cairn.")]
            : fresh
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for note in toPost {
                let content = UNMutableNotificationContent()
                content.title = note.title
                content.body = note.body
                content.categoryIdentifier = note.kind.rawValue
                content.userInfo = ["kind": note.kind.rawValue, "id": note.id]
                content.sound = .default
                center.add(UNNotificationRequest(identifier: "\(note.kind.rawValue)|\(note.id)", content: content, trigger: nil))
            }
        }
    }

    /// Takes away a notification once it's been answered elsewhere.
    func withdraw(_ kind: Kind, id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: ["\(kind.rawValue)|\(id)"])
        if kind == .incomingRemove { center?.removeDeliveredNotifications(withIdentifiers: ["\(Kind.incomingRemoveByHand.rawValue)|\(id)"]) }
    }

    /// A plain note: how an install or removal went.
    func report(_ title: String, _ body: String) {
        guard enabled, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func key(_ n: Note) -> String { "\(n.kind.rawValue)|\(n.id)|\(n.stamp)" }

    /// How a Mac is named in a notification.
    static func mac(_ device: String) -> String { device }

    static func installText(_ value: SyncValue?) -> String {
        if let p = value?.package, p.kind != .tap {
            return "Cairn would run brew install --\(p.kind.rawValue) \(p.resolvers["brew"] ?? p.id)."
        }
        if value?.app != nil { return "It opens in the App Store for you to install." }
        return ""
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = (info["kind"] as? String).flatMap(Kind.init(rawValue:))
        let id = info["id"] as? String
        // Clicking the notification itself (not a button) opens the Sync tab.
        let action = Action(rawValue: response.actionIdentifier) ?? .open
        Task { @MainActor in
            if let kind, let id { SyncNotifier.shared.handle?(kind, id, action) }
            completionHandler()
        }
    }
}
