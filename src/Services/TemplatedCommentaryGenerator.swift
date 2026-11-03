import Foundation

/// Fast, deterministic, on-device templated commentary generator.
/// Serves as the primary zero-dependency generator on macOS 14-25, and as the instant fallback
/// when an LLM backend times out, errors, or is unavailable.
public actor TemplatedCommentaryGenerator: CommentaryGenerating {
    private var recentIndices: [String: [Int]] = [:]
    private let historyDepth: Int

    public init(historyDepth: Int = 4) {
        self.historyDepth = historyDepth
    }

    public func generate(context: PersonalityContext, preset: PersonalityPreset) async throws -> String {
        let candidates = candidateTemplates(for: context, preset: preset)
        guard !candidates.isEmpty else {
            throw PersonalityError.outputEmpty
        }

        let key = preset.rawValue
        var past = recentIndices[key] ?? []
        let availableIndices = candidates.indices.filter { !past.contains($0) }
        let selectedIndex: Int
        if let pick = availableIndices.randomElement() {
            selectedIndex = pick
        } else {
            selectedIndex = candidates.indices.randomElement() ?? 0
            past.removeAll()
        }
        past.append(selectedIndex)
        if past.count > historyDepth {
            past.removeFirst(past.count - historyDepth)
        }
        recentIndices[key] = past

        return candidates[selectedIndex]
    }

    public func rephrase(warning: String, context: PersonalityContext, preset: PersonalityPreset) async throws -> String {
        switch preset {
        case .snarky:
            return "\(warning) Don't melt the silicon."
        case .supportive:
            return "\(warning) Let's take a mindful pause."
        case .cute:
            return "🐾 \(warning) Paw-safe mode engaged!"
        }
    }

    public func unload() async {
        recentIndices.removeAll()
    }

    private func candidateTemplates(for context: PersonalityContext, preset: PersonalityPreset) -> [String] {
        var lines: [String] = []

        // Temperature condition
        if let temp = context.temperatureCelsius, temp >= 80.0 {
            let t = Int(temp)
            switch preset {
            case .snarky:
                lines.append("\(t)°C... are we frying eggs on this M-chip? 🍳")
                lines.append("Toasty \(t)°C. The fans are quietly judging your life choices.")
            case .supportive:
                lines.append("Warm chip (\(t)°C). A short breather will help the Mac cool down.")
                lines.append("Running at \(t)°C. Consider stepping away for a glass of water.")
            case .cute:
                lines.append("\(t)°C! Toasty warm paws on the keyboard~ 🐾")
                lines.append("Warm laptop alert! Bitz wants to curl up on it, but please rest! 🐱")
            }
        }

        // Long continuous work minutes
        if context.continuousWorkMinutes >= 60.0 {
            let mins = Int(context.continuousWorkMinutes)
            switch preset {
            case .snarky:
                lines.append("\(mins) minutes straight. Blink twice if you need a break.")
                lines.append("\(mins)m on the clock. Don't worry, the bugs will wait for you.")
            case .supportive:
                lines.append("Deep focus for \(mins) minutes. Remember to unroll your shoulders.")
                lines.append("\(mins)m streak. A brief stretch now will keep your energy high.")
            case .cute:
                lines.append("\(mins) minutes of awesome work! Purr... stretch those paws! ✨")
                lines.append("Working so hard for \(mins)m! Time for a friendly cat stretch! 😸")
            }
        }

        // Git commit streak
        if let commits = context.recentCommitCount, commits > 0 {
            switch preset {
            case .snarky:
                lines.append("\(commits) commits recently? Look at you, 10x developer.")
                lines.append("\(commits) commits pushed. Hope you didn't break main. 🔥")
            case .supportive:
                lines.append("Solid momentum: \(commits) commits shipped. Great progress!")
                lines.append("\(commits) commits down. Keep up the calm, steady pace.")
            case .cute:
                lines.append("Paws typing fast: \(commits) commits logged! Great job! 🎉")
            }
        }

        // Active AI Agent
        if let agentName = context.activeAgentNames.first {
            switch preset {
            case .snarky:
                lines.append("\(agentName) is churning tokens. Grab a coffee while you wait.")
                lines.append("\(agentName) is deep in thought. Don't look directly at the diff.")
            case .supportive:
                lines.append("\(agentName) is handling the heavy lifting. Good time for a rest.")
                lines.append("\(agentName) is working hard on your tasks. Stay hydrated!")
            case .cute:
                lines.append("\(agentName) is helping out! Teamwork makes the dream work! 🐾")
            }
        }

        // Frontmost App
        if let app = context.frontmostAppName, !app.isEmpty {
            switch preset {
            case .snarky:
                lines.append("Still deep in \(app)? Don't let the syntax win.")
            case .supportive:
                lines.append("Focused in \(app). Remember the 20-20-20 screen rule.")
            case .cute:
                lines.append("Watching you work magic in \(app)! Meow! 💖")
            }
        }

        // General ambient lines
        switch preset {
        case .snarky:
            lines.append(contentsOf: [
                "Hydration check. And no, cold brew doesn't count as water.",
                "Desktop looking busy. I might just nap right on this window.",
                "Another minute, another byte. Keep hacking away."
            ])
        case .supportive:
            lines.append(contentsOf: [
                "Taking care of your focus is taking care of yourself.",
                "Steady rhythm today. You're doing excellent work.",
                "Remember to unclench your jaw and take a deep breath."
            ])
        case .cute:
            lines.append(contentsOf: [
                "Bitz is purring quietly by your side~ 🐾",
                "Sending cyber hugs and extra focus energy! ✨",
                "Napping with one eye open while you build cool things! 😺"
            ])
        }

        return lines
    }
}
