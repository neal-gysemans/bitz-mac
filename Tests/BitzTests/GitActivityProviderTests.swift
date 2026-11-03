import XCTest
@testable import BitzCore

final class GitActivityProviderTests: XCTestCase {

    final class MockRunnerBox: @unchecked Sendable {
        var callCount: Int = 0
        var recordedCalls: [(path: String, args: [String])] = []
        var responses: [String: Result<String, Error>] = [:]

        func run(path: String, args: [String]) throws -> String {
            callCount += 1
            recordedCalls.append((path, args))
            if let result = responses[path] {
                return try result.get()
            }
            return ""
        }
    }

    func testNoReposWatchedSpawnsZeroProcessesAndReturnsNil() async {
        let box = MockRunnerBox()
        let provider = GitActivityProvider(
            repoPathsProvider: { [] },
            runner: { path, args in try box.run(path: path, args: args) }
        )

        let result = await provider.recentCommitCount(sinceMinutes: 30)
        XCTAssertNil(result)
        XCTAssertEqual(box.callCount, 0, "No git process must be spawned when no repos are watched")
    }

    func testSingleRepoReturnsCommitCount() async {
        let box = MockRunnerBox()
        box.responses["/Users/bitz/repo1"] = .success("abc1234 First commit\ndef5678 Second commit\n")

        let provider = GitActivityProvider(
            repoPathsProvider: { ["/Users/bitz/repo1"] },
            runner: { path, args in try box.run(path: path, args: args) }
        )

        let count = await provider.recentCommitCount(sinceMinutes: 30)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(box.callCount, 1)
        XCTAssertEqual(box.recordedCalls.first?.path, "/Users/bitz/repo1")
        XCTAssertEqual(box.recordedCalls.first?.args, ["log", "--since=30 minutes ago", "--oneline"])
    }

    func testMultipleReposAggregateCommitCounts() async {
        let box = MockRunnerBox()
        box.responses["/Users/bitz/repoA"] = .success("111 commit A1\n222 commit A2\n")
        box.responses["/Users/bitz/repoB"] = .success("333 commit B1\n444 commit B2\n555 commit B3\n")

        let provider = GitActivityProvider(
            repoPathsProvider: { ["/Users/bitz/repoA", "/Users/bitz/repoB"] },
            runner: { path, args in try box.run(path: path, args: args) }
        )

        let count = await provider.recentCommitCount(sinceMinutes: 60)
        XCTAssertEqual(count, 5)
        XCTAssertEqual(box.callCount, 2)
    }

    final class MockClockBox: @unchecked Sendable {
        var now: Date
        init(now: Date = Date(timeIntervalSince1970: 1_000_000)) {
            self.now = now
        }
        func advance(by seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    func testCacheTTLHonored() async {
        let box = MockRunnerBox()
        box.responses["/Users/bitz/repo"] = .success("abc1234 Commit\n")

        let clock = MockClockBox()
        let provider = GitActivityProvider(
            repoPathsProvider: { ["/Users/bitz/repo"] },
            runner: { path, args in try box.run(path: path, args: args) },
            clock: { clock.now },
            ttlSeconds: 60.0
        )

        // 1. Initial query: runner called
        let count1 = await provider.recentCommitCount(sinceMinutes: 30)
        XCTAssertEqual(count1, 1)
        XCTAssertEqual(box.callCount, 1)

        // 2. Query within TTL (advance 10 seconds): cached count returned, runner NOT called
        clock.advance(by: 10.0)
        let count2 = await provider.recentCommitCount(sinceMinutes: 30)
        XCTAssertEqual(count2, 1)
        XCTAssertEqual(box.callCount, 1, "Must return cached value within TTL without re-querying")

        // 3. Query after TTL expired (advance 61 seconds): runner called again
        clock.advance(by: 61.0)
        let count3 = await provider.recentCommitCount(sinceMinutes: 30)
        XCTAssertEqual(count3, 1)
        XCTAssertEqual(box.callCount, 2, "Must re-query after TTL expires")
    }

    func testFailingRepoIsHandledGracefully() async {
        let box = MockRunnerBox()
        box.responses["/Users/bitz/brokenRepo"] = .failure(GitError.commandFailed(128))
        box.responses["/Users/bitz/goodRepo"] = .success("abc1234 Commit 1\nxyz9876 Commit 2\n")

        let provider = GitActivityProvider(
            repoPathsProvider: { ["/Users/bitz/brokenRepo", "/Users/bitz/goodRepo"] },
            runner: { path, args in try box.run(path: path, args: args) }
        )

        let count = await provider.recentCommitCount(sinceMinutes: 45)
        XCTAssertEqual(count, 2, "Broken repository must not prevent counting valid repositories")
        XCTAssertEqual(box.callCount, 2)
    }

    func testInvalidateCacheForcesFreshFetch() async {
        let box = MockRunnerBox()
        box.responses["/Users/bitz/repo"] = .success("abc1234 Commit\n")

        let clock = MockClockBox()
        let provider = GitActivityProvider(
            repoPathsProvider: { ["/Users/bitz/repo"] },
            runner: { path, args in try box.run(path: path, args: args) },
            clock: { clock.now },
            ttlSeconds: 60.0
        )

        let count1 = await provider.recentCommitCount(sinceMinutes: 30)
        XCTAssertEqual(count1, 1)
        XCTAssertEqual(box.callCount, 1)

        // Invalidate cache immediately
        await provider.invalidateCache()

        // Query again at same timestamp: must invoke runner
        let count2 = await provider.recentCommitCount(sinceMinutes: 30)
        XCTAssertEqual(count2, 1)
        XCTAssertEqual(box.callCount, 2, "Invalidating cache must force a fresh execution")
    }
}
