import SceneKit
import AppKit

/// Controller managing the 3D SceneKit Cyber-Ship scene, isometric orthographic camera,
/// atmospheric lighting, 5 station zones, and reactive crewmate synchronization.
public final class CyberShipSceneController {

    // MARK: - Station Coordinates & Capacity Slots

    public static let codeBayCenter = SCNVector3(-5.0, 0.0, 0.0)
    public static let emergencyTableCenter = SCNVector3(0.0, 0.0, 0.0)
    public static let reactorCenter = SCNVector3(0.0, 0.0, -5.5)
    public static let launchpadCenter = SCNVector3(5.0, 0.0, 0.0)
    public static let medBayCenter = SCNVector3(0.0, 0.0, 4.5)

    public static let baseOrthographicScale: Double = 8.4
    public static let minimumVisibleHalfWidth: Double = 10.2

    public static let codeBayDeskSlots: [SCNVector3] = [
        SCNVector3(-7.1, 0, -2.1),
        SCNVector3(-4.3, 0, -2.1),
        SCNVector3(-7.1, 0, 0.3),
        SCNVector3(-4.3, 0, 0.3),
        SCNVector3(-9.9, 0, -2.1),
        SCNVector3(-9.9, 0, 0.3),
        SCNVector3(-9.9, 0, -4.5),
        SCNVector3(-7.1, 0, -4.5)
    ]

    public static let medBayNestSlots: [SCNVector3] = [
        SCNVector3(-2.9, 0, 4.5),
        SCNVector3(0.0, 0, 4.5),
        SCNVector3(2.9, 0, 4.5),
        SCNVector3(-5.8, 0, 4.5),
        SCNVector3(5.8, 0, 4.5),
        SCNVector3(-4.35, 0, 6.9),
        SCNVector3(-1.45, 0, 6.9),
        SCNVector3(1.45, 0, 6.9),
        SCNVector3(4.35, 0, 6.9)
    ]

    // MARK: - Properties

    public let scene: SCNScene
    public let cameraNode: SCNNode

    // Root nodes for stations & environment
    public let deckFloorNode = SCNNode()
    public let codeBayNode = SCNNode()
    public let emergencyTableNode = SCNNode()
    public let reactorNode = SCNNode()
    public let launchpadNode = SCNNode()
    public let medBayNode = SCNNode()

    // Lighting nodes
    public let ambientLightNode = SCNNode()
    public let directionalLightNode = SCNNode()
    public let codeBayLightNode = SCNNode()
    public let emergencyLightNode = SCNNode()
    public let reactorLightNode = SCNNode()
    public let launchpadLightNode = SCNNode()
    public let medBayLightNode = SCNNode()

    // Active crewmates indexed by `stateKey`
    public private(set) var crewmateNodes: [String: CyberCatCrewmateNode] = [:]

    // Dynamically provisioned personal desks & nests
    private var terminalDeskNodes: [SCNNode] = []
    private var chargingPodNodes: [SCNNode] = []
    public var provisionedDeskCount: Int { terminalDeskNodes.count }
    public var provisionedNestCount: Int { chargingPodNodes.count }

    // Inter-agent communication tracking
    public private(set) var lastCommsPair: (sender: String, recipient: String)?
    private var lastAutoCommsSignatures: [String: String] = [:]
    private var lastViewportSize: CGSize = .zero
    /// Persistent per-station slot assignments (`stationGroupKey -> [stateKey: slotIndex]`) so crewmates
    /// never swap desks/nests when `lastActivity` reorders `sessionSnapshots`.
    private var assignedStationSlots: [String: [String: Int]] = [:]

    // MARK: - Initialization

    public init() {
        self.scene = SCNScene()
        self.cameraNode = SCNNode()

        setupCamera()
        setupLighting()
        setupDeckFloor()
        setupStations()
    }

    // MARK: - Camera Setup

    private func setupCamera() {
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Self.baseOrthographicScale
        camera.zNear = 0.1
        camera.zFar = 100.0

        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 12, 12)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        cameraNode.name = "IsometricOrthographicCamera"

        scene.rootNode.addChildNode(cameraNode)
    }

    /// Dynamically adjusts `camera.orthographicScale` for the viewport aspect ratio and active crew
    /// horizontal span so the map and nameplates never clip when the window is resized narrower/smaller.
    public func updateCameraForViewport(size: CGSize) {
        guard size.width > 1, size.height > 1, let camera = cameraNode.camera else { return }
        lastViewportSize = size
        let aspect = Double(size.width / size.height)
        let maxCrewHalfWidth = crewmateNodes.values.map { Double(abs($0.position.x)) + 1.5 }.max() ?? 0.0
        let requiredHalfWidth = max(Self.minimumVisibleHalfWidth, maxCrewHalfWidth)
        let requiredScale = max(Self.baseOrthographicScale, requiredHalfWidth / max(0.3, aspect))
        if abs(camera.orthographicScale - requiredScale) > 0.01 {
            camera.orthographicScale = requiredScale
        }
    }

    // MARK: - Lighting Setup

    private func setupLighting() {
        // 1. Ambient Light
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = NSColor(calibratedWhite: 0.28, alpha: 1.0)
        ambientLightNode.light = ambientLight
        ambientLightNode.name = "AmbientLight"
        scene.rootNode.addChildNode(ambientLightNode)

        // 2. Directional Key Light
        let dirLight = SCNLight()
        dirLight.type = .directional
        dirLight.color = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        dirLight.castsShadow = true
        dirLight.shadowRadius = 3.0
        directionalLightNode.light = dirLight
        directionalLightNode.position = SCNVector3(5, 15, 10)
        directionalLightNode.look(at: SCNVector3(0, 0, 0))
        directionalLightNode.name = "KeyDirectionalLight"
        scene.rootNode.addChildNode(directionalLightNode)

        // 3. Station Point Lights
        // Code Bay: Cyan
        let codeBayLight = SCNLight()
        codeBayLight.type = .omni
        codeBayLight.color = NSColor(calibratedRed: 0.0, green: 0.8, blue: 1.0, alpha: 1.0)
        codeBayLight.intensity = 260
        codeBayLightNode.light = codeBayLight
        codeBayLightNode.position = SCNVector3(-5.0, 3.0, 0.0)
        codeBayLightNode.name = "CodeBayPointLight"
        scene.rootNode.addChildNode(codeBayLightNode)

        // Emergency Table: Amber
        let emergencyLight = SCNLight()
        emergencyLight.type = .omni
        emergencyLight.color = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.1, alpha: 1.0)
        emergencyLight.intensity = 300
        emergencyLightNode.light = emergencyLight
        emergencyLightNode.position = SCNVector3(0.0, 3.0, 0.0)
        emergencyLightNode.name = "EmergencyTablePointLight"
        scene.rootNode.addChildNode(emergencyLightNode)

        // Reactor: Crimson
        let reactorLight = SCNLight()
        reactorLight.type = .omni
        reactorLight.color = NSColor(calibratedRed: 1.0, green: 0.2, blue: 0.1, alpha: 1.0)
        reactorLight.intensity = 350
        reactorLightNode.light = reactorLight
        reactorLightNode.position = SCNVector3(0.0, 3.0, -5.5)
        reactorLightNode.name = "ReactorPointLight"
        let pulseLight = SCNAction.repeatForever(
            SCNAction.sequence([
                SCNAction.customAction(duration: 0.8) { node, elapsed in
                    let pct = elapsed / 0.8
                    node.light?.intensity = CGFloat(320.0 + 160.0 * sin(pct * Double.pi))
                }
            ])
        )
        reactorLightNode.runAction(pulseLight)
        scene.rootNode.addChildNode(reactorLightNode)

        // Launchpad: Emerald / Cyan
        let launchpadLight = SCNLight()
        launchpadLight.type = .omni
        launchpadLight.color = NSColor(calibratedRed: 0.0, green: 1.0, blue: 0.6, alpha: 1.0)
        launchpadLight.intensity = 260
        launchpadLightNode.light = launchpadLight
        launchpadLightNode.position = SCNVector3(5.0, 3.0, 0.0)
        launchpadLightNode.name = "LaunchpadPointLight"
        scene.rootNode.addChildNode(launchpadLightNode)

        // MedBay: Soft Blue
        let medBayLight = SCNLight()
        medBayLight.type = .omni
        medBayLight.color = NSColor(calibratedRed: 0.2, green: 0.5, blue: 1.0, alpha: 1.0)
        medBayLight.intensity = 240
        medBayLightNode.light = medBayLight
        medBayLightNode.position = SCNVector3(0.0, 3.0, 4.5)
        medBayLightNode.name = "MedBayPointLight"
        scene.rootNode.addChildNode(medBayLightNode)
    }

    // MARK: - Deck Floor

    private func setupDeckFloor() {
        let floorGeometry = SCNBox(width: 26, height: 0.2, length: 20, chamferRadius: 0.1)
        let floorMaterial = SCNMaterial()
        floorMaterial.diffuse.contents = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
        floorMaterial.roughness.contents = 0.35
        floorMaterial.metalness.contents = 0.4
        floorGeometry.materials = [floorMaterial]

        deckFloorNode.geometry = floorGeometry
        deckFloorNode.position = SCNVector3(0, -0.1, 0)
        deckFloorNode.name = "DeckFloor"
        scene.rootNode.addChildNode(deckFloorNode)

        // Subtle neon floor guide lines connecting perimeter stations to the center table
        addGuideLine(from: SCNVector3(-4.0, 0.01, 0), to: SCNVector3(-1.6, 0.01, 0), color: NSColor.cyan)
        addGuideLine(from: SCNVector3(4.0, 0.01, 0), to: SCNVector3(1.6, 0.01, 0), color: NSColor.green)
        addGuideLine(from: SCNVector3(0, 0.01, -4.5), to: SCNVector3(0, 0.01, -1.6), color: NSColor.orange)
        addGuideLine(from: SCNVector3(0, 0.01, 3.6), to: SCNVector3(0, 0.01, 1.6), color: NSColor.systemBlue)
    }

    private func addGuideLine(from start: SCNVector3, to end: SCNVector3, color: NSColor) {
        let dx = end.x - start.x
        let dz = end.z - start.z
        let length = sqrt(dx * dx + dz * dz)
        let midX = (start.x + end.x) / 2.0
        let midZ = (start.z + end.z) / 2.0

        let lineBox = SCNBox(width: CGFloat(length), height: 0.01, length: 0.06, chamferRadius: 0.0)
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(0.6)
        material.emission.contents = color
        material.emission.intensity = 0.35
        lineBox.materials = [material]

        let lineNode = SCNNode(geometry: lineBox)
        lineNode.position = SCNVector3(midX, 0.01, midZ)
        lineNode.eulerAngles = SCNVector3(0, -atan2(dz, dx), 0)
        lineNode.name = "FloorGuideLine"
        scene.rootNode.addChildNode(lineNode)
    }

    // MARK: - 5 Station Zones Setup

    private func setupStations() {
        let cyan = NSColor(calibratedRed: 0.0, green: 0.85, blue: 0.95, alpha: 1.0)
        let amber = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.1, alpha: 1.0)
        let hazardColor = NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.0, alpha: 1.0)
        let green = NSColor(calibratedRed: 0.0, green: 1.0, blue: 0.5, alpha: 1.0)
        let medBlue = NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 1.0)

        // 1. Code Bay: Dedicated Coding Room & Workstation Mats at X: -5.0, Z: 0.0
        codeBayNode.position = Self.codeBayCenter
        codeBayNode.name = "Station_CodeBay"

        let codeZonePad = SCNBox(width: 5.8, height: 0.015, length: 5.0, chamferRadius: 0.2)
        let codeZoneMat = SCNMaterial()
        codeZoneMat.diffuse.contents = NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.12, alpha: 1.0)
        codeZoneMat.emission.contents = cyan
        codeZoneMat.emission.intensity = 0.04
        codeZonePad.materials = [codeZoneMat]
        let codeZoneNode = SCNNode(geometry: codeZonePad)
        codeZoneNode.position = SCNVector3(-0.7, 0.008, -0.9)
        codeBayNode.addChildNode(codeZoneNode)

        addRoomBorderWalls(
            to: codeBayNode,
            centerOffset: SCNVector3(-0.7, 0, -0.9),
            width: 5.8,
            length: 5.0,
            color: cyan,
            openRight: true
        )
        let codeBanner = createStationBannerNode(title: "⌨️ CODE BAY", subtitle: "ACTIVE CODING", color: cyan)
        codeBanner.position = SCNVector3(-0.7, 0.35, -3.75)
        codeBayNode.addChildNode(codeBanner)

        scene.rootNode.addChildNode(codeBayNode)

        // 2. Emergency Approval Table: Center X: 0.0, Z: 0.0
        emergencyTableNode.position = Self.emergencyTableCenter
        emergencyTableNode.name = "Station_EmergencyTable"

        let tableCylinder = SCNCylinder(radius: 1.4, height: 0.4)
        let tableMat = SCNMaterial()
        tableMat.diffuse.contents = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
        tableMat.roughness.contents = 0.2
        tableMat.metalness.contents = 0.7
        tableCylinder.materials = [tableMat]
        let tableBase = SCNNode(geometry: tableCylinder)
        tableBase.position = SCNVector3(0, 0.2, 0)
        emergencyTableNode.addChildNode(tableBase)

        // Glowing amber rim
        let rimTorus = SCNTorus(ringRadius: 1.4, pipeRadius: 0.04)
        let rimMat = SCNMaterial()
        rimMat.diffuse.contents = amber
        rimMat.emission.contents = amber
        rimMat.emission.intensity = 0.7
        rimTorus.materials = [rimMat]
        let rimNode = SCNNode(geometry: rimTorus)
        rimNode.position = SCNVector3(0, 0.4, 0)
        emergencyTableNode.addChildNode(rimNode)

        // Iconic Red/Amber Among Us Emergency Button on Center Table
        let buttonCollar = SCNCylinder(radius: 0.36, height: 0.05)
        let collarMat = SCNMaterial()
        collarMat.diffuse.contents = NSColor(white: 0.25, alpha: 1.0)
        collarMat.metalness.contents = 0.8
        buttonCollar.materials = [collarMat]
        let collarNode = SCNNode(geometry: buttonCollar)
        collarNode.position = SCNVector3(0, 0.42, 0)
        emergencyTableNode.addChildNode(collarNode)

        let emergencyButton = SCNCylinder(radius: 0.28, height: 0.16)
        let btnMat = SCNMaterial()
        let redOrange = NSColor(calibratedRed: 1.0, green: 0.22, blue: 0.12, alpha: 1.0)
        btnMat.lightingModel = .constant
        btnMat.diffuse.contents = redOrange
        btnMat.emission.contents = redOrange
        btnMat.emission.intensity = 0.55
        emergencyButton.materials = [btnMat]
        let emergencyBtnNode = SCNNode(geometry: emergencyButton)
        emergencyBtnNode.position = SCNVector3(0, 0.46, 0)
        emergencyTableNode.addChildNode(emergencyBtnNode)

        // Floating holographic briefing ring
        let holoTorus = SCNTorus(ringRadius: 0.85, pipeRadius: 0.02)
        let holoMat = SCNMaterial()
        holoMat.diffuse.contents = amber
        holoMat.emission.contents = amber
        holoMat.emission.intensity = 0.65
        holoTorus.materials = [holoMat]
        let holoNode = SCNNode(geometry: holoTorus)
        holoNode.position = SCNVector3(0, 0.9, 0)
        holoNode.runAction(
            SCNAction.repeatForever(
                SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 4.0)
            )
        )
        emergencyTableNode.addChildNode(holoNode)

        let approvalBanner = createStationBannerNode(title: "✋ APPROVAL TABLE", subtitle: "WAITING FOR YOU", color: amber)
        approvalBanner.position = SCNVector3(0, 0.25, 1.95)
        emergencyTableNode.addChildNode(approvalBanner)
        scene.rootNode.addChildNode(emergencyTableNode)

        // 3. Reactor: Hazard Zone at X: 0.0, Z: -5.5
        reactorNode.position = Self.reactorCenter
        reactorNode.name = "Station_Reactor"

        // Plasma core
        let reactorCore = SCNCylinder(radius: 1.1, height: 2.2)
        let coreMat = SCNMaterial()
        let coreColor = NSColor(calibratedRed: 1.0, green: 0.2, blue: 0.1, alpha: 1.0)
        coreMat.diffuse.contents = coreColor
        coreMat.emission.contents = coreColor
        coreMat.emission.intensity = 0.55
        reactorCore.materials = [coreMat]
        let reactorBase = SCNNode(geometry: reactorCore)
        reactorBase.position = SCNVector3(0, 1.1, 0)
        reactorNode.addChildNode(reactorBase)

        // Containment cooling rings
        for ringY in [0.5, 1.1, 1.7] {
            let ringTorus = SCNTorus(ringRadius: 1.25, pipeRadius: 0.05)
            let ringMat = SCNMaterial()
            ringMat.diffuse.contents = NSColor(white: 0.3, alpha: 1.0)
            ringMat.metalness.contents = 0.8
            ringTorus.materials = [ringMat]
            let ringNode = SCNNode(geometry: ringTorus)
            ringNode.position = SCNVector3(0, CGFloat(ringY), 0)
            reactorNode.addChildNode(ringNode)
        }

        // Hazard perimeter line
        let hazardPerimeter = SCNTorus(ringRadius: 2.2, pipeRadius: 0.03)
        let hazardMat = SCNMaterial()
        hazardMat.diffuse.contents = hazardColor
        hazardMat.emission.contents = hazardColor
        hazardMat.emission.intensity = 0.7
        hazardPerimeter.materials = [hazardMat]
        let hazardNode = SCNNode(geometry: hazardPerimeter)
        hazardNode.position = SCNVector3(0, 0.02, 0)
        reactorNode.addChildNode(hazardNode)

        addRoomBorderWalls(
            to: reactorNode,
            centerOffset: SCNVector3(0, 0, -0.2),
            width: 5.0,
            length: 4.4,
            color: hazardColor,
            openBottom: true
        )
        let reactorBanner = createStationBannerNode(title: "⚠️ REACTOR", subtitle: "WARNINGS & LOOPS", color: hazardColor)
        reactorBanner.position = SCNVector3(0, 2.55, 0.4)
        reactorNode.addChildNode(reactorBanner)
        scene.rootNode.addChildNode(reactorNode)

        // 4. Launchpad / Airlock at X: 5.0, Z: 0.0
        launchpadNode.position = Self.launchpadCenter
        launchpadNode.name = "Station_Launchpad"

        let padCylinder = SCNCylinder(radius: 1.8, height: 0.1)
        let padMat = SCNMaterial()
        padMat.diffuse.contents = NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.12, alpha: 1.0)
        padMat.metalness.contents = 0.6
        padCylinder.materials = [padMat]
        let padBase = SCNNode(geometry: padCylinder)
        padBase.position = SCNVector3(0.4, 0.05, -0.8)
        launchpadNode.addChildNode(padBase)

        // Green runway boundary lights
        for i in 0..<8 {
            let angle = (Double(i) * 2.0 * .pi) / 8.0
            let marker = SCNSphere(radius: 0.05)
            let markerMat = SCNMaterial()
            markerMat.diffuse.contents = green
            markerMat.emission.contents = green
            markerMat.emission.intensity = 0.7
            marker.materials = [markerMat]
            let markerNode = SCNNode(geometry: marker)
            markerNode.position = SCNVector3(0.4 + 1.6 * cos(angle), 0.1, -0.8 + 1.6 * sin(angle))
            launchpadNode.addChildNode(markerNode)
        }

        // Airlock Blast Door Frame at back (X: 2.2)
        let archBox = SCNBox(width: 0.2, height: 2.4, length: 2.6, chamferRadius: 0.05)
        let archMat = SCNMaterial()
        archMat.diffuse.contents = NSColor(white: 0.2, alpha: 1.0)
        archMat.metalness.contents = 0.8
        archBox.materials = [archMat]
        let archNode = SCNNode(geometry: archBox)
        archNode.position = SCNVector3(2.2, 1.2, -0.8)
        launchpadNode.addChildNode(archNode)

        addRoomBorderWalls(
            to: launchpadNode,
            centerOffset: SCNVector3(0.4, 0, -0.8),
            width: 4.4,
            length: 4.0,
            color: green,
            openLeft: true
        )
        let launchBanner = createStationBannerNode(title: "✅ LAUNCHPAD", subtitle: "COMPLETED / READY", color: green)
        launchBanner.position = SCNVector3(0.4, 0.35, -3.15)
        launchpadNode.addChildNode(launchBanner)
        scene.rootNode.addChildNode(launchpadNode)

        // 5. MedBay Charging Nests at X: 0.0, Z: 4.5
        medBayNode.position = Self.medBayCenter
        medBayNode.name = "Station_MedBay"

        addRoomBorderWalls(
            to: medBayNode,
            centerOffset: SCNVector3(0, 0, 1.2),
            width: 14.2,
            length: 4.8,
            color: medBlue,
            openTop: true
        )
        let medBanner = createStationBannerNode(title: "💤 SLEEPING NESTS", subtitle: "IDLE / STANDBY", color: medBlue)
        medBanner.position = SCNVector3(0, 0.25, 3.95)
        medBayNode.addChildNode(medBanner)
        scene.rootNode.addChildNode(medBayNode)

        // Baseline 3 desks + 3 nests (expanded dynamically if more simultaneous agents run)
        ensureStationCapacity(workingCount: 0, idleCount: 0)
    }

    private func ensureStationCapacity(
        workingCount: Int,
        idleCount: Int,
        occupiedWorkingSlots: Set<Int>? = nil,
        occupiedIdleSlots: Set<Int>? = nil
    ) {
        let targetDesks = max(3, workingCount)
        while terminalDeskNodes.count < targetDesks {
            let slotIndex = terminalDeskNodes.count
            let worldSlot = Self.codeBaySlotPosition(for: slotIndex)
            let terminal = createTerminalConsoleNode()
            terminal.name = "CodeBayDesk_\(slotIndex)"
            terminal.position = SCNVector3(
                worldSlot.x - Self.codeBayCenter.x,
                0.0,
                worldSlot.z - Self.codeBayCenter.z
            )
            codeBayNode.addChildNode(terminal)
            terminalDeskNodes.append(terminal)
        }

        let targetNests = max(3, idleCount)
        while chargingPodNodes.count < targetNests {
            let slotIndex = chargingPodNodes.count
            let worldSlot = Self.medBaySlotPosition(for: slotIndex)
            let podNode = createChargingPodNode()
            podNode.name = "MedBayNest_\(slotIndex)"
            podNode.position = SCNVector3(
                worldSlot.x - Self.medBayCenter.x,
                0.0,
                worldSlot.z - Self.medBayCenter.z
            )
            medBayNode.addChildNode(podNode)
            chargingPodNodes.append(podNode)
        }

        for (idx, desk) in terminalDeskNodes.enumerated() {
            desk.isHidden = occupiedWorkingSlots.map { !$0.contains(idx) } ?? (idx >= workingCount)
        }
        for (idx, pod) in chargingPodNodes.enumerated() {
            pod.isHidden = occupiedIdleSlots.map { !$0.contains(idx) } ?? (idx >= idleCount)
        }
    }

    private func createStationBannerNode(
        title: String,
        subtitle: String,
        color: NSColor,
        width: CGFloat = 3.6,
        height: CGFloat = 0.92
    ) -> SCNNode {
        let size = NSSize(width: 520, height: 132)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12)
        let plaque = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.09, alpha: 0.96).setFill()
        plaque.fill()
        color.setStroke()
        plaque.lineWidth = 4.0
        plaque.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .heavy),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        NSAttributedString(string: title, attributes: titleAttrs).draw(
            with: NSRect(x: 16, y: 62, width: size.width - 32, height: 44),
            options: [.usesLineFragmentOrigin]
        )

        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 19, weight: .heavy),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        NSAttributedString(string: subtitle, attributes: subtitleAttrs).draw(
            with: NSRect(x: 16, y: 18, width: size.width - 32, height: 32),
            options: [.usesLineFragmentOrigin]
        )

        image.unlockFocus()

        let plane = SCNPlane(width: width, height: height)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = false
        mat.writesToDepthBuffer = false
        mat.diffuse.contents = image
        mat.emission.contents = NSColor.black
        mat.isDoubleSided = true
        plane.materials = [mat]

        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-0.95, 0, 0)
        node.renderingOrder = 25
        return node
    }

    private func addRoomBorderWalls(
        to parent: SCNNode,
        centerOffset: SCNVector3,
        width: CGFloat,
        length: CGFloat,
        color: NSColor,
        openTop: Bool = false,
        openBottom: Bool = false,
        openLeft: Bool = false,
        openRight: Bool = false
    ) {
        let wallHeight: CGFloat = 0.24
        let wallThick: CGFloat = 0.08
        let halfW = width / 2.0
        let halfL = length / 2.0

        let wallMat = SCNMaterial()
        wallMat.diffuse.contents = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.18, alpha: 1.0)
        wallMat.emission.contents = color
        wallMat.emission.intensity = 0.22

        func makeSegment(w: CGFloat, l: CGFloat, x: CGFloat, z: CGFloat) {
            let box = SCNBox(width: w, height: wallHeight, length: l, chamferRadius: 0.02)
            box.materials = [wallMat]
            let node = SCNNode(geometry: box)
            node.position = SCNVector3(centerOffset.x + x, wallHeight / 2.0, centerOffset.z + z)
            parent.addChildNode(node)
        }

        for (isOpen, isHorizontal, fixedPos) in [
            (openTop, true, -halfL), (openBottom, true, halfL),
            (openLeft, false, -halfW), (openRight, false, halfW)
        ] {
            let span = isHorizontal ? width : length
            let side = (span - (isHorizontal ? 2.2 : 2.0)) / 2.0
            for (segSpan, offset) in (isOpen ? [(side, -(span - side) / 2.0), (side, (span - side) / 2.0)] : [(span, 0)]) {
                makeSegment(w: isHorizontal ? segSpan : wallThick, l: isHorizontal ? wallThick : segSpan, x: isHorizontal ? offset : fixedPos, z: isHorizontal ? fixedPos : offset)
            }
        }
    }

    /// Low-profile personal cyber workstation floor mat (each working Bitz brings its own holographic laptop).
    private func createTerminalConsoleNode() -> SCNNode {
        let matNode = SCNNode()

        let baseBox = SCNBox(width: 1.30, height: 0.04, length: 1.30, chamferRadius: 0.08)
        let baseMat = SCNMaterial()
        baseMat.diffuse.contents = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.18, alpha: 1.0)
        baseMat.metalness.contents = 0.6
        baseMat.roughness.contents = 0.35
        baseBox.materials = [baseMat]
        let baseGeometryNode = SCNNode(geometry: baseBox)
        baseGeometryNode.position = SCNVector3(0, 0.02, 0)
        matNode.addChildNode(baseGeometryNode)

        let padBox = SCNBox(width: 1.10, height: 0.02, length: 1.10, chamferRadius: 0.06)
        let padMat = SCNMaterial()
        let screenCyan = NSColor(calibratedRed: 0.0, green: 0.85, blue: 0.95, alpha: 1.0)
        padMat.diffuse.contents = NSColor(calibratedRed: 0.05, green: 0.16, blue: 0.22, alpha: 1.0)
        padMat.emission.contents = screenCyan
        padMat.emission.intensity = 0.14
        padBox.materials = [padMat]
        let padNode = SCNNode(geometry: padBox)
        padNode.position = SCNVector3(0, 0.045, 0)
        matNode.addChildNode(padNode)

        return matNode
    }

    private func createChargingPodNode() -> SCNNode {
        let podNode = SCNNode()

        // Base nest frame
        let podBase = SCNBox(width: 1.35, height: 0.2, length: 1.6, chamferRadius: 0.10)
        let podMat = SCNMaterial()
        podMat.diffuse.contents = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1.0)
        podMat.metalness.contents = 0.6
        podBase.materials = [podMat]
        let baseNode = SCNNode(geometry: podBase)
        baseNode.position = SCNVector3(0, 0.1, 0)
        podNode.addChildNode(baseNode)

        // Glowing nest pillow cushion
        let cushion = SCNBox(width: 1.05, height: 0.08, length: 1.3, chamferRadius: 0.05)
        let cushionMat = SCNMaterial()
        let blue = NSColor(calibratedRed: 0.18, green: 0.50, blue: 0.95, alpha: 1.0)
        cushionMat.diffuse.contents = NSColor(calibratedRed: 0.07, green: 0.14, blue: 0.24, alpha: 1.0)
        cushionMat.emission.contents = blue
        cushionMat.emission.intensity = 0.12
        cushion.materials = [cushionMat]
        let cushionNode = SCNNode(geometry: cushion)
        cushionNode.position = SCNVector3(0, 0.18, 0)
        podNode.addChildNode(cushionNode)

        return podNode
    }

    // MARK: - Station Target Placement

    public static func codeBaySlotPosition(for slotIndex: Int) -> SCNVector3 {
        let safeSlot = max(0, slotIndex)
        if safeSlot < codeBayDeskSlots.count {
            return codeBayDeskSlots[safeSlot]
        }
        let overflow = safeSlot - codeBayDeskSlots.count
        let col = overflow % 2
        let row = overflow / 2
        return SCNVector3(-9.9 - CGFloat(col) * 2.8, 0, -4.5 + CGFloat(row) * 2.4)
    }

    public static func medBaySlotPosition(for slotIndex: Int) -> SCNVector3 {
        let safeSlot = max(0, slotIndex)
        if safeSlot < medBayNestSlots.count {
            return medBayNestSlots[safeSlot]
        }
        let overflow = safeSlot - medBayNestSlots.count
        let col = overflow % 4
        let row = overflow / 4
        return SCNVector3(-4.35 + CGFloat(col) * 2.9, 0, 9.3 + CGFloat(row) * 2.4)
    }

    public static func targetPosition(
        for state: AgentSessionLifecycleState,
        warning: AgentWarningReason?,
        slotIndex: Int,
        totalInStation: Int
    ) -> SCNVector3 {
        let safeSlot = max(0, slotIndex)
        let count = max(1, totalInStation)

        switch state {
        case .working:
            return codeBaySlotPosition(for: safeSlot)

        case .needsApproval:
            // Emergency Table perimeter circle
            let angle = (2.0 * CGFloat.pi * CGFloat(safeSlot)) / CGFloat(count)
            let radius: CGFloat = count <= 2 ? 1.8 : 2.3
            return SCNVector3(radius * cos(angle), 0, radius * sin(angle))

        case .warning:
            if warning == .loop {
                // Orbiting around reactor core
                let angle = (2.0 * CGFloat.pi * CGFloat(safeSlot)) / CGFloat(count)
                let radius: CGFloat = 1.6
                return SCNVector3(radius * cos(angle), 0, -5.5 + radius * sin(angle))
            } else {
                // Standing at reactor perimeter barrier
                let xOffset = (CGFloat(safeSlot) - CGFloat(count - 1) / 2.0) * 2.8
                return SCNVector3(xOffset, 0, -3.8)
            }

        case .almostDone:
            // Approaching launchpad
            let zOffset = count == 1 ? 0.0 : (CGFloat(safeSlot) - CGFloat(count - 1) / 2.0) * 2.4
            return SCNVector3(3.6, 0, zOffset)

        case .done:
            // Centered on launchpad for 1, 2-column grid for multiple
            if count == 1 {
                return SCNVector3(5.0, 0, 0)
            }
            let col = safeSlot % 2
            let row = safeSlot / 2
            return SCNVector3(5.0 + CGFloat(col) * 2.8, 0, -1.5 + CGFloat(row) * 2.4)

        case .failed:
            // Knocked out on launchpad edge
            return SCNVector3(5.8 + CGFloat(safeSlot) * 2.8, 0, 1.2)

        case .idle:
            return medBaySlotPosition(for: safeSlot)
        }
    }

    private static func stationGroupKey(for session: AgentSessionSnapshot) -> String {
        if session.lifecycleState == .warning {
            return session.activeWarning == .loop ? "warning_loop" : "warning_barrier"
        }
        return session.lifecycleState.rawValue
    }

    // MARK: - Session Synchronization

    public func syncSessions(_ sessions: [AgentSessionSnapshot], selectedSessionKey: String?) {
        let currentKeys = Set(crewmateNodes.keys)
        let incomingKeys = Set(sessions.map(\.stateKey))
        let hadExistingCrewmates = !currentKeys.isEmpty

        // 1. Remove obsolete crewmates
        let removedKeys = currentKeys.subtracting(incomingKeys)
        for key in removedKeys {
            lastAutoCommsSignatures.removeValue(forKey: key)
            if let node = crewmateNodes.removeValue(forKey: key) {
                node.removeAction(forKey: "reactorOrbit")
                node.removeAction(forKey: "commsWalk")
                node.removeAction(forKey: "commsReceive")
                node.removeFromParentNode()
            }
        }

        // Group incoming sessions by station zone to compute stable, non-overlapping slot distribution
        var sessionsByStation: [String: [AgentSessionSnapshot]] = [:]
        for session in sessions {
            let key = Self.stationGroupKey(for: session)
            sessionsByStation[key, default: []].append(session)
        }

        for stationKey in Array(assignedStationSlots.keys) {
            if sessionsByStation[stationKey] == nil {
                assignedStationSlots.removeValue(forKey: stationKey)
            }
        }

        var resolvedSlots: [String: Int] = [:]
        for (stationKey, group) in sessionsByStation {
            let activeGroupKeys = Set(group.map(\.stateKey))
            var currentMap = (assignedStationSlots[stationKey] ?? [:]).filter { activeGroupKeys.contains($0.key) }

            let isFixedDeskStation = (stationKey == AgentSessionLifecycleState.working.rawValue || stationKey == AgentSessionLifecycleState.idle.rawValue)
            if !isFixedDeskStation {
                for (k, slot) in currentMap where slot >= group.count {
                    currentMap.removeValue(forKey: k)
                }
            }

            var usedSlots = Set(currentMap.values)
            for session in group where currentMap[session.stateKey] == nil {
                var candidate = 0
                while usedSlots.contains(candidate) {
                    candidate += 1
                }
                currentMap[session.stateKey] = candidate
                usedSlots.insert(candidate)
            }

            assignedStationSlots[stationKey] = currentMap
            for (k, slot) in currentMap {
                resolvedSlots[k] = slot
            }
        }

        // Provision a dedicated personal desk/nest for every occupied working/idle slot
        let activeWorkingSlots = Set((assignedStationSlots[AgentSessionLifecycleState.working.rawValue] ?? [:]).values)
        let activeIdleSlots = Set((assignedStationSlots[AgentSessionLifecycleState.idle.rawValue] ?? [:]).values)
        let workingCapacity = max(sessions.filter { $0.lifecycleState == .working }.count, (activeWorkingSlots.max() ?? -1) + 1)
        let idleCapacity = max(sessions.filter { $0.lifecycleState == .idle }.count, (activeIdleSlots.max() ?? -1) + 1)
        ensureStationCapacity(
            workingCount: workingCapacity,
            idleCount: idleCapacity,
            occupiedWorkingSlots: activeWorkingSlots,
            occupiedIdleSlots: activeIdleSlots
        )

        var autoCommsCandidate: (sender: String, recipient: String)?

        // 2. Add or update crewmates
        for session in sessions {
            let stationKey = Self.stationGroupKey(for: session)
            let slotIndex = resolvedSlots[session.stateKey] ?? 0
            let totalInStation = sessionsByStation[stationKey]?.count ?? 1

            let targetPos = Self.targetPosition(
                for: session.lifecycleState,
                warning: session.activeWarning,
                slotIndex: slotIndex,
                totalInStation: totalInStation
            )

            if let existingNode = crewmateNodes[session.stateKey] {
                let oldState = existingNode.sessionSnapshot.lifecycleState
                let oldWarning = existingNode.sessionSnapshot.activeWarning
                let stateChanged = (oldState != session.lifecycleState || oldWarning != session.activeWarning)
                existingNode.update(with: session)

                // Check for inter-agent message/handoff events
                if let toolHint = commsToolSignature(for: session),
                   lastAutoCommsSignatures[session.stateKey] != toolHint,
                   let peer = sessions.first(where: { $0.stateKey != session.stateKey }) {
                    lastAutoCommsSignatures[session.stateKey] = toolHint
                    autoCommsCandidate = (sender: session.stateKey, recipient: peer.stateKey)
                } else if oldState != .done && session.lifecycleState == .done,
                          let workingPeer = sessions.first(where: { $0.stateKey != session.stateKey && $0.lifecycleState == .working }) {
                    autoCommsCandidate = (sender: session.stateKey, recipient: workingPeer.stateKey)
                }

                let positionDelta = hypot(existingNode.position.x - targetPos.x, existingNode.position.z - targetPos.z)
                let isWalkingComms = (existingNode.action(forKey: "commsWalk") != nil)

                if stateChanged || (!isWalkingComms && positionDelta > 0.15) {
                    let duration: TimeInterval
                    if session.lifecycleState == .needsApproval {
                        duration = 0.6 // Sprint to table
                    } else if session.lifecycleState == .almostDone {
                        duration = 0.5 // Sprint to pad
                    } else {
                        duration = 0.8
                    }

                    existingNode.removeAction(forKey: "reactorOrbit")
                    existingNode.removeAction(forKey: "commsWalk")
                    let moveAction = SCNAction.move(to: targetPos, duration: duration)
                    moveAction.timingMode = .easeInEaseOut
                    existingNode.runAction(moveAction)

                    if session.lifecycleState == .warning && session.activeWarning == .loop {
                        startReactorOrbit(for: existingNode, slotIndex: slotIndex, totalInStation: totalInStation)
                    }
                }
            } else {
                // Create brand new crewmate node
                let newNode = CyberCatCrewmateNode(session: session)
                newNode.position = targetPos
                scene.rootNode.addChildNode(newNode)
                crewmateNodes[session.stateKey] = newNode

                if session.lifecycleState == .warning && session.activeWarning == .loop {
                    startReactorOrbit(for: newNode, slotIndex: slotIndex, totalInStation: totalInStation)
                }

                // When a new subagent/peer joins an active squad, animate a briefing walk to it
                if hadExistingCrewmates,
                   let mentorKey = sessions.first(where: { $0.stateKey != session.stateKey && $0.lifecycleState == .working })?.stateKey
                    ?? currentKeys.first {
                    autoCommsCandidate = (sender: mentorKey, recipient: session.stateKey)
                }
            }
        }

        // 3. Update selection state
        for (key, node) in crewmateNodes {
            node.isSelected = (key == selectedSessionKey)
        }

        if let comms = autoCommsCandidate {
            triggerMessageDelivery(from: comms.sender, to: comms.recipient)
        }

        if lastViewportSize.width > 1 {
            updateCameraForViewport(size: lastViewportSize)
        }
    }

    // MARK: - Inter-Agent Message Delivery Walk

    /// Animates a sender crewmate walking toward a peer crewmate across the ship with a glowing
    /// data packet, delivering a message, and walking back to its station desk/nest.
    public func triggerMessageDelivery(
        from senderKey: String,
        to recipientKey: String,
        message: String = "📨 Handoff"
    ) {
        guard senderKey != recipientKey,
              let senderNode = crewmateNodes[senderKey],
              let recipientNode = crewmateNodes[recipientKey] else {
            return
        }

        lastCommsPair = (sender: senderKey, recipient: recipientKey)

        senderNode.removeAction(forKey: "commsWalk")
        recipientNode.removeAction(forKey: "commsReceive")

        let homePos = senderNode.position
        let meetPos = SCNVector3(
            recipientNode.position.x - 0.9,
            0.0,
            recipientNode.position.z + 0.3
        )

        senderNode.messagePacketNode.isHidden = false
        senderNode.activeCommsBanner = "📨 → \(recipientNode.sessionSnapshot.agentName.uppercased())"

        let walkThere = SCNAction.move(to: meetPos, duration: 0.75)
        walkThere.timingMode = .easeInEaseOut

        let deliver = SCNAction.run({ [weak senderNode, weak recipientNode] _ in
            senderNode?.messagePacketNode.isHidden = true
            recipientNode?.activeCommsBanner = "📨 MSG RECEIVED!"
            let hopUp = SCNAction.moveBy(x: 0, y: 0.25, z: 0, duration: 0.16)
            let hopDown = SCNAction.moveBy(x: 0, y: -0.25, z: 0, duration: 0.16)
            recipientNode?.modelContainerNode.runAction(SCNAction.sequence([hopUp, hopDown]), forKey: "commsReceive")
        }, queue: .main)

        let pause = SCNAction.wait(duration: 0.65)

        let walkBack = SCNAction.move(to: homePos, duration: 0.75)
        walkBack.timingMode = .easeInEaseOut

        let finish = SCNAction.run({ [weak senderNode, weak recipientNode] _ in
            senderNode?.messagePacketNode.isHidden = true
            senderNode?.activeCommsBanner = nil
            recipientNode?.activeCommsBanner = nil
        }, queue: .main)

        senderNode.runAction(
            SCNAction.sequence([walkThere, deliver, pause, walkBack, finish]),
            forKey: "commsWalk"
        )
    }

    private func commsToolSignature(for session: AgentSessionSnapshot) -> String? {
        guard let req = session.linkedApprovalRequest else { return nil }
        let combined = "\(req.toolName ?? "") \(req.commandSummary ?? "")".lowercased()
        let keywords = ["subagent", "send_message", "swarm", "teamwork", "handoff"]
        guard keywords.contains(where: { combined.contains($0) }) else { return nil }
        return "\(req.id):\(combined)"
    }

    private func startReactorOrbit(for node: CyberCatCrewmateNode, slotIndex: Int, totalInStation: Int) {
        node.removeAction(forKey: "reactorOrbit")
        let baseAngle = (2.0 * Double.pi * Double(slotIndex)) / max(1.0, Double(totalInStation))
        let orbitAction = SCNAction.customAction(duration: 2.0) { node, elapsedTime in
            let progress = elapsedTime / 2.0
            let angle = baseAngle - progress * 2.0 * .pi
            let radius: CGFloat = 1.6
            node.position = SCNVector3(
                radius * cos(CGFloat(angle)),
                0,
                -5.5 + radius * sin(CGFloat(angle))
            )
            node.eulerAngles = SCNVector3(0, CGFloat(-angle + .pi / 2), 0)
        }
        node.runAction(SCNAction.repeatForever(orbitAction), forKey: "reactorOrbit")
    }

    // MARK: - Hit-Testing Resolution

    public func crewmateNode(for hitNode: SCNNode) -> CyberCatCrewmateNode? {
        var current: SCNNode? = hitNode
        while let node = current {
            if let crewmate = node as? CyberCatCrewmateNode {
                return crewmate
            }
            current = node.parent
        }
        return nil
    }
}
