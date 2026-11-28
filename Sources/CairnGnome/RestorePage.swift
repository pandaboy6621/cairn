import Adwaita
import CAdw
import CairnCore
import Foundation

/// Where a restore is: nothing yet, previewing (dry run), previewed, applying,
/// applied, or stopped by an error. Lives in MainView, so it survives switching pages.
struct RestoreState {
    enum Phase: Equatable { case idle, previewing, previewed, applying, applied, failed(String) }

    var snapshotID: String?
    var phase: Phase = .idle
    var report: KitReport?
    var doByHand = ""
    /// The newest line of output while it runs.
    var lastLine = ""
    var confirm = false

    var running: Bool { phase == .previewing || phase == .applying }
}

/// One snapshot in the picker: "27 Nov 2026 at 6:35 PM · laptop".
struct SnapshotChoice: Identifiable, CustomStringConvertible {
    var id: String
    var description: String
}

struct RestorePage: View {
    var snapshots: [Snapshot]
    var state: RestoreState
    var select: (String) -> Void
    var preview: () -> Void
    var askToApply: () -> Void

    var choices: [SnapshotChoice] {
        snapshots.map { SnapshotChoice(id: $0.id, description: BackupMessages.date($0.info.created) + " · " + $0.info.device) }
    }

    var view: Body {
        if snapshots.isEmpty {
            StatusPage("No Backups to Restore", icon: .custom(name: "document-revert-symbolic"),
                       description: "Back up this computer first, or choose the folder where your backups are.")
                .vexpand()
        } else {
            ScrollView {
                Clamp()
                    .maximumSize(720)
                    .child {
                        VStack(spacing: 24) {
                            PageHeader(title: "Restore",
                                       blurb: "Set this computer up from a backup. Preview first: nothing changes until you press Apply.",
                                       icon: "document-revert-symbolic", tint: "tint-teal")
                            picker
                            if state.running || isFailed { progress }
                            if state.report != nil && !state.running { results }
                            footnote
                        }
                        .padding(24, [.leading, .trailing])
                        .padding(28, [.top, .bottom])
                    }
            }
            .hscrollbarPolicy(.never)
            .vexpand()
        }
    }

    var picker: AnyView {
        Form {
            ComboRow("Backup", selection: Binding { state.snapshotID ?? snapshots.first?.id ?? "" } set: { select($0) },
                     values: choices)
            ActionRow("Preview")
                .subtitle("Lists what restoring would change. Changes nothing.")
                .suffix {
                    Button(state.phase == .previewing ? "Previewing…" : "Preview") { preview() }
                        .valign(.center)
                        .insensitive(state.running)
                }
            ActionRow("Apply")
                .subtitle(applySubtitle)
                .suffix {
                    Button(state.phase == .applying ? "Applying…" : "Apply…") { askToApply() }
                        .suggested()
                        .valign(.center)
                        .insensitive(!canApply)
                }
        }
    }

    var isFailed: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    var canApply: Bool {
        state.phase == .previewed && (state.report?.changeCount ?? 0) > 0
    }

    var applySubtitle: String {
        switch state.phase {
        case .previewed where (state.report?.changeCount ?? 0) == 0: return "Nothing to change: this computer already matches the backup."
        case .previewed: return "Makes the changes listed below. Asks for your password."
        case .applied: return "Done. Preview again to check."
        default: return "Available after a preview."
        }
    }

    @ViewBuilder var progress: Body {
        if state.running {
            HStack(spacing: 12) {
                Spinner()
                    .valign(.center)
                VStack(spacing: 2) {
                    Text(state.phase == .applying ? "Setting up this computer…" : "Checking what's already here…")
                        .heading()
                        .halign(.start)
                    Text(state.lastLine.trimmingCharacters(in: .whitespaces))
                        .ellipsize()
                        .caption()
                        .dimLabel()
                        .halign(.start)
                }
                .hexpand()
            }
            .padding(16)
            .inCard("card")
        }
        if case .failed(let message) = state.phase {
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

    @ViewBuilder var results: Body {
        if let report = state.report, !state.running {
            ReportView(report: report, doByHandText: state.doByHand, applied: state.phase == .applied)
        }
    }

    var footnote: AnyView {
        HStack(spacing: 8) {
            Symbol(icon: .custom(name: "security-high-symbolic"))
                .pixelSize(14)
                .dimLabel()
                .valign(.start)
            Text("Restore installs software and changes settings only after you press Apply and enter your password. Your password goes to the system's sudo and is never saved.")
                .wrap()
                .caption()
                .dimLabel()
                .halign(.start)
                .hexpand()
        }
    }
}

/// A kit run's result: a summary, each group's changes (the rest folded into
/// "already there") and the Do by Hand list. Used by Restore and Sync.
struct ReportView: View {
    var report: KitReport
    var doByHandText: String
    var applied: Bool
    /// Words for the summary: "Restored", "Changes Applied".
    var appliedWord = "Restored"

    var view: Body {
        VStack(spacing: 24) {
            summaryBanner(report)
            ForEach(report.sections.map(\.title), id: \.self) { title in
                section(report.sections.first { $0.title == title }!)
            }
            if !doByHandText.isEmpty || !report.downloads.isEmpty {
                doByHand(report)
            }
        }
    }

    func summaryBanner(_ report: KitReport) -> AnyView {
        
        let changes = report.changeCount
        let failed = report.sections.reduce(0) { $0 + $1.count(.failed) }
        let title: String
        let detail: String
        if applied {
            title = failed > 0 ? "\(appliedWord), with \(failed) problem\(failed == 1 ? "" : "s")" : appliedWord
            detail = changes == 0 ? "Nothing needed changing." : "\(changes) change\(changes == 1 ? "" : "s") made. Details below."
        } else {
            title = changes == 0 ? "Already Set Up" : "\(changes) Change\(changes == 1 ? "" : "s") to Make"
            detail = changes == 0 ? "This computer already matches the backup." : "Nothing has changed yet. Press Apply to make these changes."
        }
        let good = changes == 0 || (applied && failed == 0)
        return HStack(spacing: 14) {
            Symbol(icon: .custom(name: good ? "emblem-ok-symbolic" : (applied ? "dialog-warning-symbolic" : "document-edit-symbolic")))
                .pixelSize(20)
                .style("tile")
                .style("tile-large")
                .style(good ? "tint-green" : (applied ? "tint-orange" : "tint-blue"))
            VStack(spacing: 2) {
                Text(title)
                    .title3()
                    .halign(.start)
                Text(detail)
                    .wrap()
                    .dimLabel()
                    .halign(.start)
            }
            .valign(.center)
            .hexpand()
        }
        .padding(16)
        .inCard("card")
    }

    func section(_ s: KitReport.Section) -> AnyView {
        let already = s.count(.already)
        let changes = s.changes
        return FormSection(s.title) {
            Form {
                if changes.isEmpty {
                    ActionRow("All \(already) already there")
                        .prefix { icon("emblem-ok-symbolic", "tint-green") }
                } else {
                    ForEach(changes.map(\.text), id: \.self) { text in
                        row(changes.first { $0.text == text }!)
                    }
                    if already > 0 {
                        ActionRow("\(already) more already there")
                            .prefix { icon("emblem-ok-symbolic", "tint-green") }
                    }
                }
            }
        }
    }

    func row(_ item: KitReport.Item) -> AnyView {
        ActionRow(item.title)
            .subtitle(item.detail)
            .prefix { icon(Self.icon(item.status), Self.tint(item.status)) }
    }

    func icon(_ name: String, _ tint: String) -> AnyView {
        Symbol(icon: .custom(name: name))
            .pixelSize(16)
            .style("tile")
            .style(tint)
            .valign(.center)
    }

    static func icon(_ s: KitReport.Status) -> String {
        switch s {
        case .willAdd, .willInstall: return "list-add-symbolic"
        case .willChange, .willWrite: return "document-edit-symbolic"
        case .already, .done: return "emblem-ok-symbolic"
        case .skipped: return "action-unavailable-symbolic"
        case .unavailable: return "dialog-question-symbolic"
        case .failed: return "dialog-error-symbolic"
        }
    }

    static func tint(_ s: KitReport.Status) -> String {
        switch s {
        case .willAdd, .willInstall, .willChange, .willWrite: return "tint-blue"
        case .already, .done: return "tint-green"
        case .skipped, .unavailable: return "tint-gray"
        case .failed: return "tint-red"
        }
    }

    func doByHand(_ report: KitReport) -> AnyView {
        FormSection("Do by Hand") {
            Form {
                ForEach(report.downloads, id: \.self) { name in
                    ActionRow(name)
                        .subtitle("Downloaded from its maker's website, so get it there")
                        .prefix { icon("folder-download-symbolic", "tint-orange") }
                        .suffix {
                            if let url = PackageCatalog.debDownloads[name] {
                                Button("Open Website") { ReportView.open(url) }
                                    .valign(.center)
                                    .flat()
                            }
                        }
                }
                ForEach(report.unavailable, id: \.self) { name in
                    ActionRow(name)
                        .subtitle("Not available from the package manager here: install it another way")
                        .prefix { icon("dialog-question-symbolic", "tint-gray") }
                }
                ForEach(Self.otherSteps(doByHandText), id: \.self) { step in
                    ActionRow(step.title)
                        .subtitle(step.detail)
                        .subtitleLines(3)
                        .prefix { icon("document-properties-symbolic", "tint-gray") }
                }
            }
        }
    }

    struct Step: Hashable { var title: String; var detail: String }

    /// The checklist's other headings (shell config, macOS-only lines, ...), with
    /// their first sentence. Downloads and "On Fedora" are shown elsewhere or not at all.
    static func otherSteps(_ checklist: String) -> [Step] {
        var steps: [Step] = []
        let parts = checklist.components(separatedBy: "\n### ").dropFirst()
        for part in parts {
            let lines = part.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let heading = lines.first else { continue }
            let title = heading.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
            if title.hasPrefix("Apps from downloaded") || title == "On Fedora" || title.hasPrefix("Not in every") { continue }
            let sentence = lines.dropFirst().first { !$0.hasPrefix("- [ ]") } ?? ""
            let items = lines.filter { $0.hasPrefix("- [ ]") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "`", with: "") }
            steps.append(Step(title: title, detail: ([sentence] + items).filter { !$0.isEmpty }.joined(separator: "\n")))
        }
        return steps
    }

    static func open(_ url: String) {
        g_app_info_launch_default_for_uri(url, nil, nil)
    }

}
