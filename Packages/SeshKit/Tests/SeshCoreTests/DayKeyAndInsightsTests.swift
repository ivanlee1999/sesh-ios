import XCTest
@testable import SeshCore

final class DayKeyTests: XCTestCase {
    let la = TimeZone(identifier: "America/Los_Angeles")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    func testKeyIsTheViewersDayNotTheServers() {
        // 2023-11-14T22:13:20Z — already the 15th in Tokyo, still the 14th in LA.
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DayKey.key(for: instant, timeZone: la), "2023-11-14")
        XCTAssertEqual(DayKey.key(for: instant, timeZone: tokyo), "2023-11-15")
    }

    func testDayArithmeticCrossesMonthsAndYears() {
        XCTAssertEqual(DayKey.next("2024-02-28"), "2024-02-29")   // a leap year
        XCTAssertEqual(DayKey.next("2023-02-28"), "2023-03-01")
        XCTAssertEqual(DayKey.next("2023-12-31"), "2024-01-01")
        XCTAssertEqual(DayKey.previous("2024-01-01"), "2023-12-31")
        XCTAssertEqual(DayKey.previous("2024-03-01"), "2024-02-29")
    }

    func testDayArithmeticIsUnmovedByDaylightSaving() {
        // Spring forward in the US: 2024-03-10 is 23 hours long. Adding a day
        // in wall-clock terms would land back on the same date.
        XCTAssertEqual(DayKey.next("2024-03-10"), "2024-03-11")
        XCTAssertEqual(DayKey.next("2024-11-03"), "2024-11-04")
    }

    func testStartOfDayMillisSurvivesASpringForward() {
        // 00:00 does exist on that date in LA; 02:00 does not. The point is that
        // midnight is asked for, not constructed.
        let start = DayKey.startOfDayMillis("2024-03-10", timeZone: la)
        XCTAssertEqual(DayKey.key(for: Date(timeIntervalSince1970: Double(start) / 1000), timeZone: la), "2024-03-10")
        XCTAssertEqual(DayKey.key(for: Date(timeIntervalSince1970: Double(start - 1) / 1000), timeZone: la), "2024-03-09")
    }

    func testStartOfDayUtcSecondsMatchesThingsEncoding() {
        // Things stores a scheduled day as UTC midnight in whole seconds.
        XCTAssertEqual(DayKey.startOfDayUtcSeconds("2024-01-01"), 1_704_067_200)
        XCTAssertEqual(DayKey.startOfDayUtcSeconds("2024-01-01") % 86_400, 0)
    }

    func testOverdueCountsAsToday() {
        let clock = DayClock(today: "2024-05-10", tomorrow: "2024-05-11")
        XCTAssertEqual(DayKey.dueKind("2024-05-01", clock: clock), .today)
        XCTAssertEqual(DayKey.dueKind("2024-05-10", clock: clock), .today)
        XCTAssertEqual(DayKey.dueKind("2024-05-11", clock: clock), .tomorrow)
        XCTAssertEqual(DayKey.dueKind("2024-05-12", clock: clock), .upcoming)
        XCTAssertNil(DayKey.dueKind(nil, clock: clock))
        XCTAssertNil(DayKey.dueKind("", clock: clock))
    }

    func testDueKindAcceptsAFullTimestamp() {
        let clock = DayClock(today: "2024-05-10", tomorrow: "2024-05-11")
        XCTAssertEqual(DayKey.dueKind("2024-05-11T09:00:00Z", clock: clock), .tomorrow)
    }

    func testDueLabelFallsBackToSomethingReadable() {
        let clock = DayClock(today: "2024-05-10", tomorrow: "2024-05-11")
        XCTAssertEqual(DayKey.dueLabel("2024-05-10", clock: clock), "Today")
        XCTAssertEqual(DayKey.dueLabel("2024-05-11", clock: clock), "Tomorrow")
        XCTAssertEqual(DayKey.dueLabel("2024-06-01", fallback: "next month", clock: clock), "next month")
        XCTAssertEqual(DayKey.dueLabel("2024-06-01", clock: clock), "2024-06-01")
    }

    func testLabelReadsAsADate() {
        XCTAssertEqual(DayKey.label("2026-09-02"), "Wed, Sep 2")
    }

    func testClockKnowsTomorrow() {
        let clock = DayClock(now: Date(timeIntervalSince1970: 1_700_000_000), timeZone: la)
        XCTAssertEqual(clock.today, "2023-11-14")
        XCTAssertEqual(clock.tomorrow, "2023-11-15")
    }
}

final class InsightsTests: XCTestCase {
    let la = TimeZone(identifier: "America/Los_Angeles")!

    /// A focus session starting at local noon on `key`.
    private func session(_ key: String, minutes: Int = 25, category: String = "deep", kind: SessionKind = .focus) -> Session {
        let start = DayKey.startOfDayMillis(key, timeZone: la) + 12 * 3_600_000
        return Session(
            id: "manual-\(start)-\(category)-\(minutes)",
            category: category,
            type: kind,
            targetMs: 25 * 60_000,
            actualMs: minutes * 60_000,
            startedAt: start,
            endedAt: start + Millis(minutes * 60_000)
        )
    }

    private func now(_ key: String) -> Date {
        Date(timeIntervalSince1970: Double(DayKey.startOfDayMillis(key, timeZone: la) + 20 * 3_600_000) / 1000)
    }

    func testTodayCountsOnlyTodaysFocus() {
        let insights = Insights.compute(
            sessions: [session("2024-05-10", minutes: 25), session("2024-05-10", minutes: 15), session("2024-05-09")],
            now: now("2024-05-10"), timeZone: la
        )
        XCTAssertEqual(insights.todayCount, 2)
        XCTAssertEqual(insights.todayMs, 40 * 60_000)
    }

    func testBreaksAreNotFocus() {
        let insights = Insights.compute(
            sessions: [session("2024-05-10", minutes: 25), session("2024-05-10", minutes: 5, kind: .rest)],
            now: now("2024-05-10"), timeZone: la
        )
        XCTAssertEqual(insights.todayCount, 1)
        XCTAssertEqual(insights.todayMs, 25 * 60_000)
    }

    func testStreakCountsConsecutiveDays() {
        let insights = Insights.compute(
            sessions: ["2024-05-10", "2024-05-09", "2024-05-08"].map { session($0) },
            now: now("2024-05-10"), timeZone: la
        )
        XCTAssertEqual(insights.streak, 3)
    }

    func testStreakStopsAtTheFirstEmptyDay() {
        let insights = Insights.compute(
            sessions: ["2024-05-10", "2024-05-09", "2024-05-07"].map { session($0) },
            now: now("2024-05-10"), timeZone: la
        )
        XCTAssertEqual(insights.streak, 2)
    }

    func testAnEmptyTodayDoesNotEndYesterdaysStreak() {
        // The day is not over. Collapsing the streak every morning before the
        // first session would be both wrong and dispiriting.
        let insights = Insights.compute(
            sessions: ["2024-05-09", "2024-05-08"].map { session($0) },
            now: now("2024-05-10"), timeZone: la
        )
        XCTAssertEqual(insights.streak, 2)
    }

    func testStreakSurvivesADaylightSavingBoundary() {
        // 2024-03-10 is a 23-hour day in Los Angeles.
        let insights = Insights.compute(
            sessions: ["2024-03-11", "2024-03-10", "2024-03-09"].map { session($0) },
            now: now("2024-03-11"), timeZone: la
        )
        XCTAssertEqual(insights.streak, 3)
    }

    func testDaysRunOldestToNewestEndingToday() {
        let insights = Insights.compute(
            sessions: [session("2024-05-10"), session("2024-05-08")],
            now: now("2024-05-10"), timeZone: la, dayCount: 7
        )
        XCTAssertEqual(insights.days.count, 7)
        XCTAssertEqual(insights.days.last?.key, "2024-05-10")
        XCTAssertEqual(insights.days.first?.key, "2024-05-04")
        XCTAssertEqual(insights.days.last?.ms, 25 * 60_000)
        XCTAssertEqual(insights.days.first?.ms, 0)
        XCTAssertEqual(insights.days.last?.label, "Fri")
    }

    func testCategoriesAreRankedByTimeSpent() {
        let insights = Insights.compute(
            sessions: [
                session("2024-05-10", minutes: 50, category: "deep"),
                session("2024-05-10", minutes: 25, category: "writing"),
                session("2024-05-09", minutes: 25, category: "writing"),
            ],
            now: now("2024-05-10"), timeZone: la
        )
        XCTAssertEqual(insights.categories.map(\.category), ["deep", "writing"])
        XCTAssertEqual(insights.categories.first?.share ?? 0, 0.5, accuracy: 0.001)
    }

    func testPlanAccuracyComparesActualAgainstTarget() {
        let insights = Insights.compute(
            sessions: [session("2024-05-10", minutes: 30)],   // 30 done against a 25 target
            now: now("2024-05-10"), timeZone: la
        )
        XCTAssertEqual(insights.planAccuracy ?? 0, 30.0 / 25.0, accuracy: 0.001)
    }

    func testNothingRecordedIsNotAnError() {
        let insights = Insights.compute(sessions: [], now: now("2024-05-10"), timeZone: la)
        XCTAssertEqual(insights.todayMs, 0)
        XCTAssertEqual(insights.streak, 0)
        XCTAssertEqual(insights.days.count, 7)
        XCTAssertNil(insights.planAccuracy)
        XCTAssertTrue(insights.categories.isEmpty)
    }
}

final class TaskRefTests: XCTestCase {
    func testTodoistIdsStayBareAndOthersAreNamespaced() {
        XCTAssertEqual(TaskRef(provider: .todoist, id: "123").encoded, "123")
        XCTAssertEqual(TaskRef(provider: .things, id: "abc").encoded, "things:abc")
    }

    func testABareIdIsTodoist() {
        XCTAssertEqual(TaskRef.decode("123"), TaskRef(provider: .todoist, id: "123"))
    }

    func testAnUnknownPrefixIsNotMistakenForAProvider() {
        // A Todoist id containing a colon must not be read as a namespace.
        XCTAssertEqual(TaskRef.decode("weird:id"), TaskRef(provider: .todoist, id: "weird:id"))
    }

    func testListsRoundTrip() {
        let encoded = TaskRef.encodeList(["123", "things:abc"])
        XCTAssertEqual(encoded, "123,things:abc")
        XCTAssertEqual(TaskRef.decodeList(encoded), [
            TaskRef(provider: .todoist, id: "123"),
            TaskRef(provider: .things, id: "abc"),
        ])
    }

    func testASingleRefEncodesToExactlyWhatItAlwaysWas() {
        // Which is why existing rows keep working untouched.
        XCTAssertEqual(TaskRef.encodeList(["123"]), "123")
    }

    func testEmptinessIsNil() {
        XCTAssertNil(TaskRef.encodeList([]))
        XCTAssertNil(TaskRef.encodeList(["", "  "]))
        XCTAssertNil(TaskRef.decode(nil))
        XCTAssertTrue(TaskRef.decodeList(nil).isEmpty)
    }

    func testSessionExposesItsRefs() {
        let session = Session(id: "manual-1", category: "deep", startedAt: 1, endedAt: 2, todoistTaskId: "123,things:abc")
        XCTAssertEqual(session.taskRefs.map(\.provider), [.todoist, .things])
    }
}
