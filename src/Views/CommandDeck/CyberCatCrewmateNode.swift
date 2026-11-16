import SceneKit
import AppKit

/// Procedural 3D SceneKit representation of an AI agent crewmate aboard the Cyber-Ship,
/// modeled after **Bitz the Cyber Cat** with agent-specific neon accents.
///
/// Features:
/// - Signature Bitz dark obsidian chassis (`#1A1C29`) with rounded cat head silhouette, pointed
///   cyber-cat ears with glowing inner triangles, agent-colored visor rim, chest core emblem,
///   articulated front paws, and swishing cyber-tail.
/// - Backpack core with thrusters and vertical context-level LED gauge.
/// - State-specific 3D action props: holographic laptop & alternating typing paws (`.working`),
///   raised waving paws + amber beacon (`.needsApproval`), spinning vortex ring (`.warning(.loop)`),
///   panicked pose + hazard icon (`.warning`), floating `"Z z z"` sleep bubbles (`.idle`),
///   celebratory `"✓"` star badge (`.done`), and 3D data packet (`messagePacketNode`) for comms walks.
/// - Action-first billboard nameplate displaying clear activity headline, session label, and context %.
public final class CyberCatCrewmateNode: SCNNode, @unchecked Sendable {

    // MARK: - Provider Skins

    /// Distinct 3D headgear and chassis silhouette per AI provider so crewmates remain
    /// instantly recognizable alongside their neon accent color.
    public enum AgentProviderSkin: String, CaseIterable, Sendable {
        case claude
        case antigravity
        case gemini
        case codex
        case cursor
        case defaultCyber

        public static func resolve(for agentID: String) -> AgentProviderSkin {
            let normalized = agentID.lowercased()
            if normalized.contains("claude") {
                return .claude
            } else if normalized.contains("antigravity") {
                return .antigravity
            } else if normalized.contains("gemini") {
                return .gemini
            } else if normalized.contains("codex") || normalized.contains("openai") || normalized.contains("chatgpt") {
                return .codex
            } else if normalized.contains("cursor") {
                return .cursor
            } else {
                return .defaultCyber
            }
        }
    }

    // MARK: - Public State

    public let stateKey: String
    public private(set) var sessionSnapshot: AgentSessionSnapshot
    public private(set) var providerSkin: AgentProviderSkin

    public var activeCommsBanner: String? = nil {
        didSet {
            guard activeCommsBanner != oldValue else { return }
            updateNameplate()
        }
    }

    public var isSelected: Bool = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateSelectionVisuals()
        }
    }

    // MARK: - Node Hierarchy

    public let modelContainerNode = SCNNode()
    public let bodyNode = SCNNode()
    public let bitzHeadNode = SCNNode()
    public let leftEarNode = SCNNode()
    public let rightEarNode = SCNNode()
    public let leftInnerEarNode = SCNNode()
    public let rightInnerEarNode = SCNNode()
    public let visorFrameNode = SCNNode()
    public let visorNode = SCNNode()
    public let visorEyesNode = SCNNode()
    public let chestEmblemNode = SCNNode()
    public let tailNode = SCNNode()
    public let tailTipNode = SCNNode()
    public let leftPawNode = SCNNode()
    public let rightPawNode = SCNNode()
    public let workHoloNode = SCNNode()
    public let loopRingNode = SCNNode()
    public let sleepZzzNode = SCNNode()
    public let doneBadgeNode = SCNNode()
    public let messagePacketNode = SCNNode()
    public let backpackNode = SCNNode()
    public let contextGaugeNode = SCNNode()
    public let leftThrusterNode = SCNNode()
    public let rightThrusterNode = SCNNode()
    public let nameplateNode = SCNNode()
    public let selectionRingNode = SCNNode()
    public let beaconNode = SCNNode()
    public let hazardNode = SCNNode()
    public let providerSkinNode = SCNNode()

    // MARK: - Initialization

    public init(session: AgentSessionSnapshot) {
        self.stateKey = session.stateKey
        self.sessionSnapshot = session
        self.providerSkin = AgentProviderSkin.resolve(for: session.agentID)
        super.init()

        self.name = "CyberCatCrewmate_\(session.stateKey)"
        setupHierarchy()
        applyAgentAppearance()
        updateContextGauge()
        updateVisorEyes()
        updateNameplate()
        updateSelectionVisuals()
        applyStateBehavior(animated: false)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hierarchy Setup

    private func setupHierarchy() {
        addChildNode(modelContainerNode)
        addChildNode(nameplateNode)
        addChildNode(selectionRingNode)
        addChildNode(beaconNode)
        addChildNode(hazardNode)
        addChildNode(sleepZzzNode)
        addChildNode(doneBadgeNode)

        providerSkinNode.name = "CrewmateProviderSkin"
        modelContainerNode.addChildNode(providerSkinNode)

        // 1. Compact Bitz Rounded Torso (narrower than wide cat head)
        let bodyGeometry = SCNBox(width: 0.66, height: 0.46, length: 0.48, chamferRadius: 0.18)
        bodyNode.geometry = bodyGeometry
        bodyNode.position = SCNVector3(0, 0.24, 0)
        bodyNode.name = "CrewmateBody"
        modelContainerNode.addChildNode(bodyNode)

        // 1b. Signature Bitz Wide Rounded Cat Head Chassis tilted slightly toward camera
        let headGeometry = SCNBox(width: 0.94, height: 0.62, length: 0.56, chamferRadius: 0.22)
        bitzHeadNode.geometry = headGeometry
        bitzHeadNode.position = SCNVector3(0, 0.72, 0.04)
        bitzHeadNode.eulerAngles = SCNVector3(-0.24, 0, 0)
        bitzHeadNode.name = "CrewmateBitzHead"
        modelContainerNode.addChildNode(bitzHeadNode)

        // 2. Large Pointed Cyber-Cat Ears + Emissive Inner Triangles
        let earGeometry = SCNCone(topRadius: 0.0, bottomRadius: 0.16, height: 0.34)
        let innerEarGeometry = SCNCone(topRadius: 0.0, bottomRadius: 0.09, height: 0.22)

        leftEarNode.geometry = earGeometry
        leftEarNode.position = SCNVector3(-0.28, 1.08, 0.02)
        leftEarNode.eulerAngles = SCNVector3(-0.18, 0.0, 0.22)
        leftEarNode.name = "CrewmateLeftEar"
        modelContainerNode.addChildNode(leftEarNode)

        leftInnerEarNode.geometry = innerEarGeometry
        leftInnerEarNode.position = SCNVector3(0, -0.02, 0.08)
        leftInnerEarNode.name = "CrewmateLeftInnerEar"
        leftEarNode.addChildNode(leftInnerEarNode)

        rightEarNode.geometry = earGeometry
        rightEarNode.position = SCNVector3(0.28, 1.08, 0.02)
        rightEarNode.eulerAngles = SCNVector3(-0.18, 0.0, -0.22)
        rightEarNode.name = "CrewmateRightEar"
        modelContainerNode.addChildNode(rightEarNode)

        rightInnerEarNode.geometry = innerEarGeometry
        rightInnerEarNode.position = SCNVector3(0, -0.02, 0.08)
        rightInnerEarNode.name = "CrewmateRightInnerEar"
        rightEarNode.addChildNode(rightInnerEarNode)

        // 3. Agent-Colored Visor Trim Frame + Wide Bitz Wrap-Around Visor Screen
        let visorFrameGeometry = SCNBox(width: 0.80, height: 0.38, length: 0.10, chamferRadius: 0.12)
        visorFrameNode.geometry = visorFrameGeometry
        visorFrameNode.position = SCNVector3(0, 0.73, 0.28)
        visorFrameNode.eulerAngles = SCNVector3(-0.24, 0, 0)
        visorFrameNode.name = "CrewmateVisorFrame"
        modelContainerNode.addChildNode(visorFrameNode)

        let visorGeometry = SCNBox(width: 0.76, height: 0.34, length: 0.12, chamferRadius: 0.11)
        let visorMaterial = SCNMaterial()
        visorMaterial.diffuse.contents = NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.05, alpha: 0.98)
        visorMaterial.roughness.contents = 0.1
        visorMaterial.metalness.contents = 0.8
        visorGeometry.materials = [visorMaterial]
        visorNode.geometry = visorGeometry
        visorNode.position = SCNVector3(0, 0.73, 0.30)
        visorNode.eulerAngles = SCNVector3(-0.24, 0, 0)
        visorNode.name = "CrewmateVisor"
        modelContainerNode.addChildNode(visorNode)

        // 4. Visor LED Eyes Plane
        let eyesGeometry = SCNPlane(width: 0.68, height: 0.28)
        eyesGeometry.materials = [SCNMaterial()]
        visorEyesNode.geometry = eyesGeometry
        visorEyesNode.position = SCNVector3(0, 0.74, 0.38)
        visorEyesNode.eulerAngles = SCNVector3(-0.24, 0, 0)
        visorEyesNode.renderingOrder = 20
        visorEyesNode.name = "CrewmateVisorEyes"
        modelContainerNode.addChildNode(visorEyesNode)

        // 4b. Bitz Chest Core Emblem, Tail & Capsule Front Paws
        let emblemGeometry = SCNCylinder(radius: 0.08, height: 0.03)
        chestEmblemNode.geometry = emblemGeometry
        chestEmblemNode.position = SCNVector3(0, 0.26, 0.25)
        chestEmblemNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        chestEmblemNode.name = "CrewmateChestEmblem"
        modelContainerNode.addChildNode(chestEmblemNode)

        let tailGeometry = SCNCapsule(capRadius: 0.055, height: 0.48)
        tailNode.geometry = tailGeometry
        tailNode.position = SCNVector3(0.36, 0.24, -0.14)
        tailNode.eulerAngles = SCNVector3(0, 0, -0.70)
        tailNode.name = "CrewmateTail"
        modelContainerNode.addChildNode(tailNode)

        let tailTipGeometry = SCNSphere(radius: 0.06)
        tailTipNode.geometry = tailTipGeometry
        tailTipNode.position = SCNVector3(0, -0.22, 0)
        tailTipNode.name = "CrewmateTailTip"
        tailNode.addChildNode(tailTipNode)

        let pawGeometry = SCNBox(width: 0.18, height: 0.11, length: 0.22, chamferRadius: 0.05)
        leftPawNode.geometry = pawGeometry
        leftPawNode.position = SCNVector3(-0.22, 0.12, 0.24)
        leftPawNode.name = "CrewmateLeftPaw"
        modelContainerNode.addChildNode(leftPawNode)

        rightPawNode.geometry = pawGeometry
        rightPawNode.position = SCNVector3(0.22, 0.12, 0.24)
        rightPawNode.name = "CrewmateRightPaw"
        modelContainerNode.addChildNode(rightPawNode)

        // 4c. State Props (Work Holo-Keyboard, Loop Ring, Sleep Zzz, Done Badge, Comms Packet)
        setupStatePropsHierarchy()

        // 5. Compact Cyber Power Pack
        let backpackGeometry = SCNBox(width: 0.38, height: 0.32, length: 0.14, chamferRadius: 0.05)
        let backpackMaterial = SCNMaterial()
        backpackMaterial.diffuse.contents = NSColor(white: 0.15, alpha: 1.0)
        backpackMaterial.metalness.contents = 0.6
        backpackMaterial.roughness.contents = 0.35
        backpackGeometry.materials = [backpackMaterial]
        backpackNode.geometry = backpackGeometry
        backpackNode.position = SCNVector3(0, 0.26, -0.26)
        backpackNode.name = "CrewmateBackpack"
        modelContainerNode.addChildNode(backpackNode)

        // 6. Context Gauge Bar on Power Pack
        let gaugeGeometry = SCNBox(width: 0.06, height: 0.22, length: 0.02, chamferRadius: 0.01)
        gaugeGeometry.materials = [SCNMaterial()]
        contextGaugeNode.geometry = gaugeGeometry
        contextGaugeNode.position = SCNVector3(0, 0.26, -0.34)
        contextGaugeNode.name = "CrewmateContextGauge"
        modelContainerNode.addChildNode(contextGaugeNode)

        // 7. Base Thrusters
        let thrusterGeometry = SCNCylinder(radius: 0.05, height: 0.10)
        let thrusterMaterial = SCNMaterial()
        thrusterMaterial.diffuse.contents = NSColor(white: 0.2, alpha: 1.0)
        thrusterMaterial.metalness.contents = 0.7
        thrusterGeometry.materials = [thrusterMaterial]

        leftThrusterNode.geometry = thrusterGeometry
        leftThrusterNode.position = SCNVector3(-0.10, 0.14, -0.26)
        leftThrusterNode.name = "CrewmateLeftThruster"
        modelContainerNode.addChildNode(leftThrusterNode)

        rightThrusterNode.geometry = thrusterGeometry
        rightThrusterNode.position = SCNVector3(0.10, 0.14, -0.26)
        rightThrusterNode.name = "CrewmateRightThruster"
        modelContainerNode.addChildNode(rightThrusterNode)

        // 8. Billboard Nameplate (High-DPI texture scaled comfortably above Bitz's ears)
        let nameplateGeometry = SCNPlane(width: 2.2, height: 0.55)
        nameplateGeometry.materials = [SCNMaterial()]
        nameplateNode.geometry = nameplateGeometry
        nameplateNode.position = SCNVector3(0, 1.48, 0)
        nameplateNode.scale = SCNVector3(1.02, 1.12, 1.0)
        nameplateNode.renderingOrder = 100
        nameplateNode.name = "CrewmateNameplate"
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        nameplateNode.constraints = [billboard]

        // 9. Selection Torus Ring
        let ringGeometry = SCNTorus(ringRadius: 0.55, pipeRadius: 0.03)
        let ringMaterial = SCNMaterial()
        let ringColor = NSColor(calibratedRed: 0.0, green: 0.9, blue: 1.0, alpha: 1.0)
        ringMaterial.diffuse.contents = ringColor
        ringMaterial.emission.contents = ringColor
        ringGeometry.materials = [ringMaterial]
        selectionRingNode.geometry = ringGeometry
        selectionRingNode.position = SCNVector3(0, 0.02, 0)
        selectionRingNode.name = "CrewmateSelectionRing"
        selectionRingNode.isHidden = true

        // 10. Emergency Beacon (Amber Diamond/Sphere overhead)
        let beaconGeometry = SCNSphere(radius: 0.12)
        let beaconMaterial = SCNMaterial()
        beaconMaterial.diffuse.contents = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.1, alpha: 1.0)
        beaconMaterial.emission.contents = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.1, alpha: 1.0)
        beaconGeometry.materials = [beaconMaterial]
        beaconNode.geometry = beaconGeometry
        beaconNode.position = SCNVector3(0, 1.85, 0)
        beaconNode.name = "CrewmateBeacon"
        beaconNode.isHidden = true

        // 11. Hazard Indicator (Crimson Triangle overhead)
        let hazardGeometry = SCNCone(topRadius: 0.0, bottomRadius: 0.14, height: 0.22)
        let hazardMaterial = SCNMaterial()
        hazardMaterial.diffuse.contents = NSColor(calibratedRed: 1.0, green: 0.2, blue: 0.1, alpha: 1.0)
        hazardMaterial.emission.contents = NSColor(calibratedRed: 1.0, green: 0.2, blue: 0.1, alpha: 1.0)
        hazardGeometry.materials = [hazardMaterial]
        hazardNode.geometry = hazardGeometry
        hazardNode.position = SCNVector3(0, 1.85, 0)
        hazardNode.eulerAngles = SCNVector3(CGFloat.pi, 0, 0)
        hazardNode.name = "CrewmateHazard"
        hazardNode.isHidden = true
    }

    private func setupStatePropsHierarchy() {
        let cyan = NSColor(calibratedRed: 0.0, green: 0.9, blue: 1.0, alpha: 1.0)

        // Floating Holographic Keyboard + Mini Code Display (.working)
        workHoloNode.position = SCNVector3(0, 0.38, 0.46)
        workHoloNode.name = "CrewmateWorkHolo"
        workHoloNode.isHidden = true
        let holoKeyboard = SCNBox(width: 0.52, height: 0.025, length: 0.24, chamferRadius: 0.01)
        let holoKeyMat = SCNMaterial()
        holoKeyMat.lightingModel = .constant
        holoKeyMat.diffuse.contents = NSColor(calibratedRed: 0.06, green: 0.22, blue: 0.28, alpha: 1.0)
        holoKeyMat.emission.contents = NSColor.black
        holoKeyboard.materials = [holoKeyMat]
        workHoloNode.addChildNode(SCNNode(geometry: holoKeyboard))

        let codeScreen = SCNPlane(width: 0.48, height: 0.26)
        let codeMat = SCNMaterial()
        codeMat.lightingModel = .constant
        codeMat.writesToDepthBuffer = false
        let codeImg = Self.makeMiniHoloCodeImage(accent: cyan)
        codeMat.diffuse.contents = codeImg
        codeMat.emission.contents = NSColor.black
        codeMat.isDoubleSided = true
        codeScreen.materials = [codeMat]
        let codeScreenNode = SCNNode(geometry: codeScreen)
        codeScreenNode.position = SCNVector3(0, 0.18, 0.06)
        codeScreenNode.eulerAngles = SCNVector3(-0.35, 0, 0)
        workHoloNode.addChildNode(codeScreenNode)
        modelContainerNode.addChildNode(workHoloNode)

        // Spinning Crimson Vortex Loop Ring (.warning(.loop))
        let loopGeometry = SCNTorus(ringRadius: 0.52, pipeRadius: 0.025)
        let loopMat = SCNMaterial()
        let crimson = NSColor(calibratedRed: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)
        loopMat.lightingModel = .constant
        loopMat.diffuse.contents = crimson
        loopMat.emission.contents = crimson
        loopGeometry.materials = [loopMat]
        loopRingNode.geometry = loopGeometry
        loopRingNode.position = SCNVector3(0, 0.65, 0)
        loopRingNode.name = "CrewmateLoopRing"
        loopRingNode.isHidden = true
        modelContainerNode.addChildNode(loopRingNode)

        // Floating Sleep "Z z z" Bubbles in crisp dark pill (.idle)
        let zzzPlane = SCNPlane(width: 0.65, height: 0.55)
        let zzzMat = SCNMaterial()
        zzzMat.lightingModel = .constant
        zzzMat.readsFromDepthBuffer = false
        zzzMat.writesToDepthBuffer = false
        let zzzImg = Self.makeBillboardBadgeImage(
            text: "Z z z",
            fontSize: 30,
            textColor: .white,
            pillFill: NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.16, alpha: 0.95),
            borderColor: NSColor(calibratedRed: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
        )
        zzzMat.diffuse.contents = zzzImg
        zzzMat.emission.contents = NSColor.black
        zzzMat.isDoubleSided = true
        zzzPlane.materials = [zzzMat]
        sleepZzzNode.geometry = zzzPlane
        sleepZzzNode.position = SCNVector3(0.38, 1.18, 0.25)
        sleepZzzNode.renderingOrder = 90
        let zzzBillboard = SCNBillboardConstraint()
        zzzBillboard.freeAxes = .all
        sleepZzzNode.constraints = [zzzBillboard]
        sleepZzzNode.name = "CrewmateSleepZzz"
        sleepZzzNode.isHidden = true

        // Celebratory "✓" Badge (.done)
        let donePlane = SCNPlane(width: 0.48, height: 0.48)
        let doneMat = SCNMaterial()
        doneMat.lightingModel = .constant
        doneMat.readsFromDepthBuffer = false
        doneMat.writesToDepthBuffer = false
        let green = NSColor(calibratedRed: 0.15, green: 0.92, blue: 0.55, alpha: 1.0)
        let doneImg = Self.makeBillboardBadgeImage(
            text: "✓",
            fontSize: 44,
            textColor: green,
            pillFill: NSColor(calibratedRed: 0.05, green: 0.14, blue: 0.10, alpha: 0.92),
            borderColor: green
        )
        doneMat.diffuse.contents = doneImg
        doneMat.isDoubleSided = true
        donePlane.materials = [doneMat]
        doneBadgeNode.geometry = donePlane
        doneBadgeNode.position = SCNVector3(0, 1.88, 0)
        doneBadgeNode.renderingOrder = 95
        let doneBillboard = SCNBillboardConstraint()
        doneBillboard.freeAxes = .all
        doneBadgeNode.constraints = [doneBillboard]
        doneBadgeNode.name = "CrewmateDoneBadge"
        doneBadgeNode.isHidden = true

        // 3D Data Packet Carried During Inter-Agent Communication Walks
        let packetGeometry = SCNBox(width: 0.32, height: 0.22, length: 0.06, chamferRadius: 0.02)
        let packetMat = SCNMaterial()
        let packetColor = NSColor(calibratedRed: 0.68, green: 0.42, blue: 1.0, alpha: 1.0)
        packetMat.lightingModel = .constant
        packetMat.diffuse.contents = packetColor
        packetMat.emission.contents = packetColor
        packetGeometry.materials = [packetMat]
        messagePacketNode.geometry = packetGeometry
        messagePacketNode.position = SCNVector3(0, 0.56, 0.48)
        messagePacketNode.name = "CrewmateMessagePacket"
        messagePacketNode.isHidden = true
        modelContainerNode.addChildNode(messagePacketNode)
    }

    // MARK: - State & Snapshot Updates

    public func update(with snapshot: AgentSessionSnapshot) {
        let agentChanged = self.sessionSnapshot.agentID != snapshot.agentID
        let stateChanged = (self.sessionSnapshot.lifecycleState != snapshot.lifecycleState)
            || (self.sessionSnapshot.activeWarning != snapshot.activeWarning)
        self.sessionSnapshot = snapshot

        if agentChanged {
            applyAgentAppearance()
        }
        updateContextGauge()
        updateVisorEyes()
        updateNameplate()

        if stateChanged {
            applyStateBehavior(animated: true)
        }
    }

    // MARK: - Agent Color & Appearance

    public static func agentColor(for agentID: String) -> NSColor {
        let normalized = agentID.lowercased()
        if normalized.contains("claude") {
            // Terracotta #D97746
            return NSColor(calibratedRed: 0.851, green: 0.467, blue: 0.275, alpha: 1.0)
        } else if normalized.contains("antigravity") {
            // Neon Purple #734DE6
            return NSColor(calibratedRed: 0.451, green: 0.302, blue: 0.902, alpha: 1.0)
        } else if normalized.contains("codex") || normalized.contains("openai") || normalized.contains("chatgpt") {
            // Mint #1AB373
            return NSColor(calibratedRed: 0.102, green: 0.702, blue: 0.451, alpha: 1.0)
        } else if normalized.contains("cursor") {
            // Deep Cyan #1A80CC
            return NSColor(calibratedRed: 0.102, green: 0.502, blue: 0.800, alpha: 1.0)
        } else if normalized.contains("gemini") {
            // Electric Blue #3380F2
            return NSColor(calibratedRed: 0.200, green: 0.502, blue: 0.949, alpha: 1.0)
        } else {
            // Cyber Slate #667380
            return NSColor(calibratedRed: 0.400, green: 0.451, blue: 0.502, alpha: 1.0)
        }
    }

    public static func highlightColor(for color: NSColor) -> NSColor {
        color.blended(withFraction: 0.45, of: .white) ?? color
    }

    private func applyAgentAppearance() {
        let skin = AgentProviderSkin.resolve(for: sessionSnapshot.agentID)
        self.providerSkin = skin
        let color = Self.agentColor(for: sessionSnapshot.agentID)
        let accent = Self.highlightColor(for: color)

        // Distinct AI provider body color on the 3D Bitz chassis
        let chassisMaterial = SCNMaterial()
        chassisMaterial.diffuse.contents = color
        chassisMaterial.emission.contents = color
        chassisMaterial.emission.intensity = 0.10
        chassisMaterial.roughness.contents = 0.38
        chassisMaterial.metalness.contents = 0.20
        bodyNode.geometry?.materials = [chassisMaterial]
        bitzHeadNode.geometry?.materials = [chassisMaterial]
        tailNode.geometry?.materials = [chassisMaterial]
        leftEarNode.geometry?.materials = [chassisMaterial]
        rightEarNode.geometry?.materials = [chassisMaterial]
        leftPawNode.geometry?.materials = [chassisMaterial]
        rightPawNode.geometry?.materials = [chassisMaterial]

        // Brighter highlight tint for inner ears, visor rim, chest emblem, and tail tip
        let accentMaterial = SCNMaterial()
        accentMaterial.lightingModel = .constant
        accentMaterial.diffuse.contents = accent
        accentMaterial.emission.contents = color
        accentMaterial.emission.intensity = 0.25
        leftInnerEarNode.geometry?.materials = [accentMaterial]
        rightInnerEarNode.geometry?.materials = [accentMaterial]
        visorFrameNode.geometry?.materials = [accentMaterial]
        chestEmblemNode.geometry?.materials = [accentMaterial]
        tailTipNode.geometry?.materials = [accentMaterial]

        rebuildProviderSkinAccessories(skin: skin, primaryColor: color, accentColor: accent)
    }

    private func makeSkinMaterial(
        diffuse: NSColor,
        emission: NSColor,
        emissionIntensity: CGFloat = 0.55,
        constantLighting: Bool = true
    ) -> SCNMaterial {
        let material = SCNMaterial()
        if constantLighting {
            material.lightingModel = .constant
        } else {
            material.roughness.contents = 0.32
            material.metalness.contents = 0.35
        }
        material.diffuse.contents = diffuse
        material.emission.contents = emission
        material.emission.intensity = emissionIntensity
        return material
    }

    private func makeCrossedStarNode(
        name: String,
        position: SCNVector3,
        span: CGFloat,
        thickness: CGFloat,
        material: SCNMaterial,
        includeDiagonalCore: Bool
    ) -> SCNNode {
        let container = SCNNode()
        container.name = name
        container.position = position

        let hBar = SCNBox(width: span, height: thickness, length: thickness, chamferRadius: thickness * 0.3)
        hBar.materials = [material]
        container.addChildNode(SCNNode(geometry: hBar))

        let vBar = SCNBox(width: thickness, height: span, length: thickness, chamferRadius: thickness * 0.3)
        vBar.materials = [material]
        container.addChildNode(SCNNode(geometry: vBar))

        if includeDiagonalCore {
            let coreSize = span * 0.58
            let core = SCNBox(width: coreSize, height: coreSize, length: thickness * 0.9, chamferRadius: thickness * 0.3)
            core.materials = [material]
            let coreNode = SCNNode(geometry: core)
            coreNode.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 4)
            container.addChildNode(coreNode)
        }

        return container
    }

    /// Rebuilds the provider-specific 3D silhouette accessories (`y <= 1.24`, below the nameplate).
    private func rebuildProviderSkinAccessories(
        skin: AgentProviderSkin,
        primaryColor: NSColor,
        accentColor: NSColor
    ) {
        providerSkinNode.childNodes.forEach { $0.removeFromParentNode() }

        switch skin {
        case .claude:
            // "Anthropic Spark Engineer": forehead 6-point spark crest + shoulder collar ring
            let sparkGold = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.56, alpha: 1.0)
            let sparkMaterial = makeSkinMaterial(diffuse: sparkGold, emission: sparkGold, emissionIntensity: 0.65)
            let sparkNode = SCNNode()
            sparkNode.name = "CrewmateSkin_ClaudeSpark"
            sparkNode.position = SCNVector3(0, 1.07, 0.24)
            sparkNode.eulerAngles = SCNVector3(-0.24, 0, 0)
            let rayGeo = SCNBox(width: 0.24, height: 0.042, length: 0.042, chamferRadius: 0.015)
            rayGeo.materials = [sparkMaterial]
            for index in 0..<3 {
                let ray = SCNNode(geometry: rayGeo)
                ray.eulerAngles = SCNVector3(0, 0, CGFloat(index) * (.pi / 3.0))
                sparkNode.addChildNode(ray)
            }
            providerSkinNode.addChildNode(sparkNode)

            let collarGeometry = SCNTorus(ringRadius: 0.36, pipeRadius: 0.032)
            collarGeometry.materials = [makeSkinMaterial(diffuse: accentColor, emission: primaryColor, emissionIntensity: 0.4)]
            let collarNode = SCNNode(geometry: collarGeometry)
            collarNode.name = "CrewmateSkin_ClaudeCollar"
            collarNode.position = SCNVector3(0, 0.43, 0.04)
            providerSkinNode.addChildNode(collarNode)

        case .antigravity:
            // "Zero-G Orbital Pilot": floating levitation halo + swept orbital shoulder wings
            let cyanViolet = NSColor(calibratedRed: 0.52, green: 0.86, blue: 1.0, alpha: 1.0)
            let haloMaterial = makeSkinMaterial(diffuse: cyanViolet, emission: cyanViolet, emissionIntensity: 0.7)
            let haloGeometry = SCNTorus(ringRadius: 0.35, pipeRadius: 0.024)
            haloGeometry.materials = [haloMaterial]
            let haloNode = SCNNode(geometry: haloGeometry)
            haloNode.name = "CrewmateSkin_AntigravityHalo"
            haloNode.position = SCNVector3(0, 1.16, 0.0)
            haloNode.eulerAngles = SCNVector3(0.18, 0, -0.18)
            providerSkinNode.addChildNode(haloNode)

            let wingMaterial = makeSkinMaterial(diffuse: accentColor, emission: primaryColor, emissionIntensity: 0.45, constantLighting: false)
            let wingGeometry = SCNBox(width: 0.16, height: 0.035, length: 0.26, chamferRadius: 0.015)
            wingGeometry.materials = [wingMaterial]
            for (name, xSign, tilt): (String, CGFloat, CGFloat) in [
                ("CrewmateSkin_AntigravityLeftWing", -1, 0.35),
                ("CrewmateSkin_AntigravityRightWing", 1, -0.35)
            ] {
                let wingNode = SCNNode(geometry: wingGeometry)
                wingNode.name = name
                wingNode.position = SCNVector3(0.39 * xSign, 0.36, -0.04)
                wingNode.eulerAngles = SCNVector3(0, 0, tilt)
                providerSkinNode.addChildNode(wingNode)
            }

        case .gemini:
            // "Twin-Nova Star Navigator": primary cyan-blue nova + companion violet-white star
            let primaryStarColor = NSColor(calibratedRed: 0.40, green: 0.85, blue: 1.0, alpha: 1.0)
            let primaryStarMat = makeSkinMaterial(diffuse: primaryStarColor, emission: primaryStarColor, emissionIntensity: 0.72)
            providerSkinNode.addChildNode(
                makeCrossedStarNode(
                    name: "CrewmateSkin_GeminiStarPrimary",
                    position: SCNVector3(-0.07, 1.14, 0.16),
                    span: 0.17,
                    thickness: 0.045,
                    material: primaryStarMat,
                    includeDiagonalCore: true
                )
            )

            let secondaryStarColor = NSColor(calibratedRed: 0.88, green: 0.82, blue: 1.0, alpha: 1.0)
            let secondaryStarMat = makeSkinMaterial(diffuse: secondaryStarColor, emission: secondaryStarColor, emissionIntensity: 0.72)
            providerSkinNode.addChildNode(
                makeCrossedStarNode(
                    name: "CrewmateSkin_GeminiStarSecondary",
                    position: SCNVector3(0.12, 1.18, 0.18),
                    span: 0.11,
                    thickness: 0.032,
                    material: secondaryStarMat,
                    includeDiagonalCore: false
                )
            )

        case .codex:
            // "Matrix Cyber-Ops Headphones": glowing mint ear cups + angled overhead arch band
            let mint = NSColor(calibratedRed: 0.25, green: 0.95, blue: 0.68, alpha: 1.0)
            let cupMaterial = makeSkinMaterial(diffuse: mint, emission: primaryColor, emissionIntensity: 0.60, constantLighting: false)
            let cupGeometry = SCNCylinder(radius: 0.12, height: 0.06)
            cupGeometry.materials = [cupMaterial]
            for (name, xPos): (String, CGFloat) in [
                ("CrewmateSkin_CodexLeftCup", -0.48),
                ("CrewmateSkin_CodexRightCup", 0.48)
            ] {
                let cupNode = SCNNode(geometry: cupGeometry)
                cupNode.name = name
                cupNode.position = SCNVector3(xPos, 0.73, 0.04)
                cupNode.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
                providerSkinNode.addChildNode(cupNode)
            }

            let bandGeometry = SCNTorus(ringRadius: 0.47, pipeRadius: 0.025)
            bandGeometry.materials = [makeSkinMaterial(diffuse: accentColor, emission: primaryColor, emissionIntensity: 0.45)]
            let bandNode = SCNNode(geometry: bandGeometry)
            bandNode.name = "CrewmateSkin_CodexBand"
            bandNode.position = SCNVector3(0, 0.73, 0.04)
            bandNode.eulerAngles = SCNVector3(CGFloat.pi / 2 - 0.24, 0, 0)
            providerSkinNode.addChildNode(bandNode)

        case .cursor:
            // "Vector Blade Fin": central aero crown fin + dual cheek speed fins
            let iceCyan = NSColor(calibratedRed: 0.45, green: 0.90, blue: 1.0, alpha: 1.0)
            let bladeMaterial = makeSkinMaterial(diffuse: iceCyan, emission: primaryColor, emissionIntensity: 0.55, constantLighting: false)
            let bladeGeometry = SCNBox(width: 0.07, height: 0.18, length: 0.36, chamferRadius: 0.02)
            bladeGeometry.materials = [bladeMaterial]
            let bladeNode = SCNNode(geometry: bladeGeometry)
            bladeNode.name = "CrewmateSkin_CursorBlade"
            bladeNode.position = SCNVector3(0, 1.05, 0.02)
            bladeNode.eulerAngles = SCNVector3(-0.35, 0, 0)
            providerSkinNode.addChildNode(bladeNode)

            let finGeometry = SCNBox(width: 0.04, height: 0.05, length: 0.18, chamferRadius: 0.01)
            finGeometry.materials = [makeSkinMaterial(diffuse: accentColor, emission: iceCyan, emissionIntensity: 0.5)]
            for (name, xPos): (String, CGFloat) in [
                ("CrewmateSkin_CursorLeftFin", -0.48),
                ("CrewmateSkin_CursorRightFin", 0.48)
            ] {
                let finNode = SCNNode(geometry: finGeometry)
                finNode.name = name
                finNode.position = SCNVector3(xPos, 0.66, 0.14)
                providerSkinNode.addChildNode(finNode)
            }

        case .defaultCyber:
            // "Classic Bitz Telemetry Antenna": stalk + glowing orb tip
            let stalkGeometry = SCNCylinder(radius: 0.018, height: 0.18)
            stalkGeometry.materials = [makeSkinMaterial(diffuse: accentColor, emission: primaryColor, emissionIntensity: 0.35, constantLighting: false)]
            let stalkNode = SCNNode(geometry: stalkGeometry)
            stalkNode.name = "CrewmateSkin_DefaultStalk"
            stalkNode.position = SCNVector3(0, 1.08, 0.04)
            providerSkinNode.addChildNode(stalkNode)

            let tipGeometry = SCNSphere(radius: 0.045)
            tipGeometry.materials = [makeSkinMaterial(diffuse: accentColor, emission: accentColor, emissionIntensity: 0.8)]
            let tipNode = SCNNode(geometry: tipGeometry)
            tipNode.name = "CrewmateSkin_DefaultTip"
            tipNode.position = SCNVector3(0, 1.18, 0.04)
            providerSkinNode.addChildNode(tipNode)
        }
    }

    // MARK: - Context Gauge

    private func updateContextGauge() {
        let percent = sessionSnapshot.contextReading?.percent ?? 0
        let gaugeColor: NSColor
        if percent < 70 {
            // Cyan
            gaugeColor = NSColor(calibratedRed: 0.0, green: 0.8, blue: 1.0, alpha: 1.0)
        } else if percent < 90 {
            // Amber
            gaugeColor = NSColor(calibratedRed: 1.0, green: 0.7, blue: 0.1, alpha: 1.0)
        } else {
            // Crimson
            gaugeColor = NSColor(calibratedRed: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)
        }

        let material = SCNMaterial()
        material.diffuse.contents = gaugeColor
        material.emission.contents = gaugeColor
        contextGaugeNode.geometry?.materials = [material]
    }

    // MARK: - Visor LED Eyes

    private func updateVisorEyes() {
        let state = sessionSnapshot.lifecycleState
        let color = state.nsColor

        let imageSize = NSSize(width: 240, height: 100)
        let image = NSImage(size: imageSize)
        image.lockFocus()

        // Clear transparent background
        NSColor.clear.set()
        NSRect(origin: .zero, size: imageSize).fill()

        // Subtle glowing cheek blush ovals (classic Bitz look)
        let cheekColor = color.withAlphaComponent(0.32)
        cheekColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 18, y: 18, width: 26, height: 14)).fill()
        NSBezierPath(ovalIn: NSRect(x: 196, y: 18, width: 26, height: 14)).fill()

        if state == .working {
            // Signature glowing Bitz rounded-rectangle cyber-cat eyes + white eye shine
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 48, y: 24, width: 42, height: 52), xRadius: 14, yRadius: 14).fill()
            NSBezierPath(roundedRect: NSRect(x: 150, y: 24, width: 42, height: 52), xRadius: 14, yRadius: 14).fill()

            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: 72, y: 58, width: 12, height: 12)).fill()
            NSBezierPath(ovalIn: NSRect(x: 174, y: 58, width: 12, height: 12)).fill()
        } else {
            let symbolText: String
            switch state {
            case .working:       symbolText = "•  •"
            case .needsApproval: symbolText = "!  !"
            case .warning:       symbolText = "▲  ▲"
            case .almostDone:    symbolText = ">  <"
            case .done:          symbolText = "^  ^"
            case .failed:        symbolText = "×  ×"
            case .idle:          symbolText = "—  —"
            }

            let font = NSFont.monospacedSystemFont(ofSize: 52, weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            let attrString = NSAttributedString(string: symbolText, attributes: attributes)
            let strSize = attrString.size()
            let drawPoint = NSPoint(
                x: (imageSize.width - strSize.width) / 2.0,
                y: (imageSize.height - strSize.height) / 2.0
            )
            attrString.draw(at: drawPoint)
        }

        image.unlockFocus()

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.diffuse.contents = image
        material.emission.contents = NSColor.black
        material.isDoubleSided = false
        visorEyesNode.geometry?.materials = [material]
    }

    // MARK: - Action Headline & Billboard Nameplate

    public static func actionHeadline(
        for snapshot: AgentSessionSnapshot,
        commsBanner: String? = nil
    ) -> String {
        if let commsBanner, !commsBanner.isEmpty {
            return commsBanner
        }
        switch snapshot.lifecycleState {
        case .working:
            return snapshot.pendingTools > 0
                ? "⌨️ RUNNING TOOL (\(snapshot.pendingTools))"
                : "⌨️ CODING NOW"
        case .needsApproval:
            return "✋ NEEDS APPROVAL!"
        case .warning:
            switch snapshot.activeWarning {
            case .loop:      return "🔄 STUCK IN LOOP!"
            case .stall:     return "⏳ STALLED · IDLE"
            case .context:   return "🧠 CONTEXT HIGH!"
            case .rateLimit:  return "⛔ RATE LIMIT (429)"
            case .runawayCPU: return "🔥 RUNAWAY CPU!"
            case .reported:   return "⚠️ NEEDS ATTENTION"
            case nil:        return "⚠️ NEEDS ATTENTION"
            }
        case .almostDone:
            return "🚀 WRAPPING UP..."
        case .done:
            return "✅ TASK COMPLETE"
        case .failed:
            return "💥 ERROR / FAILED"
        case .idle:
            return "💤 SLEEPING · IDLE"
        }
    }

    private static func highContrastHeaderColors(
        for state: AgentSessionLifecycleState,
        commsActive: Bool
    ) -> (background: NSColor, foreground: NSColor) {
        if commsActive {
            return (
                NSColor(calibratedRed: 0.427, green: 0.157, blue: 0.851, alpha: 1.0), // #6D28D9 Electric Purple
                .white
            )
        }
        switch state {
        case .working:
            return (
                NSColor(calibratedRed: 0.0, green: 0.784, blue: 0.325, alpha: 1.0), // #00C853 Solid Emerald
                NSColor(calibratedRed: 0.016, green: 0.031, blue: 0.024, alpha: 1.0)
            )
        case .needsApproval:
            return (
                NSColor(calibratedRed: 1.0, green: 0.702, blue: 0.0, alpha: 1.0), // #FFB300 Solid Amber
                NSColor(calibratedRed: 0.031, green: 0.024, blue: 0.0, alpha: 1.0)
            )
        case .warning:
            return (
                NSColor(calibratedRed: 0.835, green: 0.0, blue: 0.196, alpha: 1.0), // #D50032 Solid Crimson
                .white
            )
        case .almostDone:
            return (
                NSColor(calibratedRed: 0.0, green: 0.722, blue: 0.831, alpha: 1.0), // #00B8D4 Solid Cyan
                NSColor(calibratedRed: 0.016, green: 0.031, blue: 0.039, alpha: 1.0)
            )
        case .done:
            return (
                NSColor(calibratedRed: 0.0, green: 0.902, blue: 0.463, alpha: 1.0), // #00E676 Solid Mint
                NSColor(calibratedRed: 0.016, green: 0.031, blue: 0.024, alpha: 1.0)
            )
        case .failed:
            return (
                NSColor(calibratedRed: 0.776, green: 0.157, blue: 0.157, alpha: 1.0), // #C62828 Solid Red
                .white
            )
        case .idle:
            return (
                NSColor(calibratedRed: 0.118, green: 0.227, blue: 0.541, alpha: 1.0), // #1E3A8A Deep Navy-Blue
                .white
            )
        }
    }

    private func updateNameplate() {
        let imageSize = NSSize(width: 660, height: 180)
        let image = NSImage(size: imageSize)
        image.lockFocus()

        let statusColor = sessionSnapshot.lifecycleState.nsColor
        let agentAccent = Self.agentColor(for: sessionSnapshot.agentID)
        let headerColors = Self.highContrastHeaderColors(
            for: sessionSnapshot.lifecycleState,
            commsActive: activeCommsBanner != nil
        )

        // Solid dark obsidian rounded pill
        let pillRect = NSRect(x: 8, y: 8, width: 644, height: 164)
        let path = NSBezierPath(roundedRect: pillRect, xRadius: 24, yRadius: 24)
        NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.09, alpha: 0.98).setFill()
        path.fill()

        // Solid high-contrast top action header band
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let headerBand = NSRect(x: 8, y: 94, width: 644, height: 78)
        headerColors.background.setFill()
        headerBand.fill()
        NSGraphicsContext.restoreGraphicsState()

        statusColor.setStroke()
        path.lineWidth = 4.5
        path.stroke()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        // Line 1: Bold WCAG AAA high-contrast action headline
        let headline = Self.actionHeadline(for: sessionSnapshot, commsBanner: activeCommsBanner)
        let headlineFont = NSFont.monospacedSystemFont(ofSize: 28, weight: .heavy)
        let headlineAttrs: [NSAttributedString.Key: Any] = [
            .font: headlineFont,
            .foregroundColor: headerColors.foreground,
            .paragraphStyle: paragraphStyle
        ]
        NSAttributedString(string: headline, attributes: headlineAttrs).draw(
            with: NSRect(x: 28, y: 108, width: 604, height: 44),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )

        // Agent color identity dot with crisp white rim on second row
        let dotRect = NSRect(x: 28, y: 40, width: 22, height: 22)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        agentAccent.setFill()
        dotPath.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        dotPath.lineWidth = 2.5
        dotPath.stroke()

        // Line 2: Readable Session Label + Right-Aligned Context %
        let labelFont = NSFont.monospacedSystemFont(ofSize: 26, weight: .heavy)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
        NSAttributedString(string: sessionSnapshot.sessionLabel, attributes: labelAttrs).draw(
            with: NSRect(x: 62, y: 28, width: 468, height: 40),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )

        let percent = sessionSnapshot.contextReading?.percent ?? 0
        let pctColor: NSColor
        if percent < 70 {
            pctColor = NSColor(calibratedRed: 0.35, green: 0.92, blue: 1.0, alpha: 1.0)
        } else if percent < 90 {
            pctColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.25, alpha: 1.0)
        } else {
            pctColor = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.42, alpha: 1.0)
        }
        let pctParagraph = NSMutableParagraphStyle()
        pctParagraph.alignment = .right
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 25, weight: .heavy),
            .foregroundColor: pctColor,
            .paragraphStyle: pctParagraph
        ]
        NSAttributedString(string: "\(percent)%", attributes: pctAttrs).draw(
            with: NSRect(x: 536, y: 28, width: 96, height: 40),
            options: [.usesLineFragmentOrigin]
        )

        image.unlockFocus()

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.diffuse.contents = image
        material.emission.contents = NSColor.black
        material.isDoubleSided = true
        nameplateNode.geometry?.materials = [material]
    }

    // MARK: - Texture Helpers

    private static func makeMiniHoloCodeImage(accent: NSColor) -> NSImage {
        let size = NSSize(width: 140, height: 80)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(calibratedRed: 0.03, green: 0.12, blue: 0.18, alpha: 0.85).setFill()
        NSRect(origin: .zero, size: size).fill()

        accent.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4))
        border.lineWidth = 3
        border.stroke()

        let barWidths: [CGFloat] = [92, 66, 108, 54, 84]
        for (idx, w) in barWidths.enumerated() {
            let y = 60 - CGFloat(idx) * 12
            let color = idx % 2 == 0 ? accent : NSColor(calibratedRed: 0.25, green: 0.95, blue: 0.65, alpha: 1.0)
            color.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: y, width: w, height: 6), xRadius: 3, yRadius: 3).fill()
        }

        image.unlockFocus()
        return image
    }

    private static func makeBillboardBadgeImage(
        text: String,
        fontSize: CGFloat,
        textColor: NSColor,
        pillFill: NSColor?,
        borderColor: NSColor?
    ) -> NSImage {
        let size = NSSize(width: 120, height: 100)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()

        if let pillFill {
            let pill = NSBezierPath(roundedRect: NSRect(x: 10, y: 10, width: 100, height: 80), xRadius: 24, yRadius: 24)
            pillFill.setFill()
            pill.fill()
            if let borderColor {
                borderColor.setStroke()
                pill.lineWidth = 4
                pill.stroke()
            }
        }

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()
        attr.draw(at: NSPoint(x: (size.width - textSize.width) / 2.0, y: (size.height - textSize.height) / 2.0))

        image.unlockFocus()
        return image
    }

    // MARK: - Selection Visuals

    private func updateSelectionVisuals() {
        selectionRingNode.isHidden = !isSelected
        selectionRingNode.removeAction(forKey: "selectionPulse")

        if isSelected {
            let pulse = SCNAction.repeatForever(
                SCNAction.sequence([
                    SCNAction.fadeOpacity(to: 0.4, duration: 0.6),
                    SCNAction.fadeOpacity(to: 1.0, duration: 0.6)
                ])
            )
            selectionRingNode.runAction(pulse, forKey: "selectionPulse")
        }
    }

    // MARK: - Procedural State Behaviors & Animations

    public func applyStateBehavior(animated: Bool = true) {
        modelContainerNode.removeAction(forKey: "stateBehavior")
        beaconNode.removeAction(forKey: "beaconPulse")
        hazardNode.removeAction(forKey: "hazardPulse")
        leftPawNode.removeAction(forKey: "pawAction")
        rightPawNode.removeAction(forKey: "pawAction")
        loopRingNode.removeAction(forKey: "loopSpin")
        sleepZzzNode.removeAction(forKey: "sleepFloat")
        doneBadgeNode.removeAction(forKey: "donePulse")
        tailNode.removeAction(forKey: "tailSwish")

        beaconNode.isHidden = true
        hazardNode.isHidden = true
        workHoloNode.isHidden = true
        loopRingNode.isHidden = true
        sleepZzzNode.isHidden = true
        doneBadgeNode.isHidden = true

        modelContainerNode.position = SCNVector3Zero
        modelContainerNode.eulerAngles = SCNVector3Zero
        modelContainerNode.scale = SCNVector3(1, 1, 1)

        leftPawNode.position = SCNVector3(-0.22, 0.12, 0.24)
        rightPawNode.position = SCNVector3(0.22, 0.12, 0.24)
        tailNode.eulerAngles = SCNVector3(0, 0, -0.70)

        let state = sessionSnapshot.lifecycleState

        if state != .failed {
            let swishLeft = SCNAction.rotateBy(x: 0, y: 0.22, z: 0, duration: 0.9)
            let swishRight = SCNAction.rotateBy(x: 0, y: -0.22, z: 0, duration: 0.9)
            swishLeft.timingMode = .easeInEaseOut
            swishRight.timingMode = .easeInEaseOut
            tailNode.runAction(SCNAction.repeatForever(SCNAction.sequence([swishLeft, swishRight])), forKey: "tailSwish")
        }

        switch state {
        case .working:
            modelContainerNode.position = SCNVector3Zero
            modelContainerNode.eulerAngles = SCNVector3Zero

            workHoloNode.isHidden = false
            leftPawNode.position = SCNVector3(-0.16, 0.42, 0.42)
            rightPawNode.position = SCNVector3(0.16, 0.42, 0.42)

            let tapUp = SCNAction.moveBy(x: 0, y: 0.08, z: 0, duration: 0.09)
            let tapDown = SCNAction.moveBy(x: 0, y: -0.08, z: 0, duration: 0.09)
            let pawCycle = SCNAction.sequence([tapUp, tapDown])
            leftPawNode.runAction(SCNAction.repeatForever(pawCycle), forKey: "pawAction")
            rightPawNode.runAction(
                SCNAction.sequence([SCNAction.wait(duration: 0.09), SCNAction.repeatForever(pawCycle)]),
                forKey: "pawAction"
            )

            // Typing bob: vertical oscillation on model container
            let bobUp = SCNAction.moveBy(x: 0, y: 0.05, z: 0, duration: 0.18)
            let bobDown = SCNAction.moveBy(x: 0, y: -0.05, z: 0, duration: 0.18)
            let pause = SCNAction.wait(duration: 0.1)
            let typingSequence = SCNAction.sequence([bobUp, bobDown, bobUp, bobDown, pause])
            modelContainerNode.runAction(SCNAction.repeatForever(typingSequence), forKey: "stateBehavior")

        case .needsApproval:
            modelContainerNode.position = SCNVector3Zero
            modelContainerNode.eulerAngles = SCNVector3Zero

            leftPawNode.position = SCNVector3(-0.32, 0.96, 0.22)
            rightPawNode.position = SCNVector3(0.32, 0.96, 0.22)
            let waveUp = SCNAction.moveBy(x: 0, y: 0.12, z: 0, duration: 0.16)
            let waveDown = SCNAction.moveBy(x: 0, y: -0.12, z: 0, duration: 0.16)
            let wave = SCNAction.repeatForever(SCNAction.sequence([waveUp, waveDown]))
            leftPawNode.runAction(wave, forKey: "pawAction")
            rightPawNode.runAction(wave, forKey: "pawAction")

            beaconNode.isHidden = false
            let beaconPulse = SCNAction.repeatForever(
                SCNAction.sequence([
                    SCNAction.scale(to: 1.4, duration: 0.3),
                    SCNAction.scale(to: 0.9, duration: 0.3)
                ])
            )
            beaconNode.runAction(beaconPulse, forKey: "beaconPulse")

            // Alert hop
            let hopUp = SCNAction.moveBy(x: 0, y: 0.35, z: 0, duration: 0.22)
            hopUp.timingMode = .easeOut
            let hopDown = SCNAction.moveBy(x: 0, y: -0.35, z: 0, duration: 0.22)
            hopDown.timingMode = .easeIn
            let hopSequence = SCNAction.sequence([hopUp, hopDown, SCNAction.wait(duration: 0.15)])
            modelContainerNode.runAction(SCNAction.repeatForever(hopSequence), forKey: "stateBehavior")

        case .warning:
            modelContainerNode.position = SCNVector3Zero
            modelContainerNode.eulerAngles = SCNVector3Zero

            if sessionSnapshot.activeWarning == .loop {
                loopRingNode.isHidden = false
                loopRingNode.eulerAngles = SCNVector3(0.35, 0, -0.25)
                loopRingNode.runAction(
                    SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.7)),
                    forKey: "loopSpin"
                )

                // Loop warning: rapid frantic spinning wobble
                let wobbleLeft = SCNAction.rotateBy(x: 0, y: 0, z: 0.15, duration: 0.12)
                let wobbleRight = SCNAction.rotateBy(x: 0, y: 0, z: -0.30, duration: 0.24)
                let wobbleCenter = SCNAction.rotateBy(x: 0, y: 0, z: 0.15, duration: 0.12)
                let loopWobble = SCNAction.repeatForever(SCNAction.sequence([wobbleLeft, wobbleRight, wobbleCenter]))
                modelContainerNode.runAction(loopWobble, forKey: "stateBehavior")
            } else {
                // Panicked paws on cheeks
                leftPawNode.position = SCNVector3(-0.30, 0.72, 0.30)
                rightPawNode.position = SCNVector3(0.30, 0.72, 0.30)

                // Stall / Context / Rate Limit hazard indicator
                hazardNode.isHidden = false
                let hazardPulse = SCNAction.repeatForever(
                    SCNAction.sequence([
                        SCNAction.scale(to: 1.3, duration: 0.4),
                        SCNAction.scale(to: 1.0, duration: 0.4)
                    ])
                )
                hazardNode.runAction(hazardPulse, forKey: "hazardPulse")

                // Nervous jitter
                let jitterLeft = SCNAction.moveBy(x: -0.04, y: 0, z: 0, duration: 0.08)
                let jitterRight = SCNAction.moveBy(x: 0.08, y: 0, z: 0, duration: 0.16)
                let jitterBack = SCNAction.moveBy(x: -0.04, y: 0, z: 0, duration: 0.08)
                let jitter = SCNAction.repeatForever(SCNAction.sequence([jitterLeft, jitterRight, jitterBack, SCNAction.wait(duration: 0.4)]))
                modelContainerNode.runAction(jitter, forKey: "stateBehavior")
            }

        case .almostDone:
            leftPawNode.position = SCNVector3(-0.28, 0.50, 0.30)
            rightPawNode.position = SCNVector3(0.28, 0.50, 0.30)
            let pumpForward = SCNAction.moveBy(x: 0, y: 0, z: 0.16, duration: 0.15)
            let pumpBack = SCNAction.moveBy(x: 0, y: 0, z: -0.16, duration: 0.15)
            let pump = SCNAction.repeatForever(SCNAction.sequence([pumpForward, pumpBack]))
            leftPawNode.runAction(pump, forKey: "pawAction")
            rightPawNode.runAction(SCNAction.sequence([SCNAction.wait(duration: 0.15), pump]), forKey: "pawAction")

            // Sprint tilt forward toward launchpad
            let tilt = SCNAction.rotateTo(x: 0.25, y: 0, z: 0, duration: 0.25)
            let bob = SCNAction.repeatForever(
                SCNAction.sequence([
                    SCNAction.moveBy(x: 0, y: 0.08, z: 0, duration: 0.15),
                    SCNAction.moveBy(x: 0, y: -0.08, z: 0, duration: 0.15)
                ])
            )
            modelContainerNode.runAction(SCNAction.group([tilt, bob]), forKey: "stateBehavior")

        case .done:
            modelContainerNode.position = SCNVector3Zero
            modelContainerNode.eulerAngles = SCNVector3Zero

            // Celebratory V paws + Checkmark badge
            leftPawNode.position = SCNVector3(-0.34, 0.94, 0.18)
            rightPawNode.position = SCNVector3(0.34, 0.94, 0.18)
            doneBadgeNode.isHidden = false
            doneBadgeNode.runAction(
                SCNAction.repeatForever(
                    SCNAction.sequence([
                        SCNAction.scale(to: 1.15, duration: 0.45),
                        SCNAction.scale(to: 0.95, duration: 0.45)
                    ])
                ),
                forKey: "donePulse"
            )

            // Victory bounce + 360° spin
            let jumpUp = SCNAction.moveBy(x: 0, y: 0.50, z: 0, duration: 0.3)
            jumpUp.timingMode = .easeOut
            let spin = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.5)
            let jumpDown = SCNAction.moveBy(x: 0, y: -0.50, z: 0, duration: 0.3)
            jumpDown.timingMode = .easeIn
            let rest = SCNAction.wait(duration: 0.3)
            let victory = SCNAction.repeatForever(
                SCNAction.sequence([
                    SCNAction.group([jumpUp, spin]),
                    jumpDown,
                    rest
                ])
            )
            modelContainerNode.runAction(victory, forKey: "stateBehavior")

        case .failed:
            // Splay paws outward
            leftPawNode.position = SCNVector3(-0.42, 0.55, 0.10)
            rightPawNode.position = SCNVector3(0.42, 0.55, 0.10)

            // Tip over backwards 90° KO'd
            let fallBack = SCNAction.rotateTo(x: -.pi / 2, y: 0, z: 0, duration: 0.35)
            fallBack.timingMode = .easeIn
            let lower = SCNAction.move(to: SCNVector3(0, 0.2, 0), duration: 0.35)
            modelContainerNode.runAction(SCNAction.group([fallBack, lower]), forKey: "stateBehavior")

        case .idle:
            // Rest paws comfortably on belly + floating Zzz bubbles
            leftPawNode.position = SCNVector3(-0.18, 0.24, 0.30)
            rightPawNode.position = SCNVector3(0.18, 0.24, 0.30)

            sleepZzzNode.isHidden = false
            sleepZzzNode.position = SCNVector3(0.38, 1.18, 0.25)
            let floatUp = SCNAction.group([
                SCNAction.moveBy(x: 0.04, y: 0.16, z: 0, duration: 1.4),
                SCNAction.fadeOpacity(to: 0.95, duration: 0.7)
            ])
            let floatDown = SCNAction.group([
                SCNAction.moveBy(x: -0.04, y: -0.16, z: 0, duration: 1.4),
                SCNAction.fadeOpacity(to: 0.45, duration: 0.7)
            ])
            sleepZzzNode.runAction(SCNAction.repeatForever(SCNAction.sequence([floatUp, floatDown])), forKey: "sleepFloat")

            // Recline gently in MedBay pod with breathing expansion
            let recline = SCNAction.rotateTo(x: -0.20, y: 0, z: 0, duration: 0.4)
            let breatheIn = SCNAction.scale(to: 1.04, duration: 1.8)
            breatheIn.timingMode = .easeInEaseOut
            let breatheOut = SCNAction.scale(to: 0.98, duration: 1.8)
            breatheOut.timingMode = .easeInEaseOut
            let breathe = SCNAction.repeatForever(SCNAction.sequence([breatheIn, breatheOut]))
            modelContainerNode.runAction(SCNAction.group([recline, breathe]), forKey: "stateBehavior")
        }
    }
}
