import AppKit
import Combine
import RealityKit
import SwiftUI

struct WokArenaView: NSViewRepresentable {
    let session: MacSession
    let game: WokDemoState
    var reduceMotion = false
    func makeCoordinator() -> Coordinator { Coordinator(session: session, game: game) }
    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.environment.background = .color(NSColor(red: 0.035, green: 0.065, blue: 0.08, alpha: 1))
        view.setAccessibilityLabel("3D cooking station with a motion-controlled wok, fried egg, and serving plate")
        context.coordinator.build(view)
        return view
    }
    func updateNSView(_ view: ARView, context: Context) { context.coordinator.reduceMotion = reduceMotion }
    static func dismantleNSView(_ view: ARView, coordinator: Coordinator) { coordinator.subscription?.cancel() }

    @MainActor final class Coordinator {
        let session: MacSession
        let game: WokDemoState
        let root = AnchorEntity(world: .zero)
        let pan = Entity(), egg = Entity()
        let white = ModelEntity(), underside = ModelEntity(), yolk = ModelEntity()
        var shells: [Entity] = [], steam: [ModelEntity] = [], flame: [ModelEntity] = []
        var servedModels: [Int: Entity] = [:]
        var confetti: [ModelEntity] = []
        var sessionGeneration: UInt64 = 0
        var reduceMotion = false
        var subscription: (any Cancellable)?
        var lastColor = -1
        var clock = 0.0
        init(session: MacSession, game: WokDemoState) { self.session = session; self.game = game }

        func build(_ view: ARView) {
            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 48
            camera.look(at: [0.22, 0.4, 0.25], from: [0.22, 3.65, 5.0], relativeTo: nil)
            root.addChild(camera)
            let light = DirectionalLight(); light.light.intensity = 3200
            light.look(at: .zero, from: [-2, 5, 3], relativeTo: nil); root.addChild(light)
            let warm = PointLight(); warm.light.intensity = 1800; warm.light.color = .systemOrange
            warm.position = [-1.6, 1.8, 1]; root.addChild(warm)
            let fill = PointLight(); fill.light.intensity = 2200; fill.light.color = .systemCyan
            fill.position = [2, 2, -1]; root.addChild(fill)
            box(root, size: [4.5, 0.16, 3.8], at: [0, -0.65, 0.3], color: NSColor(red: 0.10, green: 0.17, blue: 0.18, alpha: 1))
            box(root, size: [3.7, 0.025, 3.1], at: [0, -0.55, 0.3], color: NSColor(white: 0.07, alpha: 1), metal: true)
            let plate = Entity(); plate.position = WokGameEngine.platePosition
            if let mesh = plateMesh() {
                plate.addChild(ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: NSColor(red: 0.96, green: 0.95, blue: 0.89, alpha: 1), roughness: 0.18, isMetallic: false)]))
            }
            if let mesh = ring(radius: 0.50, tube: 0.009) {
                let trim = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: .systemTeal, roughness: 0.22, isMetallic: false)])
                trim.position.y = 0.052; plate.addChild(trim)
            }
            root.addChild(plate)
            let burner = ModelEntity(mesh: cylinderMesh(height: 0.16, radius: 1.15) ?? .generateBox(size: [2.3, 0.16, 2.3]), materials: [SimpleMaterial(color: NSColor(white: 0.08, alpha: 1), roughness: 0.6, isMetallic: true)])
            burner.position.y = -0.39; root.addChild(burner)
            if let mesh = ring(radius: 0.83, tube: 0.026) {
                let ring = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .systemOrange)])
                ring.position.y = -0.29; root.addChild(ring)
            }
            for index in 0..<16 {
                let angle = Float(index) * 2 * .pi / 16
                let fire = ModelEntity(mesh: .generateSphere(radius: 1), materials: [UnlitMaterial(color: NSColor(red: 0.18, green: 0.64, blue: 1, alpha: 0.85))])
                fire.position = [cos(angle) * 0.7, -0.20, sin(angle) * 0.7]
                fire.scale = [0.035, 0.10, 0.035]; flame.append(fire); root.addChild(fire)
            }
            if let mesh = bowl() {
                let body = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: NSColor(white: 0.20, alpha: 1), roughness: 0.30, isMetallic: true)])
                pan.addChild(body)
            }
            if let mesh = ring(radius: 1.05, tube: 0.018) {
                let rim = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: NSColor(white: 0.44, alpha: 1), roughness: 0.28, isMetallic: true)])
                rim.position.y = 0.43; pan.addChild(rim)
            }
            // A painted rim mark makes heading visible on an otherwise symmetric bowl.
            if let markMesh = mesh(name: "Phone top-edge rim mark",
                                   points: [[-0.055, 0.451, -0.985], [0.055, 0.451, -0.985], [0, 0.451, -1.07]],
                                   normals: Array(repeating: [0, 1, 0], count: 3), triangles: [0, 1, 2]) {
                pan.addChild(ModelEntity(mesh: markMesh, materials: [UnlitMaterial(color: .systemMint)]))
            }
            if let mesh = ring(radius: 0.48, tube: 0.009) {
                let oil = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: NSColor(red: 0.9, green: 0.67, blue: 0.15, alpha: 0.6), roughness: 0.08, isMetallic: false)])
                oil.position.y = 0.09; pan.addChild(oil)
            }
            root.addChild(pan)
            if let mesh = eggWhite(under: false) {
                white.name = "Egg white"
                white.model = ModelComponent(mesh: mesh, materials: [SimpleMaterial(color: .white, roughness: 0.25, isMetallic: false)])
                egg.addChild(white)
            }
            if let mesh = eggWhite(under: true) {
                underside.name = "Egg underside"
                underside.model = ModelComponent(mesh: mesh, materials: [SimpleMaterial(color: .white, roughness: 0.4, isMetallic: false)])
                egg.addChild(underside)
            }
            yolk.name = "Egg yolk"
            yolk.model = ModelComponent(mesh: .generateSphere(radius: 1), materials: [SimpleMaterial(color: NSColor(red: 1, green: 0.59, blue: 0.03, alpha: 1), roughness: 0.13, isMetallic: false)])
            yolk.scale = [0.13, 0.085, 0.13]; yolk.position = [0.025, 0.04, -0.015]; egg.addChild(yolk)
            for index in 0..<18 {
                let angle = Float(index) * 2 * .pi / 18
                let dot = ModelEntity(mesh: .generateSphere(radius: 1), materials: [SimpleMaterial(color: NSColor(red: 0.39, green: 0.15, blue: 0.04, alpha: 1), roughness: 0.8, isMetallic: false)])
                dot.scale = [0.012 + Float(index % 3) * 0.005, 0.003, 0.014]
                dot.position = [cos(angle) * 0.20, -0.009, sin(angle) * 0.16]; egg.addChild(dot)
            }
            root.addChild(egg)
            for side: Float in [-1, 1] {
                let shell = Entity()
                if let mesh = shellMesh(side: side) {
                    shell.addChild(ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: NSColor(red: 0.83, green: 0.65, blue: 0.42, alpha: 1), roughness: 0.65, isMetallic: false)]))
                }
                shells.append(shell); root.addChild(shell)
            }
            var steamMaterial = UnlitMaterial(color: NSColor(white: 0.9, alpha: 1))
            steamMaterial.blending = .transparent(opacity: 0.055)
            for _ in 0..<10 {
                let vapor = ModelEntity(mesh: .generateSphere(radius: 1), materials: [steamMaterial])
                steam.append(vapor); root.addChild(vapor)
            }
            let colors: [NSColor] = [.systemYellow, .systemMint, .systemOrange, .systemPink, .systemCyan]
            for index in 0..<45 {
                let piece = ModelEntity(mesh: .generateBox(size: [0.032, 0.009, 0.018]), materials: [UnlitMaterial(color: colors[index % colors.count])])
                piece.isEnabled = false; confetti.append(piece); root.addChild(piece)
            }
            view.scene.addAnchor(root)
            subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                let dt = event.deltaTime
                Task { @MainActor in self?.tick(dt) }
            }
        }

        func tick(_ dt: Double) {
            guard dt.isFinite, dt > 0 else { return }
            clock += min(dt, 0.06)
            // RealityKit can throttle the window below 10 fps. Divide renderer
            // intervals into valid simulation steps rather than discarding every
            // slow frame. Large/background gaps contribute only a bounded step.
            var remaining = min(dt, 0.25)
            while remaining > 0.000001 {
                let step = min(remaining, 0.05)
                game.tick(step, session: session)
                remaining -= step
            }
            let engine = game.engine
            pan.position = engine.panPosition; pan.orientation = engine.panRotation.rotation
            egg.isEnabled = engine.phase != .ready && !(engine.phase == .served && game.cookingSession.currentRecorded)
            egg.position = engine.eggPosition; egg.orientation = engine.eggRotation.rotation
            let bucket = Int(engine.sear[0] * 20) + Int(engine.sear[1] * 20) * 25
            if bucket != lastColor {
                lastColor = bucket
                let first = min(1, engine.sear[0]), second = min(1, engine.sear[1])
                underside.model?.materials = [SimpleMaterial(color: NSColor(red: 1 - first * 0.3, green: 0.96 - first * 0.52, blue: 0.85 - first * 0.65, alpha: 1), roughness: 0.55, isMetallic: false)]
                white.model?.materials = [SimpleMaterial(color: NSColor(red: 1 - second * 0.2, green: 0.94 - second * 0.36, blue: 0.78 - second * 0.50, alpha: 1), roughness: .float(Float(0.25 + second * 0.35)), isMetallic: false)]
                yolk.model?.materials = [SimpleMaterial(color: NSColor(red: 1, green: 0.57 + second * 0.17, blue: 0.04 + second * 0.15, alpha: 1), roughness: .float(Float(0.13 + second * 0.4)), isMetallic: false)]
            }
            if sessionGeneration != game.cookingSession.generation {
                for model in servedModels.values { model.removeFromParent() }
                servedModels.removeAll(); sessionGeneration = game.cookingSession.generation
            }
            for saved in game.cookingSession.pile.eggs {
                let model: Entity
                if let existing = servedModels[saved.id] { model = existing }
                else {
                    model = egg.clone(recursive: true); model.isEnabled = true
                    servedModels[saved.id] = model; root.addChild(model)
                    colorFinishedEgg(model, sear: saved.sear)
                }
                model.position = saved.position; model.orientation = saved.rotation.rotation
                model.isEnabled = saved.position.y > -3
            }
            let celebrationAge = Float(2.8 - game.celebrationRemaining)
            for (index, piece) in confetti.enumerated() {
                piece.isEnabled = game.celebrationRemaining > 0 && !reduceMotion
                guard piece.isEnabled else { continue }
                let angle = Float(index) * 2.39996
                let spread = 0.45 + Float(index % 5) * 0.12
                let velocity = SIMD3<Float>(cos(angle) * spread, 1.3 + Float(index % 7) * 0.13, sin(angle) * spread)
                piece.position = game.celebrationPosition + [0, 0.15, 0] + velocity * celebrationAge
                    + [0, -1.7 * celebrationAge * celebrationAge, 0]
                piece.orientation = simd_quatf(angle: celebrationAge * (4 + Float(index % 4)), axis: simd_normalize(SIMD3<Float>(1, 0.4, sin(angle))))
                piece.scale = SIMD3(repeating: min(1, Float(game.celebrationRemaining) / 0.6))
            }
            for (index, shell) in shells.enumerated() {
                shell.isEnabled = engine.phase == .cracking
                let t = Float(engine.phaseTime), side: Float = index == 0 ? -1 : 1
                shell.position = engine.panPosition + [side * min(0.8, t * 0.9), 1.55 + sin(t * 3) * 0.1, 0]
                shell.orientation = simd_quatf(angle: side * t * 1.5, axis: [0, 0, 1])
            }
            let hot = game.playing && game.input.active && !engine.practiceMode && (engine.phase == .cooking || engine.phase == .airborne || engine.phase == .cracking)
            for (index, vapor) in steam.enumerated() {
                vapor.isEnabled = hot && engine.sear[0] > 0.02
                let age = Float((clock * 0.45 + Double(index) / 10).truncatingRemainder(dividingBy: 1))
                let angle = Float(index) * 2.4
                vapor.position = engine.panPosition + [cos(angle) * 0.28 + sin(age * 5) * 0.06, 0.25 + age * 0.8, sin(angle) * 0.3]
                vapor.scale = SIMD3(repeating: 0.035 + age * 0.09)
            }
            for (index, fire) in flame.enumerated() {
                fire.isEnabled = hot
                fire.scale.y = 0.07 + Float(sin(clock * 8 + Double(index))) * 0.015
            }
        }

        func colorFinishedEgg(_ model: Entity, sear: [Double]) {
            let first = min(1, sear[0]), second = min(1, sear[1])
            (model.findEntity(named: "Egg underside") as? ModelEntity)?.model?.materials = [SimpleMaterial(color: NSColor(red: 1 - first * 0.3, green: 0.96 - first * 0.52, blue: 0.85 - first * 0.65, alpha: 1), roughness: 0.55, isMetallic: false)]
            (model.findEntity(named: "Egg white") as? ModelEntity)?.model?.materials = [SimpleMaterial(color: NSColor(red: 1 - second * 0.2, green: 0.94 - second * 0.36, blue: 0.78 - second * 0.50, alpha: 1), roughness: 0.4, isMetallic: false)]
            (model.findEntity(named: "Egg yolk") as? ModelEntity)?.model?.materials = [SimpleMaterial(color: NSColor(red: 1, green: 0.57 + second * 0.17, blue: 0.04 + second * 0.15, alpha: 1), roughness: 0.3, isMetallic: false)]
        }

        func box(_ parent: Entity, size: SIMD3<Float>, at position: SIMD3<Float>, color: NSColor, metal: Bool = false) {
            let entity = ModelEntity(mesh: .generateBox(size: size, cornerRadius: 0.015), materials: [SimpleMaterial(color: color, roughness: 0.4, isMetallic: metal)])
            entity.position = position; parent.addChild(entity)
        }
        func mesh(name: String, points: [SIMD3<Float>], normals: [SIMD3<Float>], triangles: [UInt32]) -> MeshResource? {
            var descriptor = MeshDescriptor(name: name)
            descriptor.positions = .init(points); descriptor.normals = .init(normals); descriptor.primitives = .triangles(triangles)
            return try? MeshResource.generate(from: [descriptor])
        }
        func cylinderMesh(height: Float, radius: Float) -> MeshResource? {
            var points: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], triangles: [UInt32] = []
            for index in 0..<64 {
                let a = Float(index) * 2 * .pi / 64, b = Float(index + 1) * 2 * .pi / 64
                let first = SIMD3<Float>(cos(a), 0, sin(a)), second = SIMD3<Float>(cos(b), 0, sin(b))
                let start = UInt32(points.count)
                points += [first * radius + [0, -height / 2, 0], first * radius + [0, height / 2, 0],
                           second * radius + [0, height / 2, 0], second * radius + [0, -height / 2, 0]]
                normals += [first, first, second, second]
                triangles += [start, start + 1, start + 2, start, start + 2, start + 3]
                for side: Float in [-1, 1] {
                    let cap = UInt32(points.count), y = side * height / 2
                    points += [[0, y, 0], first * radius + [0, y, 0], second * radius + [0, y, 0]]
                    normals += Array(repeating: [0, side, 0], count: 3)
                    triangles += side > 0 ? [cap, cap + 2, cap + 1] : [cap, cap + 1, cap + 2]
                }
            }
            return mesh(name: "Machined cylinder", points: points, normals: normals, triangles: triangles)
        }
        func bowl() -> MeshResource? {
            let rows = 28, columns = 96
            var points: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], triangles: [UInt32] = []
            for surface in 0..<2 {
                let start = points.count
                for row in 0...rows {
                    let radius = Float(row) / Float(rows) * 1.05
                    for column in 0...columns {
                        let angle = Float(column) * 2 * .pi / Float(columns)
                        let x = cos(angle) * radius, z = sin(angle) * radius
                        points.append([x, 0.04 + 0.39 * radius * radius / (1.05 * 1.05) - (surface == 0 ? 0 : 0.045), z])
                        let n = simd_normalize(SIMD3<Float>(-0.78 * x / (1.05 * 1.05), 1, -0.78 * z / (1.05 * 1.05)))
                        normals.append(surface == 0 ? n : -n)
                        if row < rows && column < columns {
                            let a = UInt32(start + row * (columns + 1) + column), b = a + UInt32(columns + 1)
                            triangles += surface == 0 ? [a, a + 1, b, a + 1, b + 1, b] : [a, b, a + 1, a + 1, b, b + 1]
                        }
                    }
                }
            }
            return mesh(name: "Forged carbon steel wok", points: points, normals: normals, triangles: triangles)
        }
        func plateMesh() -> MeshResource? {
            let rows = 20, columns = 80, radius: Float = 0.53
            var points: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], triangles: [UInt32] = []
            for surface in 0..<2 {
                let start = points.count
                for row in 0...rows {
                    let fraction = Float(row) / Float(rows), r = radius * fraction
                    let y = 0.06 * pow(fraction, 4) - (surface == 0 ? 0 : 0.03)
                    let slope = 0.24 * pow(fraction, 3) / radius
                    for column in 0...columns {
                        let angle = Float(column) * 2 * .pi / Float(columns)
                        points.append([cos(angle) * r, y, sin(angle) * r])
                        let normal = simd_normalize(SIMD3<Float>(-slope * cos(angle), 1, -slope * sin(angle)))
                        normals.append(surface == 0 ? normal : -normal)
                        if row < rows && column < columns {
                            let a = UInt32(start + row * (columns + 1) + column), b = a + UInt32(columns + 1)
                            triangles += surface == 0 ? [a, a + 1, b, a + 1, b + 1, b] : [a, b, a + 1, a + 1, b, b + 1]
                        }
                    }
                }
            }
            return mesh(name: "Ceramic serving plate", points: points, normals: normals, triangles: triangles)
        }
        func ring(radius: Float, tube: Float) -> MeshResource? {
            let rows = 80, columns = 10
            var points: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], triangles: [UInt32] = []
            for row in 0...rows {
                let angle = Float(row) * 2 * .pi / Float(rows)
                for column in 0...columns {
                    let phi = Float(column) * 2 * .pi / Float(columns)
                    let normal = SIMD3<Float>(cos(angle) * cos(phi), sin(phi), sin(angle) * cos(phi))
                    points.append(SIMD3<Float>(cos(angle) * radius, 0, sin(angle) * radius) + normal * tube)
                    normals.append(normal)
                    if row < rows && column < columns {
                        let a = UInt32(row * (columns + 1) + column), b = a + UInt32(columns + 1)
                        triangles += [a, a + 1, b, a + 1, b + 1, b]
                    }
                }
            }
            return mesh(name: "Wok rim", points: points, normals: normals, triangles: triangles)
        }
        func eggWhite(under: Bool) -> MeshResource? {
            var points: [SIMD3<Float>] = [[0, under ? -0.008 : 0.025, 0]]
            var triangles: [UInt32] = []
            for index in 0...80 {
                let a = Float(index) * 2 * .pi / 80
                let r: Float = 1 + sin(a * 3) * 0.06 + cos(a * 5) * 0.07
                points.append([cos(a) * 0.33 * r, under ? -0.008 : 0.006, sin(a) * 0.27 * r])
                if index < 80 { triangles += under ? [0, UInt32(index + 1), UInt32(index + 2)] : [0, UInt32(index + 2), UInt32(index + 1)] }
            }
            return mesh(name: "Organic fried egg", points: points, normals: Array(repeating: [0, under ? -1 : 1, 0], count: points.count), triangles: triangles)
        }
        func shellMesh(side: Float) -> MeshResource? {
            let rows = 20, columns = 40
            var points: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], triangles: [UInt32] = []
            for row in 0...rows {
                let theta = Float(row) / Float(rows) * .pi / 2
                for column in 0...columns {
                    let phi = Float(column) / Float(columns) * 2 * .pi
                    let n = SIMD3<Float>(side * cos(theta), sin(theta) * cos(phi), sin(theta) * sin(phi))
                    points.append(n * SIMD3<Float>(0.16, 0.21, 0.16)); normals.append(n)
                    if row < rows && column < columns {
                        let a = UInt32(row * (columns + 1) + column), b = a + UInt32(columns + 1)
                        let face: [UInt32] = side > 0 ? [a, b, a + 1, a + 1, b, b + 1] : [a, a + 1, b, a + 1, b + 1, b]
                        triangles += face + [face[0], face[2], face[1], face[3], face[5], face[4]]
                    }
                }
            }
            return mesh(name: "Cracked eggshell", points: points, normals: normals, triangles: triangles)
        }
    }
}
