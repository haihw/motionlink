import AppKit
import Combine
import RealityKit
import SwiftUI

struct PaperFlightArenaView: NSViewRepresentable {
    let flight: PaperFlightState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeCoordinator() -> Coordinator { Coordinator(flight: flight) }
    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.environment.background = .color(NSColor(red: 0.40, green: 0.71, blue: 0.87, alpha: 1))
        context.coordinator.build(in: view)
        view.setAccessibilityLabel("Paper plane above the sea, flying through eight rings. Avoid dark storm clouds.")
        return view
    }
    func updateNSView(_ view: ARView, context: Context) { context.coordinator.reduceMotion = reduceMotion }
    static func dismantleNSView(_ view: ARView, coordinator: Coordinator) { coordinator.subscription?.cancel() }

    @MainActor final class Coordinator {
        let flight: PaperFlightState
        let root = AnchorEntity(world: .zero)
        let plane = Entity()
        let camera = PerspectiveCamera()
        var subscription: (any Cancellable)?
        var reduceMotion = false
        private var rings: [ModelEntity] = []
        private var beacons: [ModelEntity] = []
        private var trails: [ModelEntity] = []
        private var trailHistory: [(SIMD3<Float>, SIMD3<Float>)] = []
        private var lastID: UUID?
        private var lastResults: [FlightRingResult] = []
        private var lastNext = -1
        private var cameraPosition = SIMD3<Float>.zero
        private var cameraTarget = SIMD3<Float>.zero
        private var trailBoost = false
        private var trailClock = 0.0
        init(flight: PaperFlightState) { self.flight = flight }

        func build(in view: ARView) {
            camera.camera.fieldOfViewInDegrees = 60
            root.addChild(camera)
            let sun = DirectionalLight()
            sun.light.intensity = 3800
            sun.look(at: [0, 0, -100], from: [-80, 100, 50], relativeTo: nil)
            root.addChild(sun)
            let fill = DirectionalLight()
            fill.light.intensity = 1100; fill.light.color = NSColor(red: 0.65, green: 0.85, blue: 1, alpha: 1)
            fill.look(at: [0, 4, -100], from: [40, 30, -300], relativeTo: nil); root.addChild(fill)
            let sea = ModelEntity(mesh: .generateBox(size: [1800, 0.3, 1800]), materials: [SimpleMaterial(color: NSColor(red: 0.10, green: 0.42, blue: 0.57, alpha: 1), roughness: 0.8, isMetallic: false)])
            sea.position = [0, -0.2, -250]; root.addChild(sea)
            // Sparse stripes give a reliable sense of altitude and forward speed.
            let lineMesh = MeshResource.generateBox(size: [1, 1, 1])
            for index in 0..<44 {
                let stripe = ModelEntity(mesh: lineMesh, materials: [UnlitMaterial(color: NSColor(red: 0.25, green: 0.58, blue: 0.68, alpha: 1))])
                stripe.scale = [90, 0.015, 0.11]; stripe.position = [0, -0.025, -Float(index) * 10]; root.addChild(stripe)
            }
            let course = PaperFlightCourse()
            if let ringMesh = Self.torus(radius: 4.8, tube: 0.15) {
                for ring in course.rings {
                    let entity = ModelEntity(mesh: ringMesh, materials: [UnlitMaterial(color: .systemCyan)])
                    entity.position = ring.center; root.addChild(entity); rings.append(entity)
                    let marker = ModelEntity(mesh: .generateSphere(radius: 0.23), materials: [UnlitMaterial(color: .systemYellow)])
                    marker.position = ring.center; root.addChild(marker); beacons.append(marker)
                }
            }
            let cloudMesh = MeshResource.generateSphere(radius: 1)
            for obstacle in course.obstacles {
                let cloud = Entity(); cloud.position = obstacle.center
                let material = SimpleMaterial(color: NSColor(red: 0.20, green: 0.23, blue: 0.34, alpha: 1), roughness: 1, isMetallic: false)
                for (offset, radius): (SIMD3<Float>, Float) in [([0, 0, 0], 2.0), ([-1.1, -0.3, 0], 1.45), ([1.1, -0.2, 0], 1.45), ([0.2, 0.9, 0.1], 1.5)] {
                    let puff = ModelEntity(mesh: cloudMesh, materials: [material]); puff.scale = .init(repeating: radius); puff.position = offset; cloud.addChild(puff)
                }
                for (x, y, angle): (Float, Float, Float) in [(0, -0.7, -0.35), (0.2, -1.45, 0.4)] {
                    let bolt = ModelEntity(mesh: lineMesh, materials: [UnlitMaterial(color: .systemOrange)])
                    bolt.scale = [0.18, 1.05, 0.16]; bolt.position = [x, y, 2.05]
                    bolt.orientation = simd_quatf(angle: angle, axis: [0, 0, 1]); cloud.addChild(bolt)
                }
                root.addChild(cloud)
            }
            for (index, center) in course.windCenters.enumerated() {
                for j in 0..<5 {
                    let ribbon = ModelEntity(mesh: lineMesh, materials: [UnlitMaterial(color: NSColor(red: 0.55, green: 0.89, blue: 0.95, alpha: 1))])
                    ribbon.scale = [1.6, 0.045, 0.045]
                    ribbon.position = center + [Float(j % 2) * 2 - 1, Float(j) * 0.7 - 1.4, Float(index % 2) * 2]
                    root.addChild(ribbon)
                }
            }
            for index in 0..<32 {
                let cloud = ModelEntity(mesh: cloudMesh, materials: [SimpleMaterial(color: NSColor(white: 0.96, alpha: 1), roughness: 1, isMetallic: false)])
                cloud.scale = [5 + Float(index % 3), 1.3 + Float(index % 2), 2.5]
                cloud.position = [index % 2 == 0 ? -26 - Float(index % 5) * 3 : 26 + Float(index % 5) * 4,
                                  20 + Float(index % 4) * 2, 15 - Float(index) * 13]
                root.addChild(cloud)
            }
            Self.makePlane(plane); root.addChild(plane)
            for _ in 0..<64 {
                let streak = ModelEntity(mesh: lineMesh, materials: [UnlitMaterial(color: .white)])
                streak.isEnabled = false; root.addChild(streak); trails.append(streak)
            }
            view.scene.addAnchor(root)
            tick(deltaTime: 1 / 60)
            subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                let dt = event.deltaTime
                Task { @MainActor in self?.tick(deltaTime: dt) }
            }
        }
        private func tick(deltaTime: Double) {
            let game = flight.snapshot
            let dt = min(0.1, max(0, deltaTime.isFinite ? deltaTime : 0))
            let newFlight = lastID != game.flightID
            if newFlight { lastID = game.flightID; trailHistory = []; lastResults = []; lastNext = -1; trailClock = 0 }
            plane.position = game.position
            plane.orientation = game.orientation.rotation
            if game.phase == .crashed && !reduceMotion {
                plane.orientation *= simd_quatf(angle: Float(min(1, game.phaseAge)) * 1.7, axis: [0, 0, 1])
            }
            let heading = simd_quatf(angle: -game.heading, axis: [0, 1, 0])
            let desiredPosition = game.position + heading.act([0, 3.2, 9])
            let desiredTarget = game.position + heading.act([0, 0.7, -10])
            let blend: Float = newFlight ? 1 : 1 - exp(-Float(dt) * (reduceMotion ? 12 : 7))
            cameraPosition += (desiredPosition - cameraPosition) * blend
            cameraTarget += (desiredTarget - cameraTarget) * blend
            camera.look(at: cameraTarget, from: cameraPosition, relativeTo: nil)
            if lastResults != game.results || lastNext != game.nextRing {
                lastResults = game.results; lastNext = game.nextRing
                for index in rings.indices {
                    let result = game.results[index]
                    let color: NSColor = result == .perfect ? .systemYellow : result == .passed ? .systemGreen : result == .missed ? .darkGray : index == game.nextRing ? .systemYellow : .systemCyan
                    rings[index].model?.materials = [UnlitMaterial(color: color)]
                    beacons[index].isEnabled = result == .ahead
                    beacons[index].model?.materials = [UnlitMaterial(color: index == game.nextRing ? .systemYellow : .systemCyan)]
                }
            }
            let boosted = game.boostRemaining > 0
            if boosted != trailBoost {
                trailBoost = boosted
                for trail in trails { trail.model?.materials = [UnlitMaterial(color: boosted ? .systemYellow : .white)] }
            }
            trailClock += dt
            if game.phase == .flying && game.isTracking && game.neutralProgress >= 1 && trailClock >= 1 / 30 {
                trailClock = 0
                let left = game.position + game.orientation.rotation.act([-1.12, 0, 0.83])
                let right = game.position + game.orientation.rotation.act([1.12, 0, 0.83])
                if let previous = trailHistory.last, simd_distance(left, previous.0) > 4 { trailHistory = [] }
                if trailHistory.last.map({ simd_distance(left, $0.0) > 0.02 }) ?? true { trailHistory.append((left, right)) }
                if trailHistory.count > 33 { trailHistory.removeFirst(trailHistory.count - 33) }
            }
            for (index, trail) in trails.enumerated() {
                let step = index / 2
                guard !reduceMotion, step + 1 < trailHistory.count else { trail.isEnabled = false; continue }
                let a = index % 2 == 0 ? trailHistory[step].0 : trailHistory[step].1
                let b = index % 2 == 0 ? trailHistory[step + 1].0 : trailHistory[step + 1].1
                let delta = b - a, length = simd_length(delta)
                trail.isEnabled = length > 0.001
                trail.position = (a + b) / 2
                trail.scale = [0.018 + Float(step) * 0.0005, 0.018, max(0.001, length)]
                if length > 0.001 { trail.orientation = simd_quatf(from: [0, 0, 1], to: delta / length) }
            }
        }
        private static func makePlane(_ parent: Entity) {
            let nose = SIMD3<Float>(0, 0.05, -1.35), tail = SIMD3<Float>(0, 0.27, 0.85)
            let left = SIMD3<Float>(-1.2, 0, 0.9), right = SIMD3<Float>(1.2, 0, 0.9)
            let leftFold = SIMD3<Float>(-0.30, 0.09, 0.8), rightFold = SIMD3<Float>(0.30, 0.09, 0.8)
            let triangles: [([SIMD3<Float>], NSColor)] = [
                ([nose, left, leftFold], .init(white: 0.99, alpha: 1)),
                ([nose, leftFold, tail], .init(red: 0.74, green: 0.86, blue: 0.96, alpha: 1)),
                ([nose, tail, rightFold], .init(red: 0.86, green: 0.92, blue: 0.99, alpha: 1)),
                ([nose, rightFold, right], .init(white: 0.99, alpha: 1)),
                ([nose, SIMD3<Float>(0, -0.25, 0.8), tail], .init(red: 0.40, green: 0.62, blue: 0.85, alpha: 1))
            ]
            for (vertices, color) in triangles {
                let normal = simd_normalize(simd_cross(vertices[1] - vertices[0], vertices[2] - vertices[0]))
                var mesh = MeshDescriptor(name: "Folded paper")
                mesh.positions = MeshBuffers.Positions(vertices + vertices)
                mesh.normals = MeshBuffers.Normals(Array(repeating: normal, count: 3) + Array(repeating: -normal, count: 3))
                mesh.primitives = .triangles([0, 1, 2, 5, 4, 3])
                if let resource = try? MeshResource.generate(from: [mesh]) {
                    parent.addChild(ModelEntity(mesh: resource, materials: [SimpleMaterial(color: color, roughness: 0.9, isMetallic: false)]))
                }
            }
        }
        private static func torus(radius: Float, tube: Float) -> MeshResource? {
            var vertices: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
            let major = 80, minor = 8
            for i in 0...major {
                let a = Float(i) * 2 * .pi / Float(major)
                for j in 0...minor {
                    let b = Float(j) * 2 * .pi / Float(minor)
                    let normal = SIMD3<Float>(cos(a) * cos(b), sin(a) * cos(b), sin(b))
                    vertices.append([cos(a) * (radius + tube * cos(b)), sin(a) * (radius + tube * cos(b)), tube * sin(b)])
                    normals.append(normal)
                    if i < major && j < minor {
                        let k = UInt32(i * (minor + 1) + j), n = UInt32(minor + 1)
                        indices += [k, k + 1, k + n, k + 1, k + n + 1, k + n]
                    }
                }
            }
            var mesh = MeshDescriptor(name: "Flight ring")
            mesh.positions = MeshBuffers.Positions(vertices); mesh.normals = MeshBuffers.Normals(normals); mesh.primitives = .triangles(indices)
            return try? MeshResource.generate(from: [mesh])
        }
    }
}
