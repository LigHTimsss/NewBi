import Foundation

enum VideoPublication {
    static func text(_ timestamp: Int?, now: Date = .now, timeZone: TimeZone = .current) -> String? {
        guard let timestamp, timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(timestamp))
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 0 else { return nil }
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))小时前" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let short = String(format: "%02d-%02d", month, day)
        return year == calendar.component(.year, from: now) ? short : "\(year)-\(short)"
    }
}
