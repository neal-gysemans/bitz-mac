import CryptoKit
import Foundation
import os

/// Shared helper for parsing transcript timestamps, quota / HTTP 429 error signals,
/// and rate-limit reset dates across agent adapters.
enum RateLimitParser {
    /// Fixed-size SHA-256 digest for deduplication keys so no raw transcript text is retained in memory.
    static func dedupDigest(_ parts: [String]) -> Data {
        var hasher = SHA256()
        for part in parts {
            let bytes = Data(part.utf8)
            var len = UInt64(bytes.count).littleEndian
            withUnsafeBytes(of: &len) { hasher.update(bufferPointer: $0) }
            hasher.update(data: bytes)
        }
        return Data(hasher.finalize())
    }
    private struct Formatters: @unchecked Sendable {
        let isoFractional: ISO8601DateFormatter
        let isoBasic: ISO8601DateFormatter
        let isoDateInTextRegex: NSRegularExpression
        let quota429Regex: NSRegularExpression
        let textDelayPhraseRegex: NSRegularExpression
        let retryDelayKeyRegex: NSRegularExpression
        let durationComponentRegex: NSRegularExpression
        let standaloneDurationRegex: NSRegularExpression
    }

    private static let formatterLock: OSAllocatedUnfairLock<Formatters> = {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        // swiftlint:disable force_try
        let isoDateInTextRegex = try! NSRegularExpression(
            pattern: #"\b20\d{2}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\b"#
        )
        let quota429Regex = try! NSRegularExpression(pattern: #"\b429\b"#)
        let textDelayPhraseRegex = try! NSRegularExpression(
            pattern: #"(?:resets?\s+(?:in|after)|try\s+again\s+in|retry(?:ing)?\s+(?:in|after)|quota\s+(?:will\s+)?resets?\s+in|capacity\s+resets?\s+in|after)\s+(?:about\s+)?((?:\d+(?:\.\d+)?\s*(?:hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)(?:\s*,\s*|\s+and\s+|\s+)?){1,4})\b"#,
            options: [.caseInsensitive]
        )
        let retryDelayKeyRegex = try! NSRegularExpression(
            pattern: #"(?:retryDelay|retry_after|retry-after)\s*[:=\s]+\s*"?(\d+(?:\.\d+)?\s*(?:hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s|ms))"?"#,
            options: [.caseInsensitive]
        )
        let durationComponentRegex = try! NSRegularExpression(
            pattern: #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s|ms)\b"#,
            options: [.caseInsensitive]
        )
        let standaloneDurationRegex = try! NSRegularExpression(
            pattern: #"^\s*(?:(?:\d+(?:\.\d+)?)\s*(?:hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s|ms)\s*){1,4}$"#,
            options: [.caseInsensitive]
        )
        // swiftlint:enable force_try

        return OSAllocatedUnfairLock(initialState: Formatters(
            isoFractional: isoFractional,
            isoBasic: isoBasic,
            isoDateInTextRegex: isoDateInTextRegex,
            quota429Regex: quota429Regex,
            textDelayPhraseRegex: textDelayPhraseRegex,
            retryDelayKeyRegex: retryDelayKeyRegex,
            durationComponentRegex: durationComponentRegex,
            standaloneDurationRegex: standaloneDurationRegex
        ))
    }()

    /// Parses an ISO-8601 string or epoch timestamp (seconds or milliseconds) into a `Date`.
    static func parseTimestamp(_ raw: Any?) -> Date? {
        if let date = raw as? Date {
            return date
        }
        if let number = numericValue(raw) {
            return dateFromEpochNumber(number)
        }
        guard let str = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty else {
            return nil
        }
        if let number = Double(str), let epochDate = dateFromEpochNumber(number) {
            return epochDate
        }
        return formatterLock.withLock { f in
            f.isoFractional.date(from: str) ?? f.isoBasic.date(from: str)
        }
    }

    private static func dateFromEpochNumber(_ value: Double) -> Date? {
        guard value.isFinite else { return nil }
        if value > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1000.0)
        }
        if value > 1_000_000_000 {
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }

    static func numericValue(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber else { return nil }
        // Reject CFBoolean boxed inside NSNumber.
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        let d = number.doubleValue
        return d.isFinite ? d : nil
    }

    static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        guard let d = numericValue(raw) else { return nil }
        return Int(d)
    }

    /// Recursively collects meaningful error strings and HTTP/status codes from nested JSON values.
    static func collectErrorStrings(from value: Any?, depth: Int = 0) -> [String] {
        guard depth <= 4, let value else { return [] }
        if let s = value as? String {
            return s.isEmpty ? [] : [s]
        }
        if let n = intValue(value) {
            return [String(n)]
        }
        if let array = value as? [Any] {
            return array.flatMap { collectErrorStrings(from: $0, depth: depth + 1) }
        }
        if let dict = value as? [String: Any] {
            var collected: [String] = []
            for key in [
                "error", "message", "status", "code", "reason", "detail", "details",
                "clientVisibleErrorMessage", "actualErrorMessage", "errorDetails", "type", "title"
            ] {
                if let sub = dict[key] {
                    collected.append(contentsOf: collectErrorStrings(from: sub, depth: depth + 1))
                }
            }
            return collected
        }
        return []
    }

    /// Returns `true` when any supplied error string or status code describes a rate-limit / quota error.
    static func isQuotaError(texts: [String], statusCodes: [Int] = []) -> Bool {
        if statusCodes.contains(429) {
            return true
        }
        for text in texts where isQuotaErrorText(text) {
            return true
        }
        return false
    }

    /// Returns `true` when `text` contains HTTP 429, RESOURCE_EXHAUSTED, rate limit, or quota exhausted phrases.
    static func isQuotaErrorText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        let directMarkers = [
            "resource_exhausted",
            "resource exhausted",
            "rate limit",
            "rate_limit",
            "ratelimit",
            "rate-limit",
            "too many requests",
            "quota exhausted",
            "quota_exhausted",
            "quota exceeded",
            "exceeded your current quota",
            "exhausted your capacity",
            "capacity exhausted",
            "usage limit",
            "usage_limit",
            "insufficient_quota",
        ]
        if directMarkers.contains(where: { lower.contains($0) }) {
            return true
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return formatterLock.withLock { f in
            f.quota429Regex.firstMatch(in: text, range: nsRange) != nil
        }
    }

    /// Extracts the rate-limit reset date from structured JSON fields or embedded error messages.
    static func extractResetDate(
        in object: [String: Any],
        texts: [String] = [],
        referenceDate: Date
    ) -> Date? {
        if let structured = extractStructuredResetDate(in: object, referenceDate: referenceDate, depth: 0) {
            return structured
        }
        for text in texts {
            if let fromText = extractResetDate(fromText: text, referenceDate: referenceDate) {
                return fromText
            }
        }
        return nil
    }

    private static let timestampKeys: [String] = [
        "resetsAt", "resets_at", "resetAt", "reset_at",
        "resetTime", "reset_time", "quotaResetTimeStamp", "quotaResetTime", "nextRetryTime"
    ]
    private static let durationSecondKeys: [String] = [
        "resetsInSeconds", "resets_in_seconds", "retryAfterSeconds", "retry_after_seconds",
        "retryAfter", "retry_after", "retryDelay", "retry_delay", "quotaResetDelay"
    ]
    private static let durationMillisecondKeys: [String] = [
        "retryAfterMs", "retry_after_ms", "retryDelayMs", "retry_delay_ms"
    ]

    private static func extractStructuredResetDate(
        in object: [String: Any],
        referenceDate: Date,
        depth: Int
    ) -> Date? {
        guard depth <= 4 else { return nil }

        for key in timestampKeys {
            guard let value = object[key] else { continue }
            if let date = parseTimestamp(value) {
                return date
            }
            if let seconds = numericValue(value), seconds > 0, seconds <= 30 * 86_400 {
                return referenceDate.addingTimeInterval(seconds)
            }
            if let str = value as? String, let seconds = parseStandaloneDurationSeconds(str) {
                return referenceDate.addingTimeInterval(seconds)
            }
        }

        for key in durationSecondKeys {
            guard let value = object[key] else { continue }
            if let seconds = numericValue(value), seconds > 0 {
                return referenceDate.addingTimeInterval(seconds)
            }
            if let str = value as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if let seconds = Double(trimmed), seconds > 0 {
                    return referenceDate.addingTimeInterval(seconds)
                }
                if let seconds = parseStandaloneDurationSeconds(trimmed) {
                    return referenceDate.addingTimeInterval(seconds)
                }
            }
        }

        for key in durationMillisecondKeys {
            guard let value = object[key] else { continue }
            if let ms = numericValue(value), ms > 0 {
                return referenceDate.addingTimeInterval(ms / 1000.0)
            }
            if let str = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let ms = Double(str), ms > 0 {
                return referenceDate.addingTimeInterval(ms / 1000.0)
            }
        }

        for subKey in ["error", "details", "detail", "errorDetails", "quota", "rate_limits", "rateLimits", "payload"] {
            if let subDict = object[subKey] as? [String: Any],
               let found = extractStructuredResetDate(in: subDict, referenceDate: referenceDate, depth: depth + 1) {
                return found
            }
            if let subArray = object[subKey] as? [Any] {
                for item in subArray {
                    if let subDict = item as? [String: Any],
                       let found = extractStructuredResetDate(in: subDict, referenceDate: referenceDate, depth: depth + 1) {
                        return found
                    }
                }
            }
        }
        return nil
    }

    static func extractResetDate(fromText text: String, referenceDate: Date) -> Date? {
        guard !text.isEmpty else { return nil }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

        // 1. Explicit ISO-8601 timestamp in error text.
        let isoRange: NSRange? = formatterLock.withLock { f in
            f.isoDateInTextRegex.firstMatch(in: text, range: fullRange)?.range
        }
        if let isoRange, let swiftRange = Range(isoRange, in: text),
           let date = parseTimestamp(String(text[swiftRange])) {
            return date
        }

        // 2. Explicit retryDelay / retry-after key-value in error string.
        let retryRange: NSRange? = formatterLock.withLock { f in
            guard let match = f.retryDelayKeyRegex.firstMatch(in: text, range: fullRange),
                  match.numberOfRanges >= 2 else { return nil }
            return match.range(at: 1)
        }
        if let retryRange, let swiftRange = Range(retryRange, in: text),
           let seconds = parseDurationComponentsSeconds(String(text[swiftRange])), seconds > 0 {
            return referenceDate.addingTimeInterval(seconds)
        }

        // 3. Natural language delay ("try again in 3h14m22s", "retry after 30 seconds", "resets in 5m").
        let phraseRange: NSRange? = formatterLock.withLock { f in
            guard let match = f.textDelayPhraseRegex.firstMatch(in: text, range: fullRange),
                  match.numberOfRanges >= 2 else { return nil }
            return match.range(at: 1)
        }
        if let phraseRange, let swiftRange = Range(phraseRange, in: text),
           let seconds = parseDurationComponentsSeconds(String(text[swiftRange])), seconds > 0 {
            return referenceDate.addingTimeInterval(seconds)
        }

        return nil
    }

    private static func parseStandaloneDurationSeconds(_ text: String) -> TimeInterval? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matchesFull = formatterLock.withLock {
            $0.standaloneDurationRegex.firstMatch(in: text, range: fullRange) != nil
        }
        guard matchesFull else { return nil }
        return parseDurationComponentsSeconds(text)
    }

    private static func parseDurationComponentsSeconds(_ text: String) -> TimeInterval? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let ranges: [(NSRange, NSRange)] = formatterLock.withLock { f in
            f.durationComponentRegex.matches(in: text, range: fullRange).compactMap { match in
                guard match.numberOfRanges >= 3 else { return nil }
                return (match.range(at: 1), match.range(at: 2))
            }
        }
        guard !ranges.isEmpty else { return nil }
        var totalSeconds: TimeInterval = 0
        for (amountRange, unitRange) in ranges {
            guard let aRange = Range(amountRange, in: text),
                  let uRange = Range(unitRange, in: text),
                  let amount = Double(text[aRange]),
                  amount > 0 else { continue }
            let unit = text[uRange].lowercased()
            if unit == "ms" {
                totalSeconds += amount / 1000.0
            } else if unit.hasPrefix("s") {
                totalSeconds += amount
            } else if unit.hasPrefix("m") {
                totalSeconds += amount * 60.0
            } else if unit.hasPrefix("h") {
                totalSeconds += amount * 3600.0
            }
        }
        return totalSeconds > 0 ? totalSeconds : nil
    }
}
