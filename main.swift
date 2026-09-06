// LimitsBar: menu bar view of 5h / weekly / Fable usage across all Claude Code and Codex
// accounts, with reset countdowns. Data comes from ~/.local/bin/limits --json (the same
// profiles the CLIs use). Build with ./build.sh; it produces ~/Applications/LimitsBar.app.
import SwiftUI
import AppKit

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
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Menu bar text: lowest 5h usage per provider, i.e. the account with the most headroom.
    var title: String {
        func best(_ p: String) -> String {
            let v = rows.filter { $0.provider == p }.compactMap { $0.fiveH?.pct }.min()
            return v.map { "\(Int($0.rounded()))%" } ?? "–"
        }
        return "C \(best("claude")) · X \(best("codex"))"
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
                ProviderSection(title: "Claude", accent: .orange, rows: model.rows(for: "claude"), now: ctx.date, makePrimary: model.setPrimary)
                ProviderSection(title: "Codex", accent: .teal, rows: model.rows(for: "codex"), now: ctx.date, makePrimary: model.setPrimary)
                if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red) }
                if model.rows.isEmpty && model.error.isEmpty {
                    Text(model.busy ? "Loading…" : "No accounts found").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text("Updated \(model.updated) · refreshes every 5 min").font(.caption2).foregroundStyle(.secondary)
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
    let title: String; let accent: Color; let rows: [Row]; let now: Date; let makePrimary: (Row) -> Void
    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 8, height: 8)
                    Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(rows.count) account\(rows.count == 1 ? "" : "s") · most headroom first")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(rows) { r in RowView(row: r, now: now, makePrimary: { makePrimary(r) }) }
            }
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
            HStack(alignment: .top, spacing: 14) {
                Bar(label: "5 hour", win: row.fiveH, now: now)
                Bar(label: "Weekly", win: row.week, now: now)
                if row.fable != nil { Bar(label: "Fable weekly", win: row.fable, now: now) }   // Max plans only
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
    let label: String; let win: Win?; let now: Date
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
        guard win?.pct != nil else { return "not tracked on this plan" }
        guard let r = win?.resetsEpoch else { return "no reset time reported" }
        let date = Date(timeIntervalSince1970: r), rem = date.timeIntervalSince(now)
        if rem <= 0 { return "resets now" }
        let df = DateFormatter()
        df.dateFormat = rem > 86400 ? "EEE HH:mm" : "HH:mm"
        return "resets in \(countdown(rem)) · \(df.string(from: date))"
    }
}
