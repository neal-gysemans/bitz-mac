import SwiftUI

/// Quick-action HUD view for pending agent approval requests (FR-004, FR-005, FR-006, FR-008).
/// Displays tool name and command summary, and renders "APPROVE", "JUMP", and "DIFF" buttons.
/// The "APPROVE" button is only displayed when an explicit hook decision channel is provided (FR-006).
public struct AgentApprovalHUDView: View {
    public let request: AgentApprovalRequest?
    public let appActivator: any AppActivating
    public let diffViewer: any DiffViewing
    public var onApprove: (() -> Void)?
    public var onJump: (() -> Void)?
    public var onDiff: (() -> Void)?

    public init(
        request: AgentApprovalRequest?,
        appActivator: any AppActivating = WorkspaceAppActivator(),
        diffViewer: any DiffViewing = SystemDiffViewer(),
        onApprove: (() -> Void)? = nil,
        onJump: (() -> Void)? = nil,
        onDiff: (() -> Void)? = nil
    ) {
        self.request = request
        self.appActivator = appActivator
        self.diffViewer = diffViewer
        self.onApprove = onApprove
        self.onJump = onJump
        self.onDiff = onDiff
    }

    public var summaryText: String? {
        guard let request else { return nil }
        if let tool = request.toolName, let cmd = request.commandSummary {
            return "\(tool): \(cmd)"
        }
        return request.commandSummary ?? request.toolName
    }

    public var body: some View {
        VStack(spacing: 5) {
            if let summary = summaryText {
                Text(summary)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(Color.white.opacity(0.95))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.4)))
            }

            HStack(spacing: 6) {
                // APPROVE button: shown ONLY when an explicit hook response channel exists (FR-006)
                if request?.hasApprovalChannel == true {
                    Button(action: {
                        onApprove?()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8))
                            Text("APPROVE")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(red: 0.0, green: 0.85, blue: 0.55)))
                        .foregroundStyle(Color.black)
                    }
                    .buttonStyle(.plain)
                }

                // JUMP button: brings owning terminal / IDE forward (FR-004)
                Button(action: {
                    if let request {
                        appActivator.activateApp(pid: request.owningPID, bundleID: request.bundleID)
                    }
                    onJump?()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.forward.app.fill")
                            .font(.system(size: 8))
                        Text("JUMP")
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 0.12, green: 0.55, blue: 0.95)))
                    .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)

                // DIFF button: opens git diff for the working directory (FR-005)
                Button(action: {
                    Task {
                        await diffViewer.openDiff(workingDirectory: request?.workingDir)
                    }
                    onDiff?()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 8))
                        Text("DIFF")
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 0.95, green: 0.65, blue: 0.15)))
                    .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }
}
