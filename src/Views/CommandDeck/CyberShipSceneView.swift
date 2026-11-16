import SwiftUI
import SceneKit
import AppKit

/// One-shot trigger request to animate an inter-agent message delivery walk in the 3D scene.
public struct AgentCommsRequest: Equatable, Sendable {
    public let id: UUID
    public let senderKey: String
    public let recipientKey: String

    public init(id: UUID = UUID(), senderKey: String, recipientKey: String) {
        self.id = id
        self.senderKey = senderKey
        self.recipientKey = recipientKey
    }
}

/// SwiftUI wrapper for the 3D SceneKit Cyber-Ship viewport.
///
/// Features:
/// - Wraps `CyberShipSCNView: SCNView` with 4x multisampling and 60 FPS cap.
/// - Strict 0.0% CPU invariant: halts display link (`isPlaying = false; stop(nil)`)
///   when the window is occluded, miniaturized, or hidden.
/// - Click hit-testing: translates clicks on crewmates into `onSelectSession(stateKey)`.
public struct CyberShipSceneView: NSViewRepresentable {

    public let sessions: [AgentSessionSnapshot]
    public let selectedSessionKey: String?
    public let isWindowVisible: Bool
    public var pendingCommsRequest: AgentCommsRequest?
    public let onSelectSession: (String) -> Void

    public init(
        sessions: [AgentSessionSnapshot],
        selectedSessionKey: String?,
        isWindowVisible: Bool,
        pendingCommsRequest: AgentCommsRequest? = nil,
        onSelectSession: @escaping (String) -> Void
    ) {
        self.sessions = sessions
        self.selectedSessionKey = selectedSessionKey
        self.isWindowVisible = isWindowVisible
        self.pendingCommsRequest = pendingCommsRequest
        self.onSelectSession = onSelectSession
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onSelectSession: onSelectSession)
    }

    public func configureView(_ scnView: CyberShipSCNView, coordinator: Coordinator) {
        scnView.scene = coordinator.controller.scene
        scnView.sceneController = coordinator.controller
        scnView.onSelectSession = onSelectSession

        scnView.antialiasingMode = .multisampling4X
        scnView.preferredFramesPerSecond = 60
        scnView.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.08, alpha: 1.0)
        scnView.allowsCameraControl = false
        scnView.autoenablesDefaultLighting = false
        scnView.rendersContinuously = true

        updateView(scnView, coordinator: coordinator)
    }

    public func updateView(_ nsView: CyberShipSCNView, coordinator: Coordinator) {
        coordinator.onSelectSession = onSelectSession
        nsView.onSelectSession = onSelectSession

        if !isWindowVisible {
            if nsView.isPlaying {
                nsView.isPlaying = false
                nsView.stop(nil)
            }
            return
        }

        if !nsView.isPlaying {
            nsView.isPlaying = true
            nsView.play(nil)
        }

        coordinator.controller.syncSessions(sessions, selectedSessionKey: selectedSessionKey)
        coordinator.controller.updateCameraForViewport(size: nsView.bounds.size)

        if let req = pendingCommsRequest, req.id != coordinator.lastHandledCommsID {
            coordinator.lastHandledCommsID = req.id
            coordinator.controller.triggerMessageDelivery(from: req.senderKey, to: req.recipientKey)
        }
    }

    public func makeNSView(context: Context) -> CyberShipSCNView {
        let scnView = CyberShipSCNView(frame: .zero)
        configureView(scnView, coordinator: context.coordinator)
        return scnView
    }

    public func updateNSView(_ nsView: CyberShipSCNView, context: Context) {
        updateView(nsView, coordinator: context.coordinator)
    }

    public static func dismantleNSView(_ nsView: CyberShipSCNView, coordinator: Coordinator) {
        nsView.isPlaying = false
        nsView.stop(nil)
        nsView.scene = nil
        nsView.sceneController = nil
        nsView.onSelectSession = nil
    }

    // MARK: - Coordinator

    public final class Coordinator {
        public let controller: CyberShipSceneController
        public var onSelectSession: (String) -> Void
        public var lastHandledCommsID: UUID? = nil

        public init(onSelectSession: @escaping (String) -> Void) {
            self.controller = CyberShipSceneController()
            self.onSelectSession = onSelectSession
        }
    }
}

// MARK: - Custom SCNView Subclass

/// Custom `SCNView` subclass handling mouse hit-testing for crewmate selection.
public final class CyberShipSCNView: SCNView {
    public weak var sceneController: CyberShipSceneController?
    public var onSelectSession: ((String) -> Void)?

    public override func layout() {
        super.layout()
        sceneController?.updateCameraForViewport(size: bounds.size)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sceneController?.updateCameraForViewport(size: newSize)
    }

    public override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let hitResults = hitTest(location, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true
        ])

        if let firstHit = hitResults.first,
           let controller = sceneController,
           let crewmate = controller.crewmateNode(for: firstHit.node) {
            onSelectSession?(crewmate.stateKey)
            return
        }

        super.mouseDown(with: event)
    }
}
