// LimitsBar: menu bar view of 5h / weekly / Fable usage across all Claude Code and Codex
// accounts, with reset countdowns. Data comes from ~/.local/bin/limits --json (the same
// profiles the CLIs use). Build with ./build.sh; it produces ~/Applications/LimitsBar.app.
import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

struct Win: Decodable, Sendable {
    var pct: Double?; var resets: String?; var resetsEpoch: Double?; var windowSeconds: Double?
    enum CodingKeys: String, CodingKey { case pct, resets, resetsEpoch = "resets_epoch", windowSeconds = "window_seconds" }
}
struct LimitResets: Decodable, Sendable {
    var available: Int?; var usableNow: Int?; var expires: [Double]?   // one expiry per credit, ascending
    enum CodingKeys: String, CodingKey { case available, usableNow = "usable_now", expires }
}
struct Row: Decodable, Identifiable, Sendable {
    var provider: String; var name: String; var plan: String?; var note: String?
    var fiveH: Win?; var week: Win?; var fable: Win?
    var limitResets: LimitResets?
    var dir: String?; var primary: Bool?   // profile dir, and whether the bare `claude`/`codex` command opens it
    var id: String { provider + "|" + name }
    enum CodingKeys: String, CodingKey { case provider, name, plan, note, fiveH = "5h", week, fable, limitResets = "limit_resets", dir, primary }
}

@MainActor final class Model: ObservableObject {
    @Published var rows: [Row] = []
    @Published var updated = "…"
    @Published var error = ""
    @Published var busy = false
    @Published var tick = Date()   // drives the title countdown between fetches
    @Published var loginItem = SMAppService.mainApp.status == .enabled
    private var timer: Timer?, ticker: Timer?
    private var previous: [String: Row] = [:]   // last sample per account, for threshold crossings

    init() {
        if Bundle.main.bundleIdentifier != nil {   // notifications need a real bundle; skip when run bare
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick = Date() }
        }
    }

    static func short(_ name: String) -> String {   // "visual.design@airtribe.live" -> "visual"
        let local = name.split(separator: "@").first.map(String.init) ?? name
        return local.split(separator: ".").first.map(String.init) ?? local
    }
    static func headroom(_ r: Row) -> Win? { r.fiveH ?? r.week }   // the window that gates usage right now

    /// Menu bar text: per provider, the account with the most headroom and its usage; if every
    /// account is exhausted, the soonest reset instead.
    var title: String {
        func part(_ p: String, _ letter: String) -> String {
            let rs = rows.filter { $0.provider == p }
            guard let best = rs.min(by: { (Self.headroom($0)?.pct ?? 999) < (Self.headroom($1)?.pct ?? 999) }),
                  let pct = Self.headroom(best)?.pct else { return "\(letter) –" }
            if pct < 100 { return "\(letter) \(Self.short(best.name)) \(Int(pct.rounded()))%" }
            if let soonest = rs.compactMap({ Self.headroom($0)?.resetsEpoch }).min() {
                return "\(letter) ⏱ \(countdown(soonest - tick.timeIntervalSince1970))"
            }
            return "\(letter) 100%"
        }
        return part("claude", "C") + " · " + part("codex", "X")
    }

    /// Reset alerts are handed to the system at the exact reset time of any exhausted window;
    /// 80% / 100% alerts fire when a window crosses the line between two samples.
    private func notify(_ new: [Row]) {
        let center = UNUserNotificationCenter.current()
        let df = DateFormatter(); df.dateFormat = "EEE HH:mm"
        for r in new {
            let prev = previous[r.id]
            for (label, w, pw) in [("5-hour", r.fiveH, prev?.fiveH), ("weekly", r.week, prev?.week), ("Fable weekly", r.fable, prev?.fable)] {
                guard let pct = w?.pct else { continue }
                let id = "\(r.id)|\(label)", who = "\(Self.short(r.name)) (\(r.provider))"
                let resetAt = w?.resetsEpoch.map { Date(timeIntervalSince1970: $0) }
                if pct >= 100, let at = resetAt, at > Date() {
                    let c = UNMutableNotificationContent()
                    c.title = "\(who): \(label) limit reset"; c.body = "\(r.name) is usable again"; c.sound = .default
                    center.add(UNNotificationRequest(identifier: "reset|" + id, content: c,
                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false)))
                } else {
                    center.removePendingNotificationRequests(withIdentifiers: ["reset|" + id])
                }
                guard let pp = pw?.pct else { continue }
                for thr in [80.0, 100.0] where pp < thr && pct >= thr {
                    let c = UNMutableNotificationContent()
                    c.title = thr >= 100 ? "\(who): \(label) limit reached" : "\(who): \(label) at \(Int(pct.rounded()))%"
                    c.body = resetAt.map { "resets \(df.string(from: $0))" } ?? r.name; c.sound = .default
                    center.add(UNNotificationRequest(identifier: "thr|\(id)|\(Int(thr))|\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil))
                }
            }
            previous[r.id] = r
        }
    }

    struct AddResult { var provider: String; var message: String; var command: String }
    @Published var addResult: AddResult?

    /// Create a new profile dir via `limits add`; the browser sign-in itself has to run in a terminal.
    func addAccount(_ provider: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let py = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        let p = Process(); p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [home + "/.local/bin/limits", "add", provider, n]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { addResult = AddResult(provider: provider, message: "cannot run limits: \(error.localizedDescription)", command: ""); return }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        p.waitUntilExit()
        let ok = p.terminationStatus == 0
        addResult = AddResult(provider: provider, message: ok ? "Created ~/.\(provider)-\(n). Sign in once, then it appears here:" : text,
                              command: ok ? (provider == "claude" ? "claude-\(n) auth login" : "codex-\(n) login") : "")
    }

    func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }

    /// Opens Terminal.app with the command; the login shell there defines the new wrapper from the profile dir.
    func runInTerminal(_ cmd: String) {
        let quoted = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Terminal\"\nactivate\ndo script \"\(quoted)\"\nend tell")?.executeAndReturnError(&err)
        if let e = err { self.error = "Terminal: \(e[NSAppleScript.errorMessage] ?? "could not run the command; copy it instead")" }
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "login item: \(error.localizedDescription)" }
        loginItem = SMAppService.mainApp.status == .enabled
        if on && SMAppService.mainApp.status == .requiresApproval {
            self.error = "Approve LimitsBar under System Settings → General → Login Items"
        }
    }

    func rows(for provider: String) -> [Row] {
        // headroom = 5h usage, or weekly usage on plans without a 5h window
        rows.filter { $0.provider == provider }
            .sorted { ($0.fiveH?.pct ?? $0.week?.pct ?? 999) < ($1.fiveH?.pct ?? $1.week?.pct ?? 999) }
    }

    /// Write <base>/.primary so the bare `claude`/`codex` wrapper opens this profile next time.
    func setPrimary(_ row: Row) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = home + (row.provider == "claude" ? "/.claude" : "/.codex")
        let content = (row.dir == nil || row.dir == base) ? "" : row.dir! + "\n"
        try? content.write(toFile: base + "/.primary", atomically: true, encoding: .utf8)
        refresh()
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        Task.detached {
            let (rows, err) = Self.fetch()
            await MainActor.run {
                self.rows = rows; self.error = err; self.busy = false
                self.updated = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                if !rows.isEmpty { self.notify(rows) }
            }
        }
    }

    nonisolated static func fetch() -> ([Row], String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let py = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [home + "/.local/bin/limits", "--json"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return ([], "cannot run limits: \(error.localizedDescription)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let edata = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        do { return (try JSONDecoder().decode([Row].self, from: data), "") } catch {
            let msg = String(data: edata, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ([], msg.isEmpty ? "limits returned no usable data" : String(msg.suffix(200)))
        }
    }
}

@main struct LimitsBarApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            HStack(spacing: 4) { Image(systemName: "gauge.medium"); Text(model.title).monospacedDigit() }
        }
        .menuBarExtraStyle(.window)
    }
}

func usageColor(_ p: Double?) -> Color {
    guard let p else { return .gray }
    return p < 50 ? .green : p < 80 ? .orange : .red
}

/// "21 Sep (in 15d), 4 Oct (in 28d), 4 Oct (in 28d)" — one entry per reset credit
func expiryList(_ epochs: [Double], now: Date) -> String {
    let df = DateFormatter(); df.dateFormat = "d MMM"
    return epochs.map { e in
        let date = Date(timeIntervalSince1970: e), days = Int(date.timeIntervalSince(now) / 86400)
        return df.string(from: date) + (days <= 0 ? " (today)" : " (in \(days)d)")
    }.joined(separator: ", ")
}

func countdown(_ t: TimeInterval) -> String {
    let s = Int(max(0, t)), d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return m > 0 ? "\(m)m" : "now"
}

struct ContentView: View {
    @ObservedObject var model: Model
    var body: some View {
        // re-render every minute so the countdowns stay current between fetches
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            VStack(alignment: .leading, spacing: 12) {
                ProviderSection(model: model, provider: "claude", title: "Claude", accent: .orange, now: ctx.date)
                ProviderSection(model: model, provider: "codex", title: "Codex", accent: .teal, now: ctx.date)
                if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red) }
                if model.rows.isEmpty && model.error.isEmpty {
                    Text(model.busy ? "Loading…" : "No accounts found").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 10) {
                    Text("Updated \(model.updated)").font(.caption2).foregroundStyle(.secondary)
                        .help("Refreshes every 5 minutes")
                    Toggle("Start at login", isOn: Binding(get: { model.loginItem }, set: { model.setLoginItem($0) }))
                        .toggleStyle(.checkbox).font(.caption)
                    Spacer()
                    Button(model.busy ? "Refreshing…" : "Refresh") { model.refresh() }.disabled(model.busy)
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
            .padding(14)
            .frame(width: 500)
            .background(Color(nsColor: .windowBackgroundColor))   // opaque, so no terminal bleeds through
        }
    }
}

struct ProviderSection: View {
    @ObservedObject var model: Model
    let provider: String; let title: String; let accent: Color; let now: Date
    @State private var adding = false
    @State private var newName = ""
    var body: some View {
        let rows = model.rows(for: provider)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 8, height: 8)
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(rows.count) account\(rows.count == 1 ? "" : "s") · most headroom first").font(.caption2).foregroundStyle(.tertiary)
                Button(adding ? "cancel" : "add account…") { adding.toggle(); model.addResult = nil }.buttonStyle(.link).font(.caption2)
            }
            if adding {
                HStack(spacing: 6) {
                    TextField("short name, e.g. work", text: $newName).textFieldStyle(.roundedBorder).font(.caption)
                        .onSubmit { model.addAccount(provider, newName) }
                    Button("Create") { model.addAccount(provider, newName) }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let r = model.addResult, r.provider == provider {
                    Text(r.message).font(.caption2).foregroundStyle(r.command.isEmpty ? .red : .secondary)
                    if !r.command.isEmpty {
                        HStack(spacing: 8) {
                            Text(r.command).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Copy") { model.copyToClipboard(r.command) }.font(.caption2)
                            Button("Run in Terminal") { model.runInTerminal(r.command) }.font(.caption2)
                        }
                    }
                }
            }
            ForEach(rows) { r in RowView(row: r, now: now, makePrimary: { model.setPrimary(r) }) }
        }
    }
}

struct RowView: View {
    let row: Row; let now: Date; let makePrimary: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(usageColor(row.fiveH?.pct ?? row.week?.pct)).frame(width: 7, height: 7)
                Text(row.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let p = row.plan, !p.isEmpty { Tag(text: p) }
                if row.primary == true {
                    Tag(text: "primary", accent: true)
                } else if row.dir != nil {
                    Button("make primary", action: makePrimary).buttonStyle(.link).font(.caption2)
                        .help("Bare `\(row.provider)` opens this account next time; running sessions are unaffected")
                }
                if let lr = row.limitResets, let a = lr.available {
                    let usable = lr.usableNow ?? 0
                    Tag(text: "\(a) limit reset\(a == 1 ? "" : "s")" + (usable > 0 ? " · \(usable) usable now" : ""))
                }
                Spacer()
                if let n = row.note, !n.isEmpty {
                    Text(n).font(.caption2).foregroundStyle(n.contains("(out)") || n.contains("expired") ? .red : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if let ex = row.limitResets?.expires, !ex.isEmpty {
                Text("limit resets expire " + expiryList(ex, now: now)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            // a row with no windows at all is a failed fetch, not a plan without limits
            let missing = (row.fiveH == nil && row.week == nil) ? "no data" : "not tracked on this plan"
            HStack(alignment: .top, spacing: 14) {
                Bar(label: "5 hour", win: row.fiveH, now: now, missing: missing)
                Bar(label: "Weekly", win: row.week, now: now, missing: missing)
                if row.fable != nil { Bar(label: "Fable weekly", win: row.fable, now: now, missing: missing) }   // Max plans only
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct Tag: View {
    let text: String; var accent = false
    var body: some View {
        Text(text).font(.caption2.weight(accent ? .semibold : .regular)).padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(accent ? Color.accentColor : Color.primary)
            .background(Capsule().fill(accent ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.08)))
    }
}

struct Bar: View {
    let label: String; let win: Win?; let now: Date; var missing = "not tracked on this plan"
    var body: some View {
        let pct = win?.pct
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "n/a").font(.caption.monospacedDigit().weight(.semibold))
            }
            ProgressView(value: min(max(pct ?? 0, 0), 100), total: 100).tint(usageColor(pct))
            if let e = elapsed {
                // timeline of the window itself: how far along it is until the reset
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.secondary).frame(width: g.size.width * e)
                    }
                }.frame(height: 3)
            }
            Text(resetText).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    var elapsed: Double? {
        guard let r = win?.resetsEpoch, let w = win?.windowSeconds, w > 0 else { return nil }
        return min(max(1 - (r - now.timeIntervalSince1970) / w, 0), 1)
    }

    var resetText: String {
        guard win?.pct != nil else { return missing }
        guard let r = win?.resetsEpoch else { return "no reset time reported" }
        let date = Date(timeIntervalSince1970: r), rem = date.timeIntervalSince(now)
        if rem <= 0 { return "resets now" }
        let df = DateFormatter()
        df.dateFormat = rem > 86400 ? "EEE HH:mm" : "HH:mm"
        return "resets in \(countdown(rem)) · \(df.string(from: date))"
    }
}
