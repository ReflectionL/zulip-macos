import Foundation
import Testing
import ZulipCoreBindings
@testable import ZulipMac

@Suite("Message time labels")
struct MessageTimestampTests {
    private let locale = Locale(identifier: "en_GB")

    private func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.locale = locale
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        in calendar: Calendar
    ) throws -> Date {
        try #require(
            calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            )
        )
    }

    @Test("Today shows only the time")
    func today() throws {
        let calendar = try calendar()
        let now = try date(2026, 10, 12, 15, 0, in: calendar)
        let sent = try date(2026, 10, 12, 9, 30, in: calendar)
        #expect(MessageTimestamp.format(sent, now: now, calendar: calendar, locale: locale) == "09:30")
    }

    @Test("Yesterday is named, with the time")
    func yesterday() throws {
        let calendar = try calendar()
        let now = try date(2026, 10, 12, 0, 20, in: calendar)
        let sent = try date(2026, 10, 11, 23, 45, in: calendar)
        let text = MessageTimestamp.format(sent, now: now, calendar: calendar, locale: locale)
        #expect(text.lowercased().hasPrefix("yesterday"))
        #expect(text.hasSuffix(" 23:45"))
    }

    @Test("Date separators name today and yesterday from the given moment")
    func dayLabels() throws {
        let calendar = try calendar()
        let sent = try date(2026, 10, 13, 22, 0, in: calendar)
        let sameEvening = try date(2026, 10, 13, 23, 30, in: calendar)
        let nextMorning = try date(2026, 10, 14, 0, 10, in: calendar)
        let twoDaysLater = try date(2026, 10, 15, 9, 0, in: calendar)
        func label(at now: Date) -> String {
            MessageTimestamp.dayLabel(for: sent, now: now, calendar: calendar, locale: locale)
        }
        #expect(label(at: sameEvening) == "Today")
        #expect(label(at: nextMorning) == "Yesterday")
        #expect(label(at: twoDaysLater).contains("13"))
    }

    @Test("Days follow the calendar's time zone, not UTC")
    func dayLabelsUseTheTimeZone() throws {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        shanghai.locale = locale
        // 01:00 on 14 October in Shanghai is still 13 October in UTC.
        let sent = try date(2026, 10, 14, 1, 0, in: shanghai)
        let now = try date(2026, 10, 14, 20, 0, in: shanghai)
        #expect(MessageTimestamp.dayLabel(for: sent, now: now, calendar: shanghai, locale: locale) == "Today")
    }

    @Test("Earlier days show the date, the weekday and the time")
    func earlier() throws {
        let calendar = try calendar()
        let now = try date(2026, 10, 12, 15, 0, in: calendar)
        let sent = try date(2026, 10, 8, 9, 30, in: calendar)
        let text = MessageTimestamp.format(sent, now: now, calendar: calendar, locale: locale)
        #expect(text.contains("Thu"))
        #expect(text.contains("8"))
        #expect(text.hasSuffix(" 09:30"))
        #expect(!text.contains("2026"))
    }

    @Test("A date from another year includes the year")
    func otherYear() throws {
        let calendar = try calendar()
        let now = try date(2026, 10, 12, 15, 0, in: calendar)
        let sent = try date(2025, 3, 3, 9, 30, in: calendar)
        let text = MessageTimestamp.format(sent, now: now, calendar: calendar, locale: locale)
        #expect(text.contains("2025"))
        #expect(text.hasSuffix(" 09:30"))
    }
}

@Suite("Local echo")
struct LocalEchoTests {
    @Test("Plain sentences are shown as typed")
    func plain() {
        for text in ["Sounds good, thanks!", "see you at 5", "Meet at 10:30 or 11:45", "100% sure"] {
            #expect(!LocalEcho.needsServerRendering(text), "\(text)")
        }
    }

    @Test("Markdown, links, mentions, emoji and line breaks wait for the server")
    func rich() {
        let samples = [
            "# Title",
            "some **bold** text",
            "line one\nline two",
            "- item",
            "1. step",
            "see https://example.com",
            "nice :smile:",
            "run `make`",
            "@**Theo Martin** hi",
            "> quoted",
            "```quote\nhi\n```",
        ]
        for text in samples {
            #expect(LocalEcho.needsServerRendering(text), "\(text)")
        }
    }
}

@Suite("Text size")
@MainActor
struct InterfaceScaleTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "InterfaceScaleTests-\(UUID().uuidString)"))
    }

    @Test("Steps move through the sizes, stop at the ends, and are remembered")
    func steps() throws {
        let store = try defaults()
        let scale = InterfaceScale(defaults: store)
        #expect(scale.factor == 1.0)
        #expect(scale.isStandard)

        scale.increase()
        #expect(scale.factor == 1.1)
        #expect(!scale.isStandard)
        #expect(InterfaceScale(defaults: store).factor == 1.1)

        scale.decrease()
        scale.decrease()
        #expect(scale.factor == 0.9)

        for _ in 0..<20 {
            scale.decrease()
        }
        #expect(scale.factor == InterfaceScale.steps.first)
        #expect(!scale.canDecrease)

        for _ in 0..<20 {
            scale.increase()
        }
        #expect(scale.factor == InterfaceScale.steps.last)
        #expect(!scale.canIncrease)

        scale.reset()
        #expect(scale.factor == 1.0)
    }

    @Test("A stored value between steps snaps to the nearest one")
    func snaps() throws {
        let store = try defaults()
        store.set(1.27, forKey: "interfaceScale")
        #expect(InterfaceScale(defaults: store).factor == 1.25)
    }
}

@Suite("Presence wording")
struct PresenceDescriptionTests {
    private let locale = Locale(identifier: "en_GB")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Online states read plainly")
    func states() {
        #expect(PresenceDescription.text(state: .active, lastActive: nil, now: now, locale: locale) == "Active now")
        #expect(PresenceDescription.text(state: .idle, lastActive: nil, now: now, locale: locale) == "Idle")
        #expect(PresenceDescription.text(state: .offline, lastActive: nil, now: now, locale: locale) == "Offline")
    }

    @Test("An offline person shows how long ago they were last active")
    func lastActive() {
        let recent = PresenceDescription.text(
            state: .offline,
            lastActive: now.addingTimeInterval(-30),
            now: now,
            locale: locale
        )
        #expect(recent == "Active just now")

        let hours = PresenceDescription.text(
            state: .offline,
            lastActive: now.addingTimeInterval(-3 * 3_600),
            now: now,
            locale: locale
        )
        #expect(hours.hasPrefix("Active "))
        #expect(hours.contains("3"))
    }
}

@Suite("Topic names")
struct TopicNameTests {
    @Test("A channel's default topic is called general chat")
    func generalChat() {
        #expect(TopicName.display("") == "general chat")
        #expect(TopicName.display("release") == "release")
    }
}

@Suite("Message density")
@MainActor
struct MessageDensityTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "MessageDensityTests-\(UUID().uuidString)"))
    }

    @Test("Normal is the default, the choice is remembered, and unknown values fall back")
    func remembersTheChoice() throws {
        let store = try defaults()
        let preference = MessageDensityPreference(defaults: store)
        #expect(preference.density == .normal)

        preference.select(.compact)
        #expect(preference.density == .compact)
        #expect(MessageDensityPreference(defaults: store).density == .compact)

        store.set("roomy", forKey: "messageDensity")
        #expect(MessageDensityPreference(defaults: store).density == .normal)
    }

    @Test("Compact leaves less space around a message than normal and normal keeps the old metrics")
    func compactIsTighter() {
        #expect(MessageDensity.normal.continuationInset == 4)
        #expect(MessageDensity.normal.blockTopInset == 14)
        #expect(MessageDensity.normal.blockBottomInset == 4)
        #expect(MessageDensity.compact.continuationInset < MessageDensity.normal.continuationInset)
        #expect(MessageDensity.compact.blockTopInset < MessageDensity.normal.blockTopInset)
        #expect(MessageDensity.compact.blockBottomInset < MessageDensity.normal.blockBottomInset)
    }
}
