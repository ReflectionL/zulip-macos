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
