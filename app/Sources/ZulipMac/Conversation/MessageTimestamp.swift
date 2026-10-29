import Foundation

/// The time label of a message: only the time for today, "Yesterday" plus the time
/// for yesterday, and the date with weekday plus the time for anything older.
enum MessageTimestamp {
    static func format(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let base = Date.FormatStyle(
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        let time = date.formatted(base.hour().minute())

        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }
        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: now)
        ), calendar.isDate(date, inSameDayAs: yesterday) {
            return "\(yesterdayWord(calendar: calendar, locale: locale)) \(time)"
        }

        var dateStyle = base.month().day().weekday(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
            dateStyle = dateStyle.year()
        }
        return "\(date.formatted(dateStyle)) \(time)"
    }

    /// The short clock time beside a message, such as "12:05" (or "12:05 p" on a
    /// 12-hour system). Minutes always take two digits: with only the hour pinned
    /// to two digits, the formatter wrote 12:05 as "12:5".
    static func clockTime(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        date.formatted(clockStyle(calendar: calendar, locale: locale))
    }

    static func clockStyle(
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .hour(.twoDigits(amPM: .narrow))
            .minute(.twoDigits)
    }

    /// The date separator's label: "Today", "Yesterday", or the weekday and date.
    /// Days follow `calendar`, which is the system's calendar and time zone.
    static func dayLabel(
        for date: Date,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated)
            .month(.abbreviated)
            .day()
            .year()
        return date.formatted(style)
    }

    /// "Yesterday" in the user's language.
    private static func yesterdayWord(calendar: Calendar, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateTimeStyle = .named
        formatter.formattingContext = .beginningOfSentence
        return formatter.localizedString(from: DateComponents(day: -1))
    }
}
