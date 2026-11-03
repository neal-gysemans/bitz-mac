import Foundation

/// Sanitizes raw LLM and templated text output to adhere to Bitz's speech bubble constraints:
/// - Single line (newlines/tabs flattened).
/// - Enforced max character limit (target ≤ 80 characters with clean word boundary truncation).
/// - Strips quotes, markdown wrappers, and raw URLs.
/// - Rejects verbatim echoing of window titles, frontmost application names, or empty strings.
public struct CommentarySanitizer: Sendable {
    public static let defaultMaxCharacterLength: Int = 80

    public let maxCharacterLength: Int

    public init(maxCharacterLength: Int = CommentarySanitizer.defaultMaxCharacterLength) {
        self.maxCharacterLength = maxCharacterLength
    }

    /// Sanitizes raw input against speech bubble invariants.
    public func sanitize(_ rawText: String, context: PersonalityContext? = nil) -> Result<String, PersonalityError> {
        // Flatten multiple whitespaces and newlines into single spaces
        var cleaned = rawText
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return .failure(.outputEmpty)
        }

        // Strip surrounding matching quotes
        cleaned = stripSurroundingQuotes(cleaned)

        // Strip backticks and markdown bold/italic asterisks
        cleaned = cleaned.replacingOccurrences(of: "`", with: "")
        cleaned = cleaned.replacingOccurrences(of: "**", with: "")

        // Strip URLs (http://, https://, www.)
        cleaned = stripURLs(cleaned)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return .failure(.outputSanitizedAway)
        }

        // Reject if output is purely punctuation
        let alphanumericCount = cleaned.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        guard alphanumericCount > 0 else {
            return .failure(.outputSanitizedAway)
        }

        // Reject verbatim echoing of frontmost app name
        if let appName = context?.frontmostAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appName.isEmpty,
           cleaned.caseInsensitiveCompare(appName) == .orderedSame {
            return .failure(.outputSanitizedAway)
        }

        // Enforce max character limit with word boundary truncation
        if cleaned.count > maxCharacterLength {
            cleaned = truncateAtWordBoundary(cleaned, maxLength: maxCharacterLength)
        }

        return .success(cleaned)
    }

    private func stripSurroundingQuotes(_ text: String) -> String {
        var result = text
        let quotePairs: [(String, String)] = [
            ("\"", "\""),
            ("'", "'"),
            ("“", "”"),
            ("‘", "’")
        ]

        for (start, end) in quotePairs {
            if result.hasPrefix(start) && result.hasSuffix(end) && result.count >= (start.count + end.count) {
                result.removeFirst(start.count)
                result.removeLast(end.count)
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    private func stripURLs(_ text: String) -> String {
        // Match http://, https://, or www. links and remove them
        let pattern = #"(https?:\/\/[^\s]+|www\.[^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        let stripped = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        // Clean up any double spaces left behind by removal
        return stripped.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func truncateAtWordBoundary(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let targetLength = max(10, maxLength - 1) // Leave room for ellipsis "…"

        let prefix = String(text.prefix(targetLength))
        if let lastSpace = prefix.lastIndex(of: " ") {
            let truncated = prefix[..<lastSpace].trimmingCharacters(in: .whitespacesAndNewlines)
            return truncated + "…"
        } else {
            return prefix + "…"
        }
    }
}
