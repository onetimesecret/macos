import XCTest

@testable import CompanionKit

/// A test's stand-in for the notification center: it keeps what it was asked to post.
@MainActor
private final class WarningRecorder: PageWarningPosting {
    struct Post: Equatable {
        let title: String
        let body: String
        let identifier: String
    }

    private(set) var posts: [Post] = []

    func post(title: String, body: String, identifier: String) {
        posts.append(Post(title: title, body: body, identifier: identifier))
    }
}

/// A test's answer to whether the app is frontmost, changeable mid-test.
@MainActor
private final class Frontmost {
    var isActive = false
}

/// The line for pages that expired while nobody was there, and the last-hour warning.
@MainActor
final class ExpiryNoticeTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    /// 2023-11-14 22:13:20 UTC.
    private let stamp: UInt64 = 1_700_000_000_000
    private let hour: UInt64 = 60 * 60 * 1_000

    private func page(_ title: String, at offsetMs: UInt64 = 0) -> ExpiredPage {
        ExpiredPage(title: title, atMs: stamp + offsetMs, createdAtMs: stamp)
    }

    // MARK: The sentence

    func testNoExpiredPageIsNoLine() {
        XCTAssertNil(ExpiryNotice.sentence(for: [], timeZone: utc))
    }

    func testOnePageIsNamedWithTheMinuteItWent() {
        XCTAssertEqual(
            ExpiryNotice.sentence(for: [page("payroll")], timeZone: utc),
            "\"payroll\" expired at 22:13.")
    }

    func testSeveralPagesAreCountedAndNamed() {
        XCTAssertEqual(
            ExpiryNotice.sentence(for: [page("a"), page("b")], timeZone: utc),
            "2 pages expired since you were last here: a, b.")
        XCTAssertEqual(
            ExpiryNotice.sentence(for: [page("a"), page("b"), page("c")], timeZone: utc),
            "3 pages expired since you were last here: a, b, c.")
    }

    func testPastThreeTitlesTheRestAreCounted() {
        let pages = ["a", "b", "c", "d", "e"].map { page($0) }
        XCTAssertEqual(
            ExpiryNotice.sentence(for: pages, timeZone: utc),
            "5 pages expired since you were last here: a, b, c and 2 more.")
    }

    func testAPageWithNoTitleUsesTheTabsPlaceholder() {
        XCTAssertEqual(ExpiryNotice.label(for: page("  "), timeZone: utc), "1114-2213")
        XCTAssertEqual(
            ExpiryNotice.sentence(for: [page("")], timeZone: utc),
            "\"1114-2213\" expired at 22:13.")
        XCTAssertEqual(
            ExpiryNotice.sentence(for: [page("a"), page("")], timeZone: utc),
            "2 pages expired since you were last here: a, 1114-2213.")
    }

    // MARK: The ledger's records of a time away

    private func entry(
        _ event: String, item: String, title: String, atMs: UInt64, createdAtMs: UInt64
    ) -> LedgerEntry {
        LedgerEntry(
            event: event, item: item, title: title, atMs: atMs, createdAtMs: createdAtMs,
            size: "small", destination: "none")
    }

    func testAPagesExpiryRecordsFoldIntoOnePageOldestFirst() {
        // Newest first, as the ledger reads: a page's own record sits above its objects'.
        let entries = [
            entry("expired", item: "page-2", title: "later", atMs: stamp + 9, createdAtMs: stamp + 2),
            entry("expired", item: "page-1", title: "payroll", atMs: stamp + 5, createdAtMs: stamp + 1),
            entry("expired", item: "chip-1", title: "payroll", atMs: stamp + 5, createdAtMs: stamp + 1),
            entry("sealed", item: "chip-1", title: "payroll", atMs: stamp + 3, createdAtMs: stamp + 1),
            entry("discarded", item: "page-0", title: "gone", atMs: stamp + 2, createdAtMs: stamp),
        ]
        XCTAssertEqual(
            ExpiryNotice.pages(expiredIn: entries),
            [
                ExpiredPage(title: "payroll", atMs: stamp + 5, createdAtMs: stamp + 1),
                ExpiredPage(title: "later", atMs: stamp + 9, createdAtMs: stamp + 2),
            ])
    }

    // MARK: Which pages warn

    private func clock(_ page: String, in remainingMs: UInt64) -> LastHourWarning.Clock {
        LastHourWarning.Clock(page: page, title: page, deadlineMs: stamp + remainingMs)
    }

    func testAPageInsideItsLastHourWarnsOnceWhileTheAppIsNotActive() {
        let inside = clock("a", in: hour - 1)
        let first = LastHourWarning.decide(
            clocks: [inside, clock("b", in: hour + 1)], nowMs: stamp, warned: [:], appActive: false)
        XCTAssertEqual(first.post, [inside])
        XCTAssertEqual(first.warned, ["a": inside.deadlineMs])

        // A later reading of the same deadline, a few seconds and a few milliseconds on.
        let later = LastHourWarning.Clock(page: "a", title: "a", deadlineMs: inside.deadlineMs + 7)
        let second = LastHourWarning.decide(
            clocks: [later], nowMs: stamp + 5_000, warned: first.warned, appActive: false)
        XCTAssertEqual(second.post, [])
        XCTAssertEqual(second.warned, first.warned)
    }

    func testAPageThatEntersWhileTheAppIsActiveIsNoticedAndNotPosted() {
        let inside = clock("a", in: hour / 2)
        let active = LastHourWarning.decide(
            clocks: [inside], nowMs: stamp, warned: [:], appActive: true)
        XCTAssertEqual(active.post, [])
        XCTAssertEqual(active.warned, ["a": inside.deadlineMs])
        let away = LastHourWarning.decide(
            clocks: [inside], nowMs: stamp + 1_000, warned: active.warned, appActive: false)
        XCTAssertEqual(away.post, [])
    }

    func testANewDeadlineWarnsAgain() {
        let inside = clock("a", in: hour / 2)
        let warned = ["a": inside.deadlineMs]

        // Restarted: outside the hour, so the record goes, and it warns on the way back in.
        let restarted = LastHourWarning.decide(
            clocks: [clock("a", in: 3 * hour)], nowMs: stamp, warned: warned, appActive: false)
        XCTAssertEqual(restarted.post, [])
        XCTAssertEqual(restarted.warned, [:])
        let back = clock("a", in: 3 * hour)
        XCTAssertEqual(
            LastHourWarning.decide(
                clocks: [back], nowMs: stamp + 2 * hour + 1, warned: restarted.warned,
                appActive: false
            ).post, [back])

        // Shortened inside the hour: a different deadline, so a second warning.
        let shortened = clock("a", in: hour / 4)
        XCTAssertEqual(
            LastHourWarning.decide(
                clocks: [shortened], nowMs: stamp, warned: warned, appActive: false
            ).post, [shortened])
    }

    func testAPageAtOrPastItsDeadlineDoesNotWarn() {
        let due = LastHourWarning.Clock(page: "a", title: "a", deadlineMs: stamp)
        let decision = LastHourWarning.decide(
            clocks: [due], nowMs: stamp, warned: [:], appActive: false)
        XCTAssertEqual(decision.post, [])
        XCTAssertEqual(decision.warned, [:])
    }

    func testTheNextEntryIsTheSoonestPageStillOutsideItsLastHour() {
        XCTAssertNil(LastHourWarning.msUntilNextEntry(clocks: [clock("a", in: hour)], nowMs: stamp))
        XCTAssertEqual(
            LastHourWarning.msUntilNextEntry(
                clocks: [clock("a", in: hour / 2), clock("b", in: 3 * hour), clock("c", in: 2 * hour)],
                nowMs: stamp),
            hour)
    }

    func testTheOneTimerTakesTheSoonerOfTheCoresEventAndALastHourEntry() {
        XCTAssertNil(PageModel.eventTimerFire(coreMs: -1, lastHourMs: nil))
        let coreOnly = PageModel.eventTimerFire(coreMs: 500, lastHourMs: nil)
        XCTAssertEqual(coreOnly?.ms, 500)
        XCTAssertEqual(coreOnly?.settles, true)
        let entryOnly = PageModel.eventTimerFire(coreMs: -1, lastHourMs: 40)
        XCTAssertEqual(entryOnly?.ms, 40)
        XCTAssertEqual(entryOnly?.settles, false)
        let entryFirst = PageModel.eventTimerFire(coreMs: 500, lastHourMs: 40)
        XCTAssertEqual(entryFirst?.ms, 40)
        XCTAssertEqual(entryFirst?.settles, false)
        let tie = PageModel.eventTimerFire(coreMs: 40, lastHourMs: 40)
        XCTAssertEqual(tie?.settles, true)
    }

    func testTheWarningBodyNamesNoPage() {
        XCTAssertEqual(LastHourWarning.body, "A page expires in under an hour.")
    }

    // MARK: The model

    private func makeModel(
        warnings: (any PageWarningPosting)? = nil, frontmost: Frontmost? = nil
    ) throws -> PageModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("expiry-notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "expiry-notice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var isActive: (@MainActor () -> Bool)?
        if let frontmost { isActive = { frontmost.isActive } }
        let model = PageModel(
            formFactor: .panel, defaults: defaults,
            seams: .init(
                stateDirectory: directory, client: .ephemeral(tag: suite), saveDebounce: 3_600,
                saveRetryDebounce: 3_600, pageWarnings: warnings,
                applicationIsActive: isActive))
        model.loadStateIfNeeded()
        return model
    }

    private func seed(_ text: String, in model: PageModel) throws -> TabSummary {
        let tab = try XCTUnwrap(model.selectedTab)
        let page = try XCTUnwrap(tab.pageID)
        model.applyOps(
            sheet: page,
            opsJSON: try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: text)])))
        return try XCTUnwrap(model.tabs.first { $0.id == tab.id })
    }

    private func expireEverything(in model: PageModel) {
        XCTAssertTrue(model.coreClient.ageForTests(byMs: 31 * 24 * 60 * 60 * 1_000))
        model.settleCoreEvent()
    }

    func testASettledExpiryStandsUntilDismissed() throws {
        let model = try makeModel()
        XCTAssertNil(model.expiredWhileAwaySentence, "a first launch has nothing to report")
        let tab = try seed("payroll notes", in: model)

        expireEverything(in: model)

        XCTAssertEqual(model.expiredWhileAway.map(\.title), [tab.title])
        XCTAssertNotNil(model.expiredWhileAwaySentence)
        // A refresh is all that raising or activating the surface asks of the model.
        model.refresh()
        XCTAssertEqual(model.expiredWhileAway.count, 1)

        model.dismissExpiredWhileAway()
        XCTAssertEqual(model.expiredWhileAway, [])
        XCTAssertNil(model.expiredWhileAwaySentence)
    }

    func testAnEmptyPagesExpiryIsNotReported() throws {
        let model = try makeModel()
        XCTAssertNotNil(model.selectedPageID)
        expireEverything(in: model)
        XCTAssertTrue(model.tabs.allSatisfy { !$0.hasPage })
        XCTAssertEqual(model.expiredWhileAway, [])
    }

    func testTypingInAPageClearsTheLine() throws {
        let model = try makeModel()
        _ = try seed("payroll notes", in: model)
        expireEverything(in: model)
        XCTAssertTrue(model.perform(.pageNew))
        XCTAssertEqual(model.expiredWhileAway.count, 1, "a new page is not typing")

        _ = try seed("seen", in: model)
        XCTAssertEqual(model.expiredWhileAway, [])
    }

    func testAPageEnteringItsLastHourPostsOneWarningWhileTheAppIsNotActive() throws {
        let recorder = WarningRecorder()
        let model = try makeModel(warnings: recorder, frontmost: Frontmost())
        let tab = try seed("payroll notes", in: model)
        XCTAssertGreaterThan(tab.remainingMs, hour)
        XCTAssertEqual(recorder.posts, [])

        XCTAssertTrue(model.coreClient.ageForTests(byMs: tab.remainingMs - hour / 2))
        model.refresh()
        XCTAssertEqual(recorder.posts.map(\.title), ["OnetimePad"])
        XCTAssertEqual(recorder.posts.map(\.body), ["A page expires in under an hour."])

        model.refresh()
        XCTAssertEqual(recorder.posts.count, 1, "one warning per page per deadline")
    }

    func testAPageEnteringItsLastHourWhileTheAppIsActivePostsNothing() throws {
        let recorder = WarningRecorder()
        let frontmost = Frontmost()
        frontmost.isActive = true
        let model = try makeModel(warnings: recorder, frontmost: frontmost)
        let tab = try seed("payroll notes", in: model)

        XCTAssertTrue(model.coreClient.ageForTests(byMs: tab.remainingMs - hour / 2))
        model.refresh()
        frontmost.isActive = false
        model.refresh()
        XCTAssertEqual(recorder.posts, [])
    }
}
