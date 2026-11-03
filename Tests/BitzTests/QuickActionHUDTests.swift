import XCTest
import AppKit
@testable import BitzCore

// MARK: - Test Mocks

final class MockAppActivator: AppActivating, @unchecked Sendable {
    var activatedPIDs: [pid_t] = []
    var activatedBundleIDs: [String] = []
    var activationResult: Bool = true

    func activateApp(pid: pid_t?, bundleID: String?) -> Bool {
        if let pid { activatedPIDs.append(pid) }
        if let bundleID { activatedBundleIDs.append(bundleID) }
        return activationResult
    }
}

final class MockRunningApp: RunningAppActivating, @unchecked Sendable {
    var isTerminated: Bool
    var activationResult: Bool
    var wasActivated: Bool = false

    init(isTerminated: Bool = false, activationResult: Bool = true) {
        self.isTerminated = isTerminated
        self.activationResult = activationResult
    }

    func activate(options: NSApplication.ActivationOptions) -> Bool {
        wasActivated = true
        return activationResult
    }
}

final class MockDiffViewer: DiffViewing, @unchecked Sendable {
    var queriedDirectories: [String?] = []
    var openedDirectories: [String?] = []
    var diffResultToReturn: Result<String, DiffViewerError> = .success("diff --git a/file b/file\n+new line")
    var openDiffResultToReturn: Bool = true

    func getDiff(workingDirectory: String?) async -> Result<String, DiffViewerError> {
        queriedDirectories.append(workingDirectory)
        return diffResultToReturn
    }

    func openDiff(workingDirectory: String?) async -> Bool {
        openedDirectories.append(workingDirectory)
        return openDiffResultToReturn
    }
}

// MARK: - Unit Tests

@MainActor
final class QuickActionHUDTests: XCTestCase {

    // MARK: - App Activation Tests (FR-004, NFR-003, NFR-004)

    func testMockAppActivator_RecordsInvocations() {
        let activator = MockAppActivator()
        let result = activator.activateApp(pid: 1234, bundleID: "com.anthropic.claudefordesktop")

        XCTAssertTrue(result)
        XCTAssertEqual(activator.activatedPIDs, [1234])
        XCTAssertEqual(activator.activatedBundleIDs, ["com.anthropic.claudefordesktop"])
    }

    func testMockAppActivator_HandlesNilParameters() {
        let activator = MockAppActivator()
        let result = activator.activateApp(pid: nil, bundleID: nil)

        XCTAssertTrue(result)
        XCTAssertTrue(activator.activatedPIDs.isEmpty)
        XCTAssertTrue(activator.activatedBundleIDs.isEmpty)
    }

    func testWorkspaceAppActivator_InvalidPIDAndBundleReturnsFalse() {
        let activator = WorkspaceAppActivator()
        let result = activator.activateApp(pid: -1, bundleID: nil)
        XCTAssertFalse(result, "Negative PID must fail activation safely")

        let resultBadBundle = activator.activateApp(pid: nil, bundleID: "com.invalid.nonexistent.app.\(UUID().uuidString)")
        XCTAssertFalse(resultBadBundle, "Non-existent bundle ID must fail activation safely")
    }

    func testWorkspaceAppActivator_DeterministicPIDActivationSucceeds() {
        let mockApp = MockRunningApp(isTerminated: false, activationResult: true)
        let activator = WorkspaceAppActivator(
            pidResolver: { pid in pid == 42 ? mockApp : nil },
            bundleIDResolver: { _ in [] }
        )

        let result = activator.activateApp(pid: 42, bundleID: nil)
        XCTAssertTrue(result, "PID 42 should resolve and activate successfully")
        XCTAssertTrue(mockApp.wasActivated)
    }

    func testWorkspaceAppActivator_TerminatedPIDFallsBackToBundleID() {
        let terminatedApp = MockRunningApp(isTerminated: true, activationResult: false)
        let bundleApp = MockRunningApp(isTerminated: false, activationResult: true)

        let activator = WorkspaceAppActivator(
            pidResolver: { _ in terminatedApp },
            bundleIDResolver: { bundleID in bundleID == "com.google.antigravity" ? [bundleApp] : [] }
        )

        let result = activator.activateApp(pid: 999, bundleID: "com.google.antigravity")
        XCTAssertTrue(result, "Terminated PID must fall back to bundle identifier")
        XCTAssertFalse(terminatedApp.wasActivated)
        XCTAssertTrue(bundleApp.wasActivated)
    }

    // MARK: - Diff Viewer Tests (FR-005)

    func testMockDiffViewer_ReturnsConfiguredDiff() async {
        let viewer = MockDiffViewer()
        let result = await viewer.getDiff(workingDirectory: "/mock/repo")

        switch result {
        case .success(let diff):
            XCTAssertTrue(diff.contains("+new line"))
        case .failure:
            XCTFail("Expected mock diff success")
        }
        XCTAssertEqual(viewer.queriedDirectories, ["/mock/repo"])
    }

    func testSystemDiffViewer_InvalidDirectoryReturnsFailure() async {
        let viewer = SystemDiffViewer()
        let nonExistentDir = "/invalid/directory/\(UUID().uuidString)"
        let result = await viewer.getDiff(workingDirectory: nonExistentDir)

        switch result {
        case .success:
            XCTFail("Non-existent directory must return failure")
        case .failure(let error):
            XCTAssertEqual(error, .invalidDirectory)
        }
    }

    func testSystemDiffViewer_InvalidGitPathReturnsFailure() async {
        let viewer = SystemDiffViewer(gitPath: "/bin/nonexistent_git_\(UUID().uuidString)")
        let result = await viewer.getDiff(workingDirectory: FileManager.default.currentDirectoryPath)

        switch result {
        case .success:
            XCTFail("Non-existent git path must return failure")
        case .failure(let error):
            XCTAssertEqual(error, .gitNotFound)
        }
    }

    func testSystemDiffViewer_ValidDirectoryExecutesGitDiff() async {
        let viewer = SystemDiffViewer()
        let result = await viewer.getDiff(workingDirectory: FileManager.default.currentDirectoryPath)

        switch result {
        case .success:
            // Succeeded running git diff
            break
        case .failure(let error):
            XCTFail("Running git diff in current repo failed with: \(error)")
        }
    }

    // MARK: - SpeechBubblePanel Interactivity & Focus Invariants (FR-008, NFR-003)

    func testSpeechBubblePanel_InteractivityClassification() {
        let release = GitHubReleaseInfo(
            tagName: "v1.4.0",
            name: "v1.4.0",
            htmlUrl: URL(string: "https://github.com/AkramKs/bitz-mac/releases/tag/v1.4.0")!
        )
        let updateContent = SpeechBubbleContent.update(release)
        XCTAssertTrue(SpeechBubblePanel.isInteractiveContent(updateContent))
        XCTAssertTrue(updateContent.isQuickActionInteractive)

        let approvalPopup = AgentPopupState(
            text: "Needs approval",
            kind: .needsApproval,
            agentName: "Claude",
            expiresAt: Date().addingTimeInterval(300)
        )
        let approvalContent = SpeechBubbleContent.agentPopup(approvalPopup)
        XCTAssertTrue(SpeechBubblePanel.isInteractiveContent(approvalContent), "Approval bubble must be classified as interactive")
        XCTAssertTrue(approvalContent.isQuickActionInteractive)

        let warningPopup = AgentPopupState(
            text: "Stalled",
            kind: .warning,
            agentName: "Claude",
            expiresAt: Date().addingTimeInterval(60)
        )
        let warningContent = SpeechBubbleContent.agentPopup(warningPopup)
        XCTAssertTrue(SpeechBubblePanel.isInteractiveContent(warningContent))

        let workingPopup = AgentPopupState(
            text: "Working",
            kind: .working,
            agentName: "Claude",
            expiresAt: Date().addingTimeInterval(60)
        )
        let workingContent = SpeechBubbleContent.agentPopup(workingPopup)
        XCTAssertFalse(SpeechBubblePanel.isInteractiveContent(workingContent), "Working popup must NOT be interactive")
        XCTAssertFalse(workingContent.isQuickActionInteractive)

        let wellnessContent = SpeechBubbleContent.wellness("SYSTEM HOT!")
        XCTAssertFalse(SpeechBubblePanel.isInteractiveContent(wellnessContent))

        let carouselContent = SpeechBubbleContent.carousel("CPU: 12%")
        XCTAssertFalse(SpeechBubblePanel.isInteractiveContent(carouselContent))

        XCTAssertFalse(SpeechBubblePanel.isInteractiveContent(nil))
    }

    func testSpeechBubblePanel_PanelInteractivityTogglingAndFocusInvariants() {
        let panel = SpeechBubblePanel()

        // Invariant: must NEVER become key or main window (NFR-003)
        XCTAssertFalse(panel.canBecomeKey, "SpeechBubblePanel must never become key")
        XCTAssertFalse(panel.canBecomeMain, "SpeechBubblePanel must never become main")
        XCTAssertTrue(panel.ignoresMouseEvents, "Panel must ignore mouse events by default")
        XCTAssertFalse(panel.isInteractive)

        // Set interactive
        panel.isInteractive = true
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.isInteractive)

        // Set non-interactive
        panel.isInteractive = false
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isInteractive)

        // Update interactivity with approval content
        let approvalPopup = AgentPopupState(
            text: "Needs approval",
            kind: .needsApproval,
            agentName: "Claude",
            expiresAt: Date().addingTimeInterval(300)
        )
        panel.updateInteractivity(for: .agentPopup(approvalPopup))
        XCTAssertFalse(panel.ignoresMouseEvents, "Panel must accept clicks for approval popup")
        XCTAssertTrue(panel.isInteractive)

        // Update interactivity with nil
        panel.updateInteractivity(for: nil)
        XCTAssertTrue(panel.ignoresMouseEvents, "Panel must revert to click-through when content is nil")
        XCTAssertFalse(panel.isInteractive)
    }
}
