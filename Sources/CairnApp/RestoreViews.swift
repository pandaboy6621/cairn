import CairnCore
import SwiftUI

// MARK: - Vault unlock panel

/// The centered panel shown before restoring a backup with encrypted secrets:
/// a padlock that opens once the vault password checks out.
struct VaultUnlockPanel: View {
    @Environment(AppModel.self) private var model
    let preview: RestorePreview
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var run = model.restore
        let unlocked = run.unlock == .unlocked
        let tint: Color = unlocked ? .green : run.unlock == .wrong ? .red : .accentColor
        let secrets = run.secretSummary(preview)

        VStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.14)).frame(width: 92, height: 92)
                Circle().strokeBorder(tint.opacity(0.35), lineWidth: 2).frame(width: 92, height: 92)
                    .scaleEffect(unlocked ? 1.25 : 1)
                    .opacity(unlocked ? 0 : 1)
                    .animation(.easeOut(duration: 0.7), value: unlocked)
                Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: unlocked)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: unlocked)
            .animation(.easeInOut(duration: 0.2), value: run.unlock)

            VStack(spacing: 6) {
                Text(unlocked ? "Unlocked" : "This backup has encrypted secrets")
                    .font(.title2.weight(.semibold))
                Text(unlocked ? "\(secrets.text) will be restored to this Mac."
                     : "\(secrets.text) \(secrets.count == 1 ? "is" : "are") locked with your vault password. Enter it to restore them to this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !unlocked {
                SecureField("Vault password", text: $run.vaultPassword)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(width: 280)
                    .focused($focused)
                    .disabled(run.unlock == .checking)
                    .onSubmit { run.tryUnlock(preview, model: model) }
                    .modifier(Shake(animatableData: CGFloat(run.wrongAttempts)))
                    .animation(.linear(duration: 0.4), value: run.wrongAttempts)

                Text(run.unlock == .wrong ? "That password didn't unlock the vault. Try again." : " ")
                    .font(.caption)
                    .foregroundStyle(.red)

                HStack(spacing: 10) {
                    Button("Cancel") { run.phase = .idle; run.vaultPassword = ""; run.unlock = .idle }
                        .keyboardShortcut(.cancelAction)
                    Button("Skip Secrets…") { run.phase = .skipWarning }
                    Button {
                        run.tryUnlock(preview, model: model)
                    } label: {
                        if run.unlock == .checking {
                            ProgressView().controlSize(.small).frame(width: 52)
                        } else {
                            Text("Unlock").frame(width: 52)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear { focused = true }
        .onChange(of: run.unlock) { _, new in if new == .wrong { focused = true } }
        .alert("This backup contains encrypted secrets",
               isPresented: Binding(get: { if case .skipWarning = run.phase { return true } else { return false } },
                                    set: { if !$0, case .skipWarning = run.phase { run.phase = .unlocking } })) {
            Button("Enter Password") { run.phase = .unlocking; focused = true }
                .keyboardShortcut(.defaultAction)
            Button("Restore Without Secrets", role: .destructive) {
                run.skipSecrets = true
                run.vaultPassword = ""
                run.phase = .confirming
            }
            Button("Cancel", role: .cancel) { run.phase = .idle; run.vaultPassword = "" }
        } message: {
            Text("\(secrets.text) in this backup \(secrets.count == 1 ? "is" : "are") encrypted. Without the vault password \(secrets.count == 1 ? "it" : "they") won't be restored, but everything else will.")
        }
    }
}

/// Shakes a view side to side once per whole step of `animatableData`.
struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(animatableData * .pi * 4), y: 0))
    }
}

// MARK: - Running

/// While a restore runs: a big status icon, the current step, one flat progress
/// bar, and a task list whose Details arrow opens the full log.
struct RestoreProgressPanel: View {
    @Environment(AppModel.self) private var model
    private let showDetails = State(initialValue: false)

    var body: some View {
        let run = model.restore
        let line: String = { if case .running(let l) = run.phase { return l } else { return "" } }()
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.blue)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 460)
                    HStack(spacing: 10) {
                        ProgressView(value: min(1, max(0, run.fraction)))
                            .progressViewStyle(.linear)
                            .animation(.easeInOut(duration: 0.4), value: run.fraction)
                        Text("\(Int((run.fraction * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(maxWidth: 460)
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(run.tasks) { task in
                        HStack(spacing: 10) {
                            Group {
                                switch task.status {
                                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                case .active: ProgressView().controlSize(.small)
                                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                                }
                            }
                            .frame(width: 18)
                            Text(task.name)
                                .foregroundStyle(task.status == .pending ? .secondary : .primary)
                                .fontWeight(task.status == .active ? .semibold : .regular)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        Divider().padding(.leading, 40)
                    }
                    DisclosureGroup(isExpanded: showDetails.projectedValue) {
                        RestoreLogView(log: run.log).frame(height: 160).padding(.top, 6)
                    } label: {
                        Text("Details").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
                .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }

}

/// The detailed log: step headings and per-item lines, newest at the bottom.
struct RestoreLogView: View {
    let log: [RestoreRun.LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(log) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(l.time, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.tertiary)
                            Text(l.isStep ? l.text : "  " + l.text)
                                .foregroundStyle(l.isStep ? .primary : .secondary)
                                .textSelection(.enabled)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .id(l.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .onChange(of: log.count) { _, _ in if let last = log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onAppear { if let last = log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
    }
}

// MARK: - Finished

/// The centered "Restore finished" notice with a checkmark.
struct RestoreFinishedNotice: View {
    let outcome: RestoreRun.Outcome
    private let appearedState = State(initialValue: false)
    private var appeared: Bool { appearedState.wrappedValue }

    var body: some View {
        let ok = outcome.problems == 0
        let manual = outcome.report.manualSteps.count
        VStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(ok ? .green : .orange)
                .symbolEffect(.bounce, value: appeared)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
            Text(ok ? "Restore finished" : "Restore finished with \(outcome.problems) problem\(outcome.problems == 1 ? "" : "s")")
                .font(.title3.weight(.semibold))
            Text(summary(manual: manual))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 14)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { appearedState.wrappedValue = true } }
    }

    private func summary(manual: Int) -> String {
        var parts = ["\(outcome.verified) item\(outcome.verified == 1 ? "" : "s") restored and checked"]
        let skippedSecrets = outcome.report.entries.contains {
            if case .skipped(let why) = $0.outcome { return why.hasPrefix("skipped by you") } else { return false }
        }
        if skippedSecrets { parts.append("secrets skipped") }
        if manual > 0 { parts.append("\(manual) to finish by hand below") }
        return parts.joined(separator: " · ")
    }
}
