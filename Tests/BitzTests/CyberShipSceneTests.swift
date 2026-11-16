import XCTest
import SceneKit
import SwiftUI
import AppKit
@testable import BitzCore

@MainActor
final class CyberShipSceneTests: XCTestCase {

    private func makeIsolatedDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "CyberShipSceneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, cleanup)
    }

    private func makeSampleSnapshot(
        stateKey: String = "claude:session-1",
        agentID: String = "claude",
        agentName: String = "Claude",
        sessionID: String = "session-1",
        sessionLabel: String = "Claude · bitz-mac",
        state: AgentSessionLifecycleState = .working,
        warning: AgentWarningReason? = nil,
        tokens: Int = 50_000,
        windowTokens: Int = 200_000
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            stateKey: stateKey,
            agentID: agentID,
            agentName: agentName,
            sessionID: sessionID,
            sessionLabel: sessionLabel,
            lifecycleState: state,
            activeWarning: warning,
            contextReading: AgentContextReading(agentID: agentID, agentName: agentName, tokens: tokens, windowTokens: windowTokens),
            pendingTools: 0,
            lastActivity: Date(),
            linkedApprovalRequest: nil,
            workingDir: "/Volumes/DevDrive/Code/bitz-mac"
        )
    }

    // MARK: - 1. Station Coordinates & Geometry Constants

    func testStationCoordinatesAndCenters() {
        XCTAssertEqual(CyberShipSceneController.codeBayCenter.x, -5.0)
        XCTAssertEqual(CyberShipSceneController.codeBayCenter.y, 0.0)
        XCTAssertEqual(CyberShipSceneController.codeBayCenter.z, 0.0)

        XCTAssertEqual(CyberShipSceneController.emergencyTableCenter.x, 0.0)
        XCTAssertEqual(CyberShipSceneController.emergencyTableCenter.y, 0.0)
        XCTAssertEqual(CyberShipSceneController.emergencyTableCenter.z, 0.0)

        XCTAssertEqual(CyberShipSceneController.reactorCenter.x, 0.0)
        XCTAssertEqual(CyberShipSceneController.reactorCenter.y, 0.0)
        XCTAssertEqual(CyberShipSceneController.reactorCenter.z, -5.5)

        XCTAssertEqual(CyberShipSceneController.launchpadCenter.x, 5.0)
        XCTAssertEqual(CyberShipSceneController.launchpadCenter.y, 0.0)
        XCTAssertEqual(CyberShipSceneController.launchpadCenter.z, 0.0)

        XCTAssertEqual(CyberShipSceneController.medBayCenter.x, 0.0)
        XCTAssertEqual(CyberShipSceneController.medBayCenter.y, 0.0)
        XCTAssertEqual(CyberShipSceneController.medBayCenter.z, 4.5)
    }

    func testTargetPositionPerStationState() {
        // 1. Working: Code Bay waypoints
        let workPos0 = CyberShipSceneController.targetPosition(for: .working, warning: nil, slotIndex: 0, totalInStation: 1)
        XCTAssertEqual(workPos0.x, -7.1, accuracy: 0.001)
        XCTAssertEqual(workPos0.z, -2.1, accuracy: 0.001)

        let workPos1 = CyberShipSceneController.targetPosition(for: .working, warning: nil, slotIndex: 1, totalInStation: 2)
        XCTAssertEqual(workPos1.x, -4.3, accuracy: 0.001)
        XCTAssertEqual(workPos1.z, -2.1, accuracy: 0.001)

        // 2. Needs Approval: Emergency Table circle perimeter
        let approvalPos = CyberShipSceneController.targetPosition(for: .needsApproval, warning: nil, slotIndex: 0, totalInStation: 1)
        XCTAssertEqual(approvalPos.x, 1.8, accuracy: 0.01)
        XCTAssertEqual(approvalPos.z, 0.0, accuracy: 0.01)

        // 3. Warning (loop): Orbit around reactor (-5.5 z)
        let loopPos = CyberShipSceneController.targetPosition(for: .warning, warning: .loop, slotIndex: 0, totalInStation: 1)
        XCTAssertEqual(loopPos.x, 1.6, accuracy: 0.01)
        XCTAssertEqual(loopPos.z, -5.5, accuracy: 0.01)

        // 4. Warning (other): Standing at barrier (z = -3.8)
        let stallPos = CyberShipSceneController.targetPosition(for: .warning, warning: .stall, slotIndex: 0, totalInStation: 1)
        XCTAssertEqual(stallPos.x, 0.0, accuracy: 0.01)
        XCTAssertEqual(stallPos.z, -3.8, accuracy: 0.01)

        // 5. Almost Done: Approach launchpad (x = 3.6)
        let almostDonePos = CyberShipSceneController.targetPosition(for: .almostDone, warning: nil, slotIndex: 0, totalInStation: 1)
        XCTAssertEqual(almostDonePos.x, 3.6)

        // 6. Done: Launchpad center (x = 5.0)
        let donePos = CyberShipSceneController.targetPosition(for: .done, warning: nil, slotIndex: 0, totalInStation: 1)
        XCTAssertEqual(donePos.x, 5.0)

        // 7. Failed: Launchpad edge (x = 5.8)
        let failedPos = CyberShipSceneController.targetPosition(for: .failed, warning: nil, slotIndex: 0, totalInStation: 1)
        XCTAssertEqual(failedPos.x, 5.8)

        // 8. Idle: MedBay pod (z = 4.5)
        let idlePos = CyberShipSceneController.targetPosition(for: .idle, warning: nil, slotIndex: 0, totalInStation: 1)
        XCTAssertEqual(idlePos.x, -2.9, accuracy: 0.001)
        XCTAssertEqual(idlePos.z, 4.5, accuracy: 0.001)
    }

    // MARK: - 2. Crewmate Node Geometry & Visual Elements

    func testCrewmateNodeGeometryAndHierarchy() {
        let snapshot = makeSampleSnapshot()
        let node = CyberCatCrewmateNode(session: snapshot)

        XCTAssertEqual(node.stateKey, "claude:session-1")
        XCTAssertEqual(node.name, "CyberCatCrewmate_claude:session-1")

        // Compact Bitz Rounded Torso Box
        guard let torso = node.bodyNode.geometry as? SCNBox else {
            XCTFail("Expected bodyNode to have SCNBox geometry")
            return
        }
        XCTAssertEqual(torso.width, 0.66, accuracy: 0.001)
        XCTAssertEqual(torso.height, 0.46, accuracy: 0.001)
        XCTAssertEqual(torso.length, 0.48, accuracy: 0.001)

        // Wide Rounded Bitz Cat Head Box
        guard let head = node.bitzHeadNode.geometry as? SCNBox else {
            XCTFail("Expected bitzHeadNode to have SCNBox geometry")
            return
        }
        XCTAssertEqual(head.width, 0.94, accuracy: 0.001)
        XCTAssertEqual(head.height, 0.62, accuracy: 0.001)
        XCTAssertEqual(head.length, 0.56, accuracy: 0.001)

        // Large Pointed Ears Cone
        guard let leftEar = node.leftEarNode.geometry as? SCNCone,
              let rightEar = node.rightEarNode.geometry as? SCNCone else {
            XCTFail("Expected ear nodes to have SCNCone geometry")
            return
        }
        XCTAssertEqual(leftEar.topRadius, 0.0)
        XCTAssertEqual(leftEar.bottomRadius, 0.16, accuracy: 0.001)
        XCTAssertEqual(leftEar.height, 0.34, accuracy: 0.001)
        XCTAssertEqual(rightEar.bottomRadius, 0.16, accuracy: 0.001)

        // Wide Bitz Visor Box
        guard let visor = node.visorNode.geometry as? SCNBox else {
            XCTFail("Expected visorNode to have SCNBox geometry")
            return
        }
        XCTAssertEqual(visor.width, 0.76, accuracy: 0.001)
        XCTAssertEqual(visor.height, 0.34, accuracy: 0.001)
        XCTAssertEqual(visor.length, 0.12, accuracy: 0.001)
        XCTAssertEqual(visor.chamferRadius, 0.11, accuracy: 0.001)
        XCTAssertEqual(node.visorNode.position.z, 0.30, accuracy: 0.001)

        // Visor Eyes Plane
        guard let eyes = node.visorEyesNode.geometry as? SCNPlane else {
            XCTFail("Expected visorEyesNode to have SCNPlane geometry")
            return
        }
        XCTAssertEqual(eyes.width, 0.68, accuracy: 0.001)
        XCTAssertEqual(eyes.height, 0.28, accuracy: 0.001)
        XCTAssertEqual(node.visorEyesNode.position.z, 0.38, accuracy: 0.001)

        // Compact Power Pack Box
        guard let backpack = node.backpackNode.geometry as? SCNBox else {
            XCTFail("Expected backpackNode to have SCNBox geometry")
            return
        }
        XCTAssertEqual(backpack.width, 0.38, accuracy: 0.001)
        XCTAssertEqual(backpack.height, 0.32, accuracy: 0.001)
        XCTAssertEqual(backpack.length, 0.14, accuracy: 0.001)

        // Nameplate with Billboard Constraint
        guard let nameplate = node.nameplateNode.geometry as? SCNPlane else {
            XCTFail("Expected nameplateNode to have SCNPlane geometry")
            return
        }
        XCTAssertEqual(nameplate.width, 2.2, accuracy: 0.001)
        XCTAssertEqual(nameplate.height, 0.55, accuracy: 0.001)
        XCTAssertTrue(node.nameplateNode.constraints?.contains(where: { $0 is SCNBillboardConstraint }) ?? false)

        // Selection Torus Ring
        guard let ring = node.selectionRingNode.geometry as? SCNTorus else {
            XCTFail("Expected selectionRingNode to have SCNTorus geometry")
            return
        }
        XCTAssertEqual(ring.ringRadius, 0.55, accuracy: 0.001)
        XCTAssertEqual(ring.pipeRadius, 0.03, accuracy: 0.001)
        XCTAssertTrue(node.selectionRingNode.isHidden, "Selection ring must be hidden when not selected")
    }

    // MARK: - 3. Agent Palettes & State Colors

    func testAgentPaletteColors() {
        let claudeColor = CyberCatCrewmateNode.agentColor(for: "claude")
        let antigravityColor = CyberCatCrewmateNode.agentColor(for: "antigravity")
        let codexColor = CyberCatCrewmateNode.agentColor(for: "codex")
        let cursorColor = CyberCatCrewmateNode.agentColor(for: "cursor")
        let geminiColor = CyberCatCrewmateNode.agentColor(for: "gemini")
        let otherColor = CyberCatCrewmateNode.agentColor(for: "custom_unknown")

        XCTAssertEqual(claudeColor.redComponent, 0.851, accuracy: 0.01)
        XCTAssertEqual(antigravityColor.redComponent, 0.451, accuracy: 0.01)
        XCTAssertEqual(codexColor.greenComponent, 0.702, accuracy: 0.01)
        XCTAssertEqual(cursorColor.blueComponent, 0.800, accuracy: 0.01)
        XCTAssertEqual(geminiColor.blueComponent, 0.949, accuracy: 0.01)
        XCTAssertEqual(otherColor.redComponent, 0.400, accuracy: 0.01)

        // Verify distinct provider body colors are applied to the 3D Bitz chassis
        let claudeNode = CyberCatCrewmateNode(session: makeSampleSnapshot(stateKey: "claude:c1", agentID: "claude"))
        let antigravityNode = CyberCatCrewmateNode(session: makeSampleSnapshot(stateKey: "antigravity:a1", agentID: "antigravity"))
        let claudeBody = claudeNode.bodyNode.geometry?.firstMaterial?.diffuse.contents as? NSColor
        let antigravityBody = antigravityNode.bodyNode.geometry?.firstMaterial?.diffuse.contents as? NSColor
        XCTAssertEqual(claudeBody?.redComponent ?? 0, claudeColor.redComponent, accuracy: 0.01)
        XCTAssertEqual(antigravityBody?.redComponent ?? 0, antigravityColor.redComponent, accuracy: 0.01)
        XCTAssertNotEqual(claudeBody?.redComponent ?? 0, antigravityBody?.redComponent ?? 0, accuracy: 0.1)
    }

    func testLifecycleStateColors() {
        let amber = AgentSessionLifecycleState.needsApproval.nsColor
        let crimson = AgentSessionLifecycleState.warning.nsColor
        let red = AgentSessionLifecycleState.failed.nsColor
        let brightCyan = AgentSessionLifecycleState.almostDone.nsColor
        let green = AgentSessionLifecycleState.working.nsColor
        let happyGreen = AgentSessionLifecycleState.done.nsColor
        let dimBlue = AgentSessionLifecycleState.idle.nsColor

        XCTAssertEqual(amber.redComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(crimson.redComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(red.redComponent, 0.95, accuracy: 0.05)
        XCTAssertEqual(brightCyan.blueComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(green.greenComponent, 0.9, accuracy: 0.01)
        XCTAssertEqual(happyGreen.greenComponent, 0.85, accuracy: 0.05)
        XCTAssertEqual(dimBlue.blueComponent, 0.9, accuracy: 0.01)
    }

    // MARK: - 4. Selection Toggling

    func testSelectionTogglingVisuals() {
        let snapshot = makeSampleSnapshot()
        let node = CyberCatCrewmateNode(session: snapshot)

        XCTAssertFalse(node.isSelected)
        XCTAssertTrue(node.selectionRingNode.isHidden)
        XCTAssertNil(node.selectionRingNode.action(forKey: "selectionPulse"))

        node.isSelected = true
        XCTAssertTrue(node.isSelected)
        XCTAssertFalse(node.selectionRingNode.isHidden)
        XCTAssertNotNil(node.selectionRingNode.action(forKey: "selectionPulse"))

        node.isSelected = false
        XCTAssertFalse(node.isSelected)
        XCTAssertTrue(node.selectionRingNode.isHidden)
        XCTAssertNil(node.selectionRingNode.action(forKey: "selectionPulse"))
    }

    // MARK: - 5. State Behaviors & Accessories

    func testStateBehaviorAccessories() {
        let snapshotWorking = makeSampleSnapshot(state: .working)
        let node = CyberCatCrewmateNode(session: snapshotWorking)

        XCTAssertTrue(node.beaconNode.isHidden)
        XCTAssertTrue(node.hazardNode.isHidden)
        XCTAssertNotNil(node.modelContainerNode.action(forKey: "stateBehavior"))

        // Transition to needsApproval activates beacon
        let snapshotApproval = makeSampleSnapshot(state: .needsApproval)
        node.update(with: snapshotApproval)
        XCTAssertFalse(node.beaconNode.isHidden)
        XCTAssertNotNil(node.beaconNode.action(forKey: "beaconPulse"))
        XCTAssertTrue(node.hazardNode.isHidden)

        // Transition to warning(.context) activates hazard
        let snapshotWarning = makeSampleSnapshot(state: .warning, warning: .context)
        node.update(with: snapshotWarning)
        XCTAssertTrue(node.beaconNode.isHidden)
        XCTAssertFalse(node.hazardNode.isHidden)
        XCTAssertNotNil(node.hazardNode.action(forKey: "hazardPulse"))

        // Transition to warning(.loop) deactivates hazard (uses frantic loop)
        let snapshotLoop = makeSampleSnapshot(state: .warning, warning: .loop)
        node.update(with: snapshotLoop)
        XCTAssertTrue(node.hazardNode.isHidden)
        XCTAssertTrue(node.beaconNode.isHidden)
    }

    // MARK: - 6. CyberShipSceneController Initialization & Structure

    func testSceneControllerInitialDeckStructure() {
        let controller = CyberShipSceneController()

        // Verify camera setup
        guard let camera = controller.cameraNode.camera else {
            XCTFail("Expected cameraNode to have SCNCamera")
            return
        }
        XCTAssertTrue(camera.usesOrthographicProjection)
        XCTAssertEqual(camera.orthographicScale, 8.4, accuracy: 0.01)
        XCTAssertEqual(controller.cameraNode.position.y, 12.0)
        XCTAssertEqual(controller.cameraNode.position.z, 12.0)

        // Verify lights in scene
        XCTAssertNotNil(controller.ambientLightNode.light)
        XCTAssertEqual(controller.ambientLightNode.light?.type, .ambient)
        XCTAssertNotNil(controller.directionalLightNode.light)
        XCTAssertEqual(controller.directionalLightNode.light?.type, .directional)

        // Verify station point lights
        XCTAssertEqual(controller.codeBayLightNode.light?.type, .omni)
        XCTAssertEqual(controller.emergencyLightNode.light?.type, .omni)
        XCTAssertEqual(controller.reactorLightNode.light?.type, .omni)
        XCTAssertEqual(controller.launchpadLightNode.light?.type, .omni)
        XCTAssertEqual(controller.medBayLightNode.light?.type, .omni)

        // Verify 5 station nodes attached to root
        XCTAssertNotNil(controller.scene.rootNode.childNode(withName: "Station_CodeBay", recursively: false))
        XCTAssertNotNil(controller.scene.rootNode.childNode(withName: "Station_EmergencyTable", recursively: false))
        XCTAssertNotNil(controller.scene.rootNode.childNode(withName: "Station_Reactor", recursively: false))
        XCTAssertNotNil(controller.scene.rootNode.childNode(withName: "Station_Launchpad", recursively: false))
        XCTAssertNotNil(controller.scene.rootNode.childNode(withName: "Station_MedBay", recursively: false))

        // Verify deck floor
        XCTAssertNotNil(controller.scene.rootNode.childNode(withName: "DeckFloor", recursively: false))
    }

    // MARK: - 7. Session Synchronization (Add, Update, Remove)

    func testSessionSynchronizationLifecycle() {
        let controller = CyberShipSceneController()
        XCTAssertEqual(controller.crewmateNodes.count, 0)

        // 1. Add two sessions
        let s1 = makeSampleSnapshot(stateKey: "claude:1", agentID: "claude", state: .working)
        let s2 = makeSampleSnapshot(stateKey: "antigravity:1", agentID: "antigravity", state: .needsApproval)

        controller.syncSessions([s1, s2], selectedSessionKey: "claude:1")

        XCTAssertEqual(controller.crewmateNodes.count, 2)
        XCTAssertNotNil(controller.crewmateNodes["claude:1"])
        XCTAssertNotNil(controller.crewmateNodes["antigravity:1"])

        XCTAssertTrue(controller.crewmateNodes["claude:1"]?.isSelected ?? false)
        XCTAssertFalse(controller.crewmateNodes["antigravity:1"]?.isSelected ?? true)

        // 2. Update existing session
        let s1Updated = makeSampleSnapshot(stateKey: "claude:1", agentID: "claude", state: .done)
        controller.syncSessions([s1Updated, s2], selectedSessionKey: "antigravity:1")

        XCTAssertEqual(controller.crewmateNodes.count, 2)
        XCTAssertEqual(controller.crewmateNodes["claude:1"]?.sessionSnapshot.lifecycleState, .done)
        XCTAssertFalse(controller.crewmateNodes["claude:1"]?.isSelected ?? true)
        XCTAssertTrue(controller.crewmateNodes["antigravity:1"]?.isSelected ?? false)

        // 3. Remove one session
        controller.syncSessions([s1Updated], selectedSessionKey: "claude:1")

        XCTAssertEqual(controller.crewmateNodes.count, 1)
        XCTAssertNil(controller.crewmateNodes["antigravity:1"])
        XCTAssertNotNil(controller.crewmateNodes["claude:1"])
    }

    // MARK: - 8. Hit-Testing Resolution

    func testHitTestingResolution() {
        let controller = CyberShipSceneController()
        let s1 = makeSampleSnapshot(stateKey: "claude:1", agentID: "claude", state: .working)
        controller.syncSessions([s1], selectedSessionKey: nil)

        let crewmate = controller.crewmateNodes["claude:1"]!

        // Subnodes of crewmate resolve to the parent CyberCatCrewmateNode
        XCTAssertTrue(controller.crewmateNode(for: crewmate.bodyNode) === crewmate)
        XCTAssertTrue(controller.crewmateNode(for: crewmate.leftEarNode) === crewmate)
        XCTAssertTrue(controller.crewmateNode(for: crewmate.rightEarNode) === crewmate)
        XCTAssertTrue(controller.crewmateNode(for: crewmate.visorNode) === crewmate)
        XCTAssertTrue(controller.crewmateNode(for: crewmate.backpackNode) === crewmate)
        XCTAssertTrue(controller.crewmateNode(for: crewmate.selectionRingNode) === crewmate)
        XCTAssertTrue(controller.crewmateNode(for: crewmate) === crewmate)

        // Non-crewmate nodes return nil
        XCTAssertNil(controller.crewmateNode(for: controller.deckFloorNode))
        XCTAssertNil(controller.crewmateNode(for: controller.emergencyTableNode))
        XCTAssertNil(controller.crewmateNode(for: controller.reactorNode))
        XCTAssertNil(controller.crewmateNode(for: controller.scene.rootNode))
    }

    // MARK: - 9. Occlusion Pause State Mapping in CyberShipSceneView

    func testCyberShipSceneViewOcclusionPauseMapping() {
        var selectedKey: String? = nil
        let s1 = makeSampleSnapshot()

        let sceneView = CyberShipSceneView(
            sessions: [s1],
            selectedSessionKey: "claude:session-1",
            isWindowVisible: true,
            onSelectSession: { key in
                selectedKey = key
            }
        )

        let coordinator = sceneView.makeCoordinator()
        let scnView = CyberShipSCNView(frame: .zero)
        sceneView.configureView(scnView, coordinator: coordinator)

        XCTAssertNil(selectedKey)

        // When window is visible, isPlaying is true
        XCTAssertTrue(scnView.isPlaying)
        XCTAssertTrue(scnView.rendersContinuously)
        XCTAssertEqual(scnView.preferredFramesPerSecond, 60)
        XCTAssertEqual(scnView.antialiasingMode, .multisampling4X)

        // When window becomes invisible (occluded / miniaturized), updateView pauses the display link
        let invisibleSceneView = CyberShipSceneView(
            sessions: [s1],
            selectedSessionKey: "claude:session-1",
            isWindowVisible: false,
            onSelectSession: { _ in }
        )
        invisibleSceneView.updateView(scnView, coordinator: coordinator)
        XCTAssertFalse(scnView.isPlaying, "Occluded or miniaturized window must halt SCNView.isPlaying to achieve 0.0% CPU")

        // When window becomes visible again, display link resumes
        let visibleAgainSceneView = CyberShipSceneView(
            sessions: [s1],
            selectedSessionKey: "claude:session-1",
            isWindowVisible: true,
            onSelectSession: { _ in }
        )
        visibleAgainSceneView.updateView(scnView, coordinator: coordinator)
        XCTAssertTrue(scnView.isPlaying, "Restored window visibility must resume SCNView.isPlaying")

        // Teardown
        CyberShipSceneView.dismantleNSView(scnView, coordinator: coordinator)
        XCTAssertFalse(scnView.isPlaying)
        XCTAssertNil(scnView.scene)
    }

    // MARK: - 10. Synchronous Node Removal & Zero Orphaned Nodes

    func testSynchronousNodeRemovalAndNoOrphans() {
        let controller = CyberShipSceneController()
        let initialRootChildrenCount = controller.scene.rootNode.childNodes.count
        XCTAssertEqual(initialRootChildrenCount, 18, "Expected 18 baseline station/deck/camera/light nodes")

        // Add 10 sessions
        let sessions = (1...10).map { i in
            makeSampleSnapshot(
                stateKey: "claude:\(i)",
                agentID: "claude",
                sessionID: "\(i)",
                state: i % 2 == 0 ? .working : .needsApproval
            )
        }
        controller.syncSessions(sessions, selectedSessionKey: nil)

        XCTAssertEqual(controller.crewmateNodes.count, 10)
        XCTAssertEqual(controller.scene.rootNode.childNodes.count, initialRootChildrenCount + 10)

        // Remove all sessions synchronously
        controller.syncSessions([], selectedSessionKey: nil)

        XCTAssertEqual(controller.crewmateNodes.count, 0)
        XCTAssertEqual(
            controller.scene.rootNode.childNodes.count,
            initialRootChildrenCount,
            "All crewmate nodes must be immediately detached synchronously, leaving 0 orphaned nodes"
        )

        // Verify none of the removed crewmate nodes have parent nodes
        let orphanNodes = controller.scene.rootNode.childNodes.filter {
            $0.name?.starts(with: "CyberCatCrewmate_") == true
        }
        XCTAssertEqual(orphanNodes.count, 0, "No orphaned CyberCatCrewmate nodes should exist in rootNode")

        // Re-adding a session must create exactly one instance without stacking duplicate nodes
        let singleSession = makeSampleSnapshot(stateKey: "claude:1", agentID: "claude", state: .working)
        controller.syncSessions([singleSession], selectedSessionKey: nil)

        let matchingNodes = controller.scene.rootNode.childNodes.filter {
            $0.name == "CyberCatCrewmate_claude:1"
        }
        XCTAssertEqual(matchingNodes.count, 1, "Must never stack duplicate instances on re-add")
    }

    // MARK: - 11. Negative Slot Index Safety in Target Position

    func testTargetPositionNegativeSlotIndexSafety() {
        let testStates: [AgentSessionLifecycleState] = [
            .working, .needsApproval, .warning, .almostDone, .done, .failed, .idle
        ]

        for state in testStates {
            let posNeg1 = CyberShipSceneController.targetPosition(for: state, warning: nil, slotIndex: -1, totalInStation: 3)
            let posNeg5 = CyberShipSceneController.targetPosition(for: state, warning: nil, slotIndex: -5, totalInStation: 3)
            let posZero = CyberShipSceneController.targetPosition(for: state, warning: nil, slotIndex: 0, totalInStation: 3)

            XCTAssertFalse(posNeg1.x.isNaN)
            XCTAssertFalse(posNeg1.y.isNaN)
            XCTAssertFalse(posNeg1.z.isNaN)
            XCTAssertTrue(posNeg1.x.isFinite)

            XCTAssertFalse(posNeg5.x.isNaN)
            XCTAssertFalse(posNeg5.y.isNaN)
            XCTAssertFalse(posNeg5.z.isNaN)
            XCTAssertTrue(posNeg5.x.isFinite)

            // Negative indices must clamp to safe slot 0
            XCTAssertEqual(posNeg1.x, posZero.x, accuracy: 0.001)
            XCTAssertEqual(posNeg1.y, posZero.y, accuracy: 0.001)
            XCTAssertEqual(posNeg1.z, posZero.z, accuracy: 0.001)

            XCTAssertEqual(posNeg5.x, posZero.x, accuracy: 0.001)
            XCTAssertEqual(posNeg5.y, posZero.y, accuracy: 0.001)
            XCTAssertEqual(posNeg5.z, posZero.z, accuracy: 0.001)
        }

        // Warning state variants
        let loopNeg = CyberShipSceneController.targetPosition(for: .warning, warning: .loop, slotIndex: -2, totalInStation: 2)
        let loopZero = CyberShipSceneController.targetPosition(for: .warning, warning: .loop, slotIndex: 0, totalInStation: 2)
        XCTAssertEqual(loopNeg.x, loopZero.x, accuracy: 0.001)
        XCTAssertEqual(loopNeg.z, loopZero.z, accuracy: 0.001)

        let stallNeg = CyberShipSceneController.targetPosition(for: .warning, warning: .stall, slotIndex: -3, totalInStation: 2)
        let stallZero = CyberShipSceneController.targetPosition(for: .warning, warning: .stall, slotIndex: 0, totalInStation: 2)
        XCTAssertEqual(stallNeg.x, stallZero.x, accuracy: 0.001)
        XCTAssertEqual(stallNeg.z, stallZero.z, accuracy: 0.001)
    }

    // MARK: - 12. Transform & Scale Reset Across State Transitions

    func testTransformAndScaleResetAcrossStateTransitions() {
        let idleSnapshot = makeSampleSnapshot(state: .idle)
        let node = CyberCatCrewmateNode(session: idleSnapshot)

        // Mutate scale and position to simulate breathing/recline or state artifact
        node.modelContainerNode.scale = SCNVector3(1.04, 1.04, 1.04)
        node.modelContainerNode.position = SCNVector3(0, 0.4, 0)
        node.modelContainerNode.eulerAngles = SCNVector3(0.3, 0.2, 0.1)

        // Transition: .idle -> .working
        let workingSnapshot = makeSampleSnapshot(state: .working)
        node.update(with: workingSnapshot)

        XCTAssertEqual(node.modelContainerNode.scale.x, 1.0, accuracy: 0.001, "Scale must reset to 1.0")
        XCTAssertEqual(node.modelContainerNode.scale.y, 1.0, accuracy: 0.001, "Scale must reset to 1.0")
        XCTAssertEqual(node.modelContainerNode.scale.z, 1.0, accuracy: 0.001, "Scale must reset to 1.0")
        XCTAssertEqual(node.modelContainerNode.position.x, 0.0, accuracy: 0.001, "Position X must reset to 0.0")
        XCTAssertEqual(node.modelContainerNode.position.y, 0.0, accuracy: 0.001, "Position Y must reset to 0.0")
        XCTAssertEqual(node.modelContainerNode.position.z, 0.0, accuracy: 0.001, "Position Z must reset to 0.0")
        XCTAssertEqual(node.modelContainerNode.eulerAngles.x, 0.0, accuracy: 0.001, "Euler angles must reset to 0.0")
        XCTAssertEqual(node.modelContainerNode.eulerAngles.y, 0.0, accuracy: 0.001, "Euler angles must reset to 0.0")
        XCTAssertEqual(node.modelContainerNode.eulerAngles.z, 0.0, accuracy: 0.001, "Euler angles must reset to 0.0")

        // Transition: .working -> .failed (simulates KO fall)
        let failedSnapshot = makeSampleSnapshot(state: .failed)
        node.update(with: failedSnapshot)
        node.modelContainerNode.position = SCNVector3(0, 0.2, 0)
        node.modelContainerNode.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)

        // Transition: .failed -> .almostDone (sprint to launchpad)
        let almostDoneSnapshot = makeSampleSnapshot(state: .almostDone)
        node.update(with: almostDoneSnapshot)

        XCTAssertEqual(node.modelContainerNode.scale.x, 1.0, accuracy: 0.001, "Scale must reset to 1.0 on almostDone")
        XCTAssertEqual(node.modelContainerNode.position.y, 0.0, accuracy: 0.001, "Position Y must reset to 0.0 (no KO float)")
        XCTAssertEqual(node.modelContainerNode.position.x, 0.0, accuracy: 0.001, "Position X must reset to 0.0")
        XCTAssertEqual(node.modelContainerNode.position.z, 0.0, accuracy: 0.001, "Position Z must reset to 0.0")
    }

    // MARK: - 13. Bitz Anatomy, Visual Action Props & Action Headlines

    func testCrewmateBitzAnatomyAndVisualActionProps() {
        let workingSnapshot = makeSampleSnapshot(state: .working)
        let node = CyberCatCrewmateNode(session: workingSnapshot)

        // Verify signature Bitz anatomical nodes are attached
        XCTAssertTrue(node.bitzHeadNode.parent === node.modelContainerNode)
        XCTAssertTrue(node.leftInnerEarNode.parent === node.leftEarNode)
        XCTAssertTrue(node.rightInnerEarNode.parent === node.rightEarNode)
        XCTAssertTrue(node.chestEmblemNode.parent === node.modelContainerNode)
        XCTAssertTrue(node.tailNode.parent === node.modelContainerNode)
        XCTAssertTrue(node.leftPawNode.parent === node.modelContainerNode)
        XCTAssertTrue(node.rightPawNode.parent === node.modelContainerNode)

        // Working state shows holographic keyboard & hides sleep/loop/done props
        XCTAssertFalse(node.workHoloNode.isHidden)
        XCTAssertTrue(node.sleepZzzNode.isHidden)
        XCTAssertTrue(node.loopRingNode.isHidden)
        XCTAssertTrue(node.doneBadgeNode.isHidden)
        XCTAssertEqual(CyberCatCrewmateNode.actionHeadline(for: workingSnapshot), "⌨️ CODING NOW")

        // Idle state shows Zzz bubbles and hides work holo
        let idleSnapshot = makeSampleSnapshot(state: .idle)
        node.update(with: idleSnapshot)
        XCTAssertTrue(node.workHoloNode.isHidden)
        XCTAssertFalse(node.sleepZzzNode.isHidden)
        XCTAssertEqual(CyberCatCrewmateNode.actionHeadline(for: idleSnapshot), "💤 SLEEPING · IDLE")

        // Loop warning unhides spinning crimson ring
        let loopSnapshot = makeSampleSnapshot(state: .warning, warning: .loop)
        node.update(with: loopSnapshot)
        XCTAssertFalse(node.loopRingNode.isHidden)
        XCTAssertTrue(node.sleepZzzNode.isHidden)
        XCTAssertEqual(CyberCatCrewmateNode.actionHeadline(for: loopSnapshot), "🔄 STUCK IN LOOP!")

        // Done unhides celebratory checkmark badge
        let doneSnapshot = makeSampleSnapshot(state: .done)
        node.update(with: doneSnapshot)
        XCTAssertFalse(node.doneBadgeNode.isHidden)
        XCTAssertTrue(node.loopRingNode.isHidden)
        XCTAssertEqual(CyberCatCrewmateNode.actionHeadline(for: doneSnapshot), "✅ TASK COMPLETE")

        // Needs approval raises both paws high
        let approvalSnapshot = makeSampleSnapshot(state: .needsApproval)
        node.update(with: approvalSnapshot)
        XCTAssertGreaterThan(node.leftPawNode.position.y, 0.8)
        XCTAssertGreaterThan(node.rightPawNode.position.y, 0.8)
        XCTAssertEqual(CyberCatCrewmateNode.actionHeadline(for: approvalSnapshot), "✋ NEEDS APPROVAL!")
    }

    // MARK: - 14. Dynamic Personal Desks/Nests & Inter-Agent Message Delivery Walk

    func testDynamicDesksNestsAndInterAgentMessageWalk() throws {
        let controller = CyberShipSceneController()
        let baselineRootCount = controller.scene.rootNode.childNodes.count
        XCTAssertEqual(baselineRootCount, 18)

        // Baseline station capacity
        XCTAssertEqual(controller.provisionedDeskCount, 3)
        XCTAssertEqual(controller.provisionedNestCount, 3)

        // Sync 5 idle + 4 working sessions -> should dynamically provision 5 nests & 4 desks
        let sessions: [AgentSessionSnapshot] = (1...5).map { idx in
            makeSampleSnapshot(
                stateKey: "idle:\(idx)",
                agentID: "antigravity",
                agentName: "Antigravity",
                sessionID: "idle-\(idx)",
                state: .idle
            )
        } + (1...4).map { idx in
            makeSampleSnapshot(
                stateKey: "work:\(idx)",
                agentID: "claude",
                agentName: "Claude",
                sessionID: "work-\(idx)",
                state: .working
            )
        }

        controller.syncSessions(sessions, selectedSessionKey: "work:1")

        XCTAssertEqual(controller.provisionedNestCount, 5)
        XCTAssertEqual(controller.provisionedDeskCount, 4)

        let nestNodes = controller.medBayNode.childNodes.filter { $0.name?.hasPrefix("MedBayNest_") == true }
        XCTAssertEqual(nestNodes.count, 5, "MedBay must contain one physical nest per idle session")

        // Verify unique non-overlapping coordinates for all 5 idle nests
        let uniqueNestKeys = Set(nestNodes.map { "\(Int(round($0.position.x * 10)))_\(Int(round($0.position.z * 10)))" })
        XCTAssertEqual(uniqueNestKeys.count, 5, "All 5 MedBay nests must occupy distinct non-overlapping positions")

        // Trigger inter-agent communication delivery walk
        controller.triggerMessageDelivery(from: "work:1", to: "idle:1")
        let senderNode = try XCTUnwrap(controller.crewmateNodes["work:1"])
        XCTAssertFalse(senderNode.messagePacketNode.isHidden, "Sender must hold glowing 3D message packet during delivery")
        XCTAssertNotNil(senderNode.activeCommsBanner, "Sender nameplate must display active delivery banner")
        XCTAssertNotNil(senderNode.action(forKey: "commsWalk"), "Sender must execute commsWalk animation toward peer")
        XCTAssertEqual(controller.lastCommsPair?.sender, "work:1")
        XCTAssertEqual(controller.lastCommsPair?.recipient, "idle:1")

        // Removing all sessions cleanly removes all crewmates without leaving orphans on rootNode
        controller.syncSessions([], selectedSessionKey: nil)
        XCTAssertEqual(controller.scene.rootNode.childNodes.count, baselineRootCount)
    }

    // MARK: - 15. Multi-Crewmate Non-Overlap & Low-Profile Code Bay Mats

    func testCrewmatesNeverOverlapAcrossStationsAndMixedWarnings() throws {
        let controller = CyberShipSceneController()

        let workingSessions = (1...6).map { idx in
            makeSampleSnapshot(
                stateKey: "work:\(idx)",
                agentID: "claude",
                agentName: "Claude",
                sessionID: "work-\(idx)",
                state: .working
            )
        }
        let idleSessions = (1...6).map { idx in
            makeSampleSnapshot(
                stateKey: "idle:\(idx)",
                agentID: "antigravity",
                agentName: "Antigravity",
                sessionID: "idle-\(idx)",
                state: .idle
            )
        }
        let doneSessions = (1...3).map { idx in
            makeSampleSnapshot(
                stateKey: "done:\(idx)",
                agentID: "codex",
                agentName: "Codex",
                sessionID: "done-\(idx)",
                state: .done
            )
        }
        let mixedWarningSessions: [AgentSessionSnapshot] = [
            makeSampleSnapshot(stateKey: "warn:stall", agentID: "claude", sessionID: "w1", state: .warning, warning: .stall),
            makeSampleSnapshot(stateKey: "warn:context", agentID: "gemini", sessionID: "w2", state: .warning, warning: .context),
            makeSampleSnapshot(stateKey: "warn:rate", agentID: "cursor", sessionID: "w3", state: .warning, warning: .rateLimit)
        ]

        let allSessions = workingSessions + idleSessions + doneSessions + mixedWarningSessions
        controller.syncSessions(allSessions, selectedSessionKey: nil)

        XCTAssertEqual(controller.crewmateNodes.count, allSessions.count)

        let placedPositions: [(key: String, pos: SCNVector3)] = allSessions.compactMap { session in
            guard let node = controller.crewmateNodes[session.stateKey] else { return nil }
            return (session.stateKey, node.position)
        }
        XCTAssertEqual(placedPositions.count, allSessions.count)

        for i in 0..<placedPositions.count {
            for j in (i + 1)..<placedPositions.count {
                let a = placedPositions[i]
                let b = placedPositions[j]
                let distance = hypot(a.pos.x - b.pos.x, a.pos.z - b.pos.z)
                XCTAssertGreaterThanOrEqual(
                    distance,
                    2.2,
                    "Crewmates \(a.key) and \(b.key) are too close (\(distance)) and would overlap"
                )
            }
        }

        // Verify Code Bay uses low-profile workstation mats centered directly at each working slot without redundant monitor screens
        let deskNodes = controller.codeBayNode.childNodes.filter { $0.name?.hasPrefix("CodeBayDesk_") == true }
        XCTAssertEqual(deskNodes.count, 6)
        for slotIdx in 0..<6 {
            let desk = try XCTUnwrap(deskNodes.first(where: { $0.name == "CodeBayDesk_\(slotIdx)" }))
            XCTAssertFalse(desk.isHidden, "Occupied Code Bay mat \(slotIdx) must be visible")

            let expectedSlot = CyberShipSceneController.codeBaySlotPosition(for: slotIdx)
            XCTAssertEqual(desk.position.x, expectedSlot.x - CyberShipSceneController.codeBayCenter.x, accuracy: 0.001)
            XCTAssertEqual(desk.position.z, expectedSlot.z - CyberShipSceneController.codeBayCenter.z, accuracy: 0.001)

            let hasMonitorScreen = desk.childNodes.contains { $0.geometry is SCNPlane }
            XCTAssertFalse(hasMonitorScreen, "Code Bay mat \(slotIdx) must not render a redundant desktop screen plane")

            let maxChildHeight = desk.childNodes.compactMap { ($0.geometry as? SCNBox)?.height }.max() ?? 0
            XCTAssertLessThanOrEqual(maxChildHeight, 0.06, "Code Bay mat \(slotIdx) must stay low-profile")
        }

        // Verify responsive viewport camera scaling prevents horizontal overflow on narrow/square windows
        controller.updateCameraForViewport(size: CGSize(width: 900, height: 900))
        XCTAssertGreaterThanOrEqual(controller.cameraNode.camera?.orthographicScale ?? 0, 10.2)
        controller.updateCameraForViewport(size: CGSize(width: 1800, height: 800))
        XCTAssertEqual(controller.cameraNode.camera?.orthographicScale ?? 0, 8.4, accuracy: 0.05)

        // Verify stable desk pinning: reversing session order (simulating lastActivity changes) must not move crewmates
        let initialPositionsByKey = Dictionary(
            uniqueKeysWithValues: workingSessions.compactMap { s in
                controller.crewmateNodes[s.stateKey].map { (s.stateKey, $0.position) }
            }
        )
        let reorderedSessions = workingSessions.reversed() + idleSessions.reversed() + doneSessions + mixedWarningSessions
        controller.syncSessions(reorderedSessions, selectedSessionKey: nil)
        for session in workingSessions {
            let expectedPos = try XCTUnwrap(initialPositionsByKey[session.stateKey])
            let currentNode = try XCTUnwrap(controller.crewmateNodes[session.stateKey])
            XCTAssertEqual(currentNode.position.x, expectedPos.x, accuracy: 0.001)
            XCTAssertEqual(currentNode.position.z, expectedPos.z, accuracy: 0.001)
            XCTAssertFalse(currentNode.hasActions, "Reordering by lastActivity must not animate a desk swap")
        }
    }

    func testProviderSkinsCreateDistinct3DAccessoriesPerAgent() throws {
        let cases: [(agentID: String, expectedSkin: CyberCatCrewmateNode.AgentProviderSkin, expectedNodeNames: [String])] = [
            ("claude-code", .claude, ["CrewmateSkin_ClaudeSpark", "CrewmateSkin_ClaudeCollar"]),
            ("antigravity", .antigravity, ["CrewmateSkin_AntigravityHalo", "CrewmateSkin_AntigravityLeftWing", "CrewmateSkin_AntigravityRightWing"]),
            ("gemini-cli", .gemini, ["CrewmateSkin_GeminiStarPrimary", "CrewmateSkin_GeminiStarSecondary"]),
            ("codex", .codex, ["CrewmateSkin_CodexLeftCup", "CrewmateSkin_CodexRightCup", "CrewmateSkin_CodexBand"]),
            ("cursor", .cursor, ["CrewmateSkin_CursorBlade", "CrewmateSkin_CursorLeftFin", "CrewmateSkin_CursorRightFin"]),
            ("custom-agent", .defaultCyber, ["CrewmateSkin_DefaultStalk", "CrewmateSkin_DefaultTip"])
        ]

        for entry in cases {
            XCTAssertEqual(CyberCatCrewmateNode.AgentProviderSkin.resolve(for: entry.agentID), entry.expectedSkin)

            let snapshot = makeSampleSnapshot(
                stateKey: "\(entry.agentID):skin-test",
                agentID: entry.agentID,
                agentName: entry.agentID
            )
            let node = CyberCatCrewmateNode(session: snapshot)
            XCTAssertEqual(node.providerSkin, entry.expectedSkin)
            XCTAssertEqual(node.providerSkinNode.parent, node.modelContainerNode)

            let childNames = Set(node.providerSkinNode.childNodes.compactMap(\.name))
            for expectedName in entry.expectedNodeNames {
                XCTAssertTrue(
                    childNames.contains(expectedName),
                    "Expected skin \(entry.expectedSkin.rawValue) for \(entry.agentID) to create node '\(expectedName)', got \(childNames)"
                )
            }
        }

        // Dynamic update to a different agentID must swap the skin and accessory nodes cleanly
        let dynamicNode = CyberCatCrewmateNode(
            session: makeSampleSnapshot(stateKey: "swap:1", agentID: "claude-code", agentName: "Claude")
        )
        XCTAssertEqual(dynamicNode.providerSkin, .claude)
        XCTAssertNotNil(dynamicNode.providerSkinNode.childNode(withName: "CrewmateSkin_ClaudeSpark", recursively: false))

        dynamicNode.update(
            with: makeSampleSnapshot(stateKey: "swap:1", agentID: "codex", agentName: "Codex")
        )
        XCTAssertEqual(dynamicNode.providerSkin, .codex)
        XCTAssertNil(dynamicNode.providerSkinNode.childNode(withName: "CrewmateSkin_ClaudeSpark", recursively: false))
        XCTAssertNotNil(dynamicNode.providerSkinNode.childNode(withName: "CrewmateSkin_CodexLeftCup", recursively: false))
    }

    func testEmptyCodeBayHidesAllWorkstationMats() throws {
        let controller = CyberShipSceneController()

        let initialDesks = controller.codeBayNode.childNodes.filter { $0.name?.hasPrefix("CodeBayDesk_") == true }
        let initialNests = controller.medBayNode.childNodes.filter { $0.name?.hasPrefix("MedBayNest_") == true }
        XCTAssertEqual(initialDesks.count, 3)
        XCTAssertEqual(initialNests.count, 3)
        XCTAssertTrue(initialDesks.allSatisfy(\.isHidden), "Empty Code Bay on init must hide all workstation mats")
        XCTAssertTrue(initialNests.allSatisfy(\.isHidden), "Empty MedBay on init must hide all sleeping nests")

        // Sync only idle + needsApproval sessions (0 working sessions)
        let sessions = [
            makeSampleSnapshot(stateKey: "idle:1", agentID: "antigravity", sessionID: "idle-1", state: .idle),
            makeSampleSnapshot(stateKey: "approval:1", agentID: "claude", sessionID: "app-1", state: .needsApproval)
        ]
        controller.syncSessions(sessions, selectedSessionKey: "approval:1")

        XCTAssertTrue(
            controller.codeBayNode.childNodes
                .filter { $0.name?.hasPrefix("CodeBayDesk_") == true }
                .allSatisfy(\.isHidden),
            "Code Bay must hide all workstation mats when 0 working sessions exist"
        )
        let desk0 = try XCTUnwrap(controller.codeBayNode.childNode(withName: "CodeBayDesk_0", recursively: false))
        XCTAssertTrue(desk0.isHidden)
        let nest0 = try XCTUnwrap(controller.medBayNode.childNode(withName: "MedBayNest_0", recursively: false))
        XCTAssertFalse(nest0.isHidden, "Occupied MedBay nest must be visible")

        // Adding a working session reveals only its occupied mat
        let withWorking = sessions + [
            makeSampleSnapshot(stateKey: "work:1", agentID: "claude", sessionID: "work-1", state: .working)
        ]
        controller.syncSessions(withWorking, selectedSessionKey: "work:1")
        XCTAssertFalse(desk0.isHidden, "Occupied Code Bay mat must become visible")
        let desk1 = try XCTUnwrap(controller.codeBayNode.childNode(withName: "CodeBayDesk_1", recursively: false))
        XCTAssertTrue(desk1.isHidden, "Unoccupied Code Bay mats must remain hidden")
    }
}
