import Foundation
import UserNotifications

/// A page that expired while nobody was attending to the surface: the label its tab
/// showed, which is what the ledger stores, and never its content.
public struct ExpiredPage: Equatable, Sendable {
    public let title: String
    /// When the expiry was settled, Unix epoch milliseconds.
    public let atMs: UInt64
    /// The page's creation stamp, the source of the placeholder when no title was recorded.
    public let createdAtMs: UInt64

    public init(title: String, atMs: UInt64, createdAtMs: UInt64) {
        self.title = title
        self.atMs = atMs
        self.createdAtMs = createdAtMs
    }
}

/// The standing line that says which pages expired since the surface was last attended.
public enum ExpiryNotice {
    /// How many titles the plural sentence spells out before it counts the rest.
    static let titlesShown = 3

    /// The line for `pages`, or nil when there is nothing to say.
    public static func sentence(for pages: [ExpiredPage], timeZone: TimeZone = .current) -> String? {
        guard let first = pages.first else { return nil }
        let titles = pages.map { label(for: $0, timeZone: timeZone) }
        if pages.count == 1 {
            return CompanionL10n.format(
                "expiry.away.one", titles[0], stamp(first.atMs, format: "HH:mm", timeZone: timeZone))
        }
        let shown = titles.prefix(titlesShown).joined(separator: ", ")
        let rest = titles.count - titlesShown
        if rest > 0 {
            return CompanionL10n.format("expiry.away.more", pages.count, shown, rest)
        }
        return CompanionL10n.format("expiry.away.many", pages.count, shown)
    }

    /// The page's title, or the "MMDD-HHmm" placeholder a tab shows when nothing was typed.
    static func label(for page: ExpiredPage, timeZone: TimeZone = .current) -> String {
        let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? stamp(page.createdAtMs, format: "MMdd-HHmm", timeZone: timeZone) : title
    }

    /// The pages among a ledger's expiry records, oldest first. A page's own record and
    /// its sealed objects' records share one title and one creation stamp, so they fold.
    public static func pages(expiredIn entries: [LedgerEntry]) -> [ExpiredPage] {
        var seen: Set<String> = []
        var pages: [ExpiredPage] = []
        for entry in entries.reversed() where entry.event == "expired" {
            guard seen.insert("\(entry.createdAtMs)-\(entry.title)").inserted else { continue }
            pages.append(
                ExpiredPage(title: entry.title, atMs: entry.atMs, createdAtMs: entry.createdAtMs))
        }
        return pages
    }

    private static func stamp(_ ms: UInt64, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

/// Which pages are owed a last-hour warning, decided without a clock or a notification center.
public enum LastHourWarning {
    /// One running page with content, by its stable identity and its wall-clock deadline.
    public struct Clock: Equatable, Sendable {
        public let page: String
        public let title: String
        public let deadlineMs: UInt64

        public init(page: String, title: String, deadlineMs: UInt64) {
            self.page = page
            self.title = title
            self.deadlineMs = deadlineMs
        }
    }

    public struct Decision: Equatable, Sendable {
        /// The pages to warn about now.
        public let post: [Clock]
        /// Each page inside its last hour, with the deadline it was noticed at.
        public let warned: [String: UInt64]
    }

    static let hourMs: UInt64 = 60 * 60 * 1_000
    /// Two readings of one deadline differ by the time between the readings' clock calls.
    static let sameDeadlineMs: UInt64 = 60 * 1_000

    /// A page inside its last hour is noticed once per deadline. Noticed while the app is
    /// active, it is recorded and not posted: the tab's gauge is in front of the person.
    public static func decide(
        clocks: [Clock], nowMs: UInt64, warned: [String: UInt64], appActive: Bool
    ) -> Decision {
        var post: [Clock] = []
        var noticed: [String: UInt64] = [:]
        for clock in clocks where clock.deadlineMs > nowMs && clock.deadlineMs - nowMs <= hourMs {
            if let earlier = warned[clock.page], isSameDeadline(earlier, clock.deadlineMs) {
                noticed[clock.page] = earlier
                continue
            }
            noticed[clock.page] = clock.deadlineMs
            if !appActive { post.append(clock) }
        }
        return Decision(post: post, warned: noticed)
    }

    /// Milliseconds until the next page crosses into its last hour, or nil when none will.
    public static func msUntilNextEntry(clocks: [Clock], nowMs: UInt64) -> UInt64? {
        clocks.compactMap { clock -> UInt64? in
            guard clock.deadlineMs > nowMs, clock.deadlineMs - nowMs > hourMs else { return nil }
            return clock.deadlineMs - nowMs - hourMs
        }.min()
    }

    /// The notification's body for `title`.
    public static func body(title: String) -> String {
        CompanionL10n.format("expiry.warning.body", title)
    }

    private static func isSameDeadline(_ a: UInt64, _ b: UInt64) -> Bool {
        (a > b ? a - b : b - a) <= sameDeadlineMs
    }
}

/// Where a last-hour warning goes: the system's notification center, or a test's recorder.
@MainActor
public protocol PageWarningPosting: AnyObject {
    func post(title: String, body: String, identifier: String)
}

/// The shipping route: a local notification under provisional authorization, which the
/// system grants without a dialog and delivers quietly to Notification Center.
@MainActor
final class SystemPageWarnings: PageWarningPosting {
    func post(title: String, body: String, identifier: String) {
        Self.deliver(title: title, body: body, identifier: identifier)
    }

    /// Nonisolated so the center's completion handler, which arrives off the main thread,
    /// is not formed inside the main actor.
    private nonisolated static func deliver(title: String, body: String, identifier: String) {
        // The center traps in a process with no bundle identifier, such as a bare executable.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .provisional]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}
