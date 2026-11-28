import Adwaita
import CAdw
import CairnCore
import Foundation

/// Sync on this computer: off or on, the computers in the group, changes made
/// here waiting for a decision, and changes from the other computers (with the
/// ones Linux can't use listed and explained). Lives in MainView.
struct SyncState {
    enum Phase: Equatable { case loading, idle, syncing, previewing, applying, failed(String) }

    struct Computer: Identifiable, Equatable {
        var id: String
        var name: String
        var detail: String
        var isLinux: Bool
        var syncing: Bool
    }

    var phase: Phase = .loading
    var enabled = false
    var folder: URL?
    var presetTitle = ""
    var lastSync: Date?
    var computers: [Computer] = []
    var requests: [SyncDeviceInfo] = []
    var plan: SyncPlan?
    var apply: [SyncIncoming] = []
    var skipped: [SyncApplicability.Skipped] = []
    var report: KitReport?
    var doByHand = ""
    var applied = false
    var lastLine = ""
    var confirm = false

    var busy: Bool { [.loading, .syncing, .previewing, .applying].contains(phase) }
    var incomingCount: Int { apply.count }
}

struct SyncPage: View {
    var state: SyncState
    var actions: SyncActions

    var view: Body {
        ScrollView {
            Clamp()
                .maximumSize(720)
                .child {
                    VStack(spacing: 24) {
                        PageHeader(title: "Sync",
                                   blurb: "Keep your computers' setups in step through a shared folder, such as one on your NAS.",
                                   icon: "emblem-synchronizing-symbolic", tint: "tint-purple")
                        if state.enabled { onView } else { offView }
                        if case .failed(let message) = state.phase { problem(message) }
                    }
                    .padding(24, [.leading, .trailing])
                    .padding(28, [.top, .bottom])
                }
        }
        .hscrollbarPolicy(.never)
        .vexpand()
    }

    // MARK: Off

    var offView: AnyView {
        VStack(spacing: 24) {
            Form {
                ActionRow("Sync folder")
                    .subtitle(state.folder.map { BackupFolder.displayPath($0) } ?? "The backup folder")
                    .suffix {
                        Button("Change…") { actions.chooseFolder() }
                            .flat()
                            .valign(.center)
                    }
                ActionRow("Turn on sync")
                    .subtitle("This computer joins the computers already syncing through that folder. Nothing is installed until you review it.")
                    .suffix {
                        Button("Turn On") { actions.turnOn() }
                            .suggested()
                            .valign(.center)
                            .insensitive(state.busy)
                    }
            }
            note("On Linux, sync works through a shared folder. Syncing directly between computers is Mac-only for now.")
        }
    }

    // MARK: On

    var onView: AnyView {
        VStack(spacing: 24) {
            statusCard
            if !state.requests.isEmpty { requestList }
            if !state.computers.isEmpty { computerList }
            if let plan = state.plan, !plan.asks.isEmpty { askList(plan.asks) }
            if !state.apply.isEmpty || !state.skipped.isEmpty { incomingList }
            if let plan = state.plan, !plan.conflicts.isEmpty { conflictList(plan.conflicts) }
            if let plan = state.plan, !plan.removedElsewhere.isEmpty { removedList(plan.removedElsewhere) }
            if let report = state.report, !state.busy {
                ReportView(report: report, doByHandText: state.doByHand, applied: state.applied, appliedWord: "Changes Applied")
            }
            Form {
                ActionRow("Sync folder")
                    .subtitle(state.folder.map { BackupFolder.displayPath($0) } ?? "")
                ActionRow("Turn off sync on this computer")
                    .subtitle("The other computers keep syncing. Nothing on this computer changes.")
                    .suffix {
                        Button("Turn Off") { actions.turnOff() }
                            .flat()
                            .valign(.center)
                            .insensitive(state.busy)
                    }
            }
        }
    }

    var statusCard: AnyView {
        let status: String
        let detail: String
        switch state.phase {
        case .syncing: status = "Syncing…"; detail = "Reading this computer's setup and the shared folder."
        case .previewing: status = "Checking…"; detail = state.lastLine.trimmingCharacters(in: .whitespaces)
        case .applying: status = "Applying changes…"; detail = state.lastLine.trimmingCharacters(in: .whitespaces)
        case .loading: status = "Loading…"; detail = ""
        default:
            if state.plan == nil {
                status = "Sync is on"
                detail = state.lastSync.map { "Last synced " + BackupMessages.date($0) + "." } ?? "Not synced from this computer yet."
            } else if state.incomingCount > 0 {
                status = "\(state.incomingCount) change\(state.incomingCount == 1 ? "" : "s") from your other computers"
                detail = "Review them below. Nothing is installed until you press Apply."
            } else {
                status = "In sync"
                detail = state.lastSync.map { "Synced " + BackupMessages.date($0) + "." } ?? ""
            }
        }
        return HStack(spacing: 14) {
            if state.busy {
                Spinner()
                    .frame(minWidth: 24)
                    .valign(.center)
            } else {
                Symbol(icon: .custom(name: state.incomingCount > 0 ? "emblem-synchronizing-symbolic" : "emblem-ok-symbolic"))
                    .pixelSize(20)
                    .style("tile")
                    .style("tile-large")
                    .style(state.incomingCount > 0 ? "tint-purple" : "tint-green")
            }
            VStack(spacing: 2) {
                Text(status)
                    .title3()
                    .halign(.start)
                Text(detail)
                    .ellipsize()
                    .dimLabel()
                    .halign(.start)
            }
            .valign(.center)
            .hexpand()
            Button("Sync Now") { actions.syncNow() }
                .suggested()
                .valign(.center)
                .insensitive(state.busy)
        }
        .padding(16)
        .inCard("card")
    }

    var requestList: AnyView {
        FormSection("Asking to Join") {
            Form {
                ForEach(state.requests.map(\.name), id: \.self) { name in
                    let info = state.requests.first { $0.name == name }!
                    ActionRow(name)
                        .subtitle("\(info.os) \(info.osVersion) wants to sync with this computer")
                        .prefix { tile("computer-symbolic", "tint-blue") }
                        .suffix {
                            HStack(spacing: 6) {
                                Button("Ignore") { actions.ignore(info) }
                                    .flat()
                                Button("Trust") { actions.trust(info) }
                                    .suggested()
                            }
                            .valign(.center)
                        }
                }
            }
        }
    }

    var computerList: AnyView {
        FormSection("Your Other Computers") {
            Form {
                ForEach(state.computers) { c in
                    ActionRow(c.name)
                        .subtitle(c.detail)
                        .prefix { tile(c.isLinux ? "computer-symbolic" : "computer-apple-symbolic", c.isLinux ? "tint-orange" : "tint-gray") }
                }
            }
        }
    }

    func askList(_ asks: [SyncAsk]) -> AnyView {
        FormSection("Changed on This Computer") {
            Form {
                ForEach(asks) { ask in
                    ActionRow(ask.title)
                        .subtitle(ask.isRemoval ? "Removed here. Remove it from your other computers too?" : "Installed here. Add it to your other computers too?")
                        .prefix { tile(ask.isRemoval ? "list-remove-symbolic" : "list-add-symbolic", "tint-purple") }
                        .suffix {
                            HStack(spacing: 6) {
                                Button("This Computer Only") { actions.keepHere(ask) }
                                    .flat()
                                Button(ask.isRemoval ? "Remove There Too" : "Add to Others") { actions.share(ask) }
                            }
                            .valign(.center)
                        }
                }
            }
        }
    }

    var incomingList: AnyView {
        VStack(spacing: 24) {
            if !state.apply.isEmpty {
                FormSection("From Your Other Computers") {
                    Form {
                        ForEach(state.apply) { item in
                            ActionRow(item.title)
                                .subtitle((item.current == nil ? "New" : "Changed") + " on " + item.entry.device)
                                .prefix { tile(Style.icon(item.category), Style.tint(item.category)) }
                        }
                        ActionRow("Apply these changes here")
                            .subtitle("Preview first: it lists exactly what would be installed or changed.")
                            .suffix {
                                HStack(spacing: 6) {
                                    Button("Preview") { actions.preview() }
                                        .insensitive(state.busy)
                                    Button("Apply…") { actions.askToApply() }
                                        .suggested()
                                        .insensitive(state.busy || state.report == nil || state.applied || (state.report?.changeCount ?? 0) == 0)
                                }
                                .valign(.center)
                            }
                    }
                }
            }
            if !state.skipped.isEmpty {
                FormSection("Not for This Computer") {
                    Form {
                        ForEach(state.skipped.map(\.item.id), id: \.self) { id in
                            let s = state.skipped.first { $0.item.id == id }!
                            ActionRow(s.item.title)
                                .subtitle(s.reason)
                                .prefix { tile("action-unavailable-symbolic", "tint-gray") }
                        }
                    }
                }
            }
        }
    }

    func conflictList(_ conflicts: [SyncConflict]) -> AnyView {
        FormSection("Changed in Two Places") {
            Form {
                ForEach(conflicts) { c in
                    ActionRow(c.title)
                        .subtitle("Changed here and on \(c.theirs.device). This computer's version was kept.")
                        .prefix { tile("dialog-warning-symbolic", "tint-orange") }
                }
            }
        }
    }

    func removedList(_ removed: [SyncIncoming]) -> AnyView {
        FormSection("Removed Elsewhere") {
            Form {
                ForEach(removed) { r in
                    ActionRow(r.title)
                        .subtitle("Removed on \(r.entry.device). Sync never uninstalls, so it stays here.")
                        .prefix { tile("list-remove-symbolic", "tint-gray") }
                        .suffix {
                            Button("OK") { actions.dismissRemoval(r.id) }
                                .flat()
                                .valign(.center)
                        }
                }
            }
        }
    }

    func tile(_ name: String, _ tint: String) -> AnyView {
        Symbol(icon: .custom(name: name))
            .pixelSize(16)
            .style("tile")
            .style(tint)
            .valign(.center)
    }

    func note(_ text: String) -> AnyView {
        HStack(spacing: 8) {
            Symbol(icon: .custom(name: "dialog-information-symbolic"))
                .pixelSize(14)
                .dimLabel()
                .valign(.start)
            Text(text)
                .wrap()
                .caption()
                .dimLabel()
                .halign(.start)
                .hexpand()
        }
    }

    func problem(_ message: String) -> AnyView {
        HStack(spacing: 12) {
            Symbol(icon: .custom(name: "dialog-error-symbolic"))
                .pixelSize(20)
                .error()
            Text(message)
                .wrap()
                .halign(.start)
                .hexpand()
        }
        .padding(16)
        .inCard("card")
    }
}

/// What the Sync page's buttons do (implemented by MainView).
struct SyncActions {
    var chooseFolder: () -> Void
    var turnOn: () -> Void
    var turnOff: () -> Void
    var syncNow: () -> Void
    var trust: (SyncDeviceInfo) -> Void
    var ignore: (SyncDeviceInfo) -> Void
    var share: (SyncAsk) -> Void
    var keepHere: (SyncAsk) -> Void
    var dismissRemoval: (String) -> Void
    var preview: () -> Void
    var askToApply: () -> Void
}
