import AppKit
import Combine
import RealityKit
import SwiftUI

struct SwordArenaView: NSViewRepresentable {
    let session: MacSession
    let game: SwordDemoState
    func makeCoordinator() -> Coordinator { Coordinator(session: session, game: game) }

    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.environment.background = .color(NSColor(red: 0.035, green: 0.05, blue: 0.09, alpha: 1))
        context.coordinator.build(in: view)
        view.setAccessibilityLabel("Sword arena with three hanging watermelons: Crimson, Golden, and Mini")
        return view
    }
    func updateNSView(_ view: ARView, context: Context) {}
    static func dismantleNSView(_ view: ARView, coordinator: Coordinator) { coordinator.subscription?.cancel() }

    @MainActor final class Coordinator {
        let session: MacSession
        let game: SwordDemoState
        let root = AnchorEntity(world: .zero)
        let sword = Entity()
        var fruits: [Entity] = []
        var ropes: [ModelEntity] = []
        var trail: [ModelEntity] = []
        var subscription: (any Cancellable)?
        private var engine = SwordGameEngine()
        private var round = -1
        private var autoplay = false
        private var time = 0.0
        private var poseRevision = -1
        private var debris: [Debris] = []
        private var tipHistory: [(point: SIMD3<Float>, time: Double)] = []

        struct Debris {
            let entity: Entity
            var velocity: SIMD3<Float>
            let spin: SIMD3<Float>
            var age = 0.0
            let lifetime: Double
        }

        init(session: MacSession, game: SwordDemoState) { self.session = session; self.game = game }

        func build(in view: ARView) {
            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 43
            camera.position = [0, 0.65, 5.6]
            camera.look(at: [0, 0.20, -0.20], from: camera.position, relativeTo: nil)
            root.addChild(camera)
            let key = DirectionalLight()
            key.light.intensity = 2500
            key.look(at: .zero, from: [-2, 4, 4], relativeTo: nil)
            root.addChild(key)
            let fill = PointLight()
            fill.light.intensity = 1400; fill.light.color = .systemCyan
            fill.position = [2, 1, 3]; root.addChild(fill)
            let warm = PointLight()
            warm.light.intensity = 1800; warm.light.color = .systemOrange
            warm.position = [-2, 2, 1]; root.addChild(warm)

            Self.box(root, size: [3.5, 0.10, 0.8], color: NSColor(red: 0.28, green: 0.18, blue: 0.10, alpha: 1), position: [0, 1.8, -0.25])
            for x: Float in [-1.68, 1.68] {
                Self.box(root, size: [0.07, 3.12, 0.10], color: NSColor(red: 0.18, green: 0.12, blue: 0.075, alpha: 1), position: [x, 0.24, -0.06])
            }
            let floor = ModelEntity(mesh: .generateBox(size: [4.6, 0.05, 2.0]), materials: [SimpleMaterial(color: NSColor(white: 0.10, alpha: 1), roughness: 0.85, isMetallic: false)])
            floor.position = [0, -1.32, 0]; root.addChild(floor)
            for x: Float in [-1.1, 0, 1.1] {
                Self.box(root, size: [0.006, 2.8, 0.002], color: NSColor(white: 0.15, alpha: 1), position: [x, 0.15, -0.65])
            }
            for target in WatermelonTarget.orchard {
                let fruit = Self.fruit(target, side: 0)
                fruit.position = target.center
                root.addChild(fruit); fruits.append(fruit)
                let rope = ModelEntity(mesh: .generateBox(size: [1, 1, 1]), materials: [SimpleMaterial(color: NSColor(red: 0.64, green: 0.48, blue: 0.26, alpha: 1), isMetallic: false)])
                rope.scale = [0.014, 1, 0.014]
                root.addChild(rope); ropes.append(rope)
            }
            Self.makeSword(sword)
            root.addChild(sword)
            for _ in 0..<18 {
                let streak = ModelEntity(mesh: .generateBox(size: [1, 1, 1]), materials: [UnlitMaterial(color: .systemCyan)])
                streak.isEnabled = false; root.addChild(streak); trail.append(streak)
            }
            view.scene.addAnchor(root)
            subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                let dt = event.deltaTime
                Task { @MainActor in self?.tick(deltaTime: dt) }
            }
        }

        private func tick(deltaTime: Double) {
            guard deltaTime.isFinite, deltaTime > 0 else { return }
            let dt = min(deltaTime, 0.06)
            if game.round != round {
                round = game.round; time = 0; engine.reset(); tipHistory = []
                for piece in debris { piece.entity.removeFromParent() }
                debris = []
                for fruit in fruits { fruit.isEnabled = true }
            }
            if autoplay != game.isAutoplay || poseRevision != session.poseRevision {
                autoplay = game.isAutoplay; poseRevision = session.poseRevision
                engine.clearSweep(); tipHistory = []
                if autoplay { time = 0 }
            }
            time += dt
            for target in WatermelonTarget.orchard {
                let center = target.position(at: time)
                fruits[target.id].position = center
                let top = SIMD3<Float>(target.center.x, 1.75, target.center.z)
                let bottom = center + SIMD3(0, target.radius * 0.94, 0)
                Self.segment(ropes[target.id], from: bottom, to: top, width: 0.014)
            }

            let live = session.deviceName != nil && !session.isPaused && !session.isStale
                && session.movement.isAvailable && session.isNeutralConfirmed && !session.isDemo && !session.isSwordRecentering
            let pose: SwordPose
            let energy: Bool
            if autoplay {
                let preview = SwordPose.autoplay(at: time)
                pose = preview.pose
                energy = preview.hasSwingEnergy
            } else {
                pose = SwordPose.phone(orientation: session.orientation, displacement: session.swordDisplacement)
                energy = live && ((session.sample?.rotationRate.magnitude ?? 0) >= 1.1 || session.movement.acceleration.magnitude >= 1.8 || session.movement.speed >= 0.22)
                if !live { engine.clearSweep(); tipHistory = [] }
            }
            sword.position = pose.grip
            sword.orientation = pose.rotation.rotation
            for hit in engine.step(pose: pose, deltaTime: deltaTime, hasSwingEnergy: energy, time: time) {
                slice(hit)
                game.cuts.insert(hit.targetID)
                if live && !autoplay { session.haptics.play(.impact(intensity: 0.8, sharpness: 0.75)) }
            }
            if energy && (live || autoplay) { tipHistory.append((pose.tip, time)) }
            tipHistory.removeAll { time - $0.time > 0.23 }
            if tipHistory.count > 19 { tipHistory.removeFirst(tipHistory.count - 19) }
            for (index, streak) in trail.enumerated() {
                streak.isEnabled = index + 1 < tipHistory.count
                if streak.isEnabled {
                    let age = Float(1 - (time - tipHistory[index].time) / 0.23)
                    Self.segment(streak, from: tipHistory[index].point, to: tipHistory[index + 1].point, width: 0.025 * max(0.1, age))
                }
            }
            animateDebris(dt)
        }

        private func slice(_ hit: SwordSlice) {
            let target = WatermelonTarget.orchard[hit.targetID]
            let position = target.position(at: time)
            fruits[hit.targetID].isEnabled = false
            let tangent = hit.cutRotation.act(SIMD3<Float>(0, 1, 0))
            let bitangent = hit.cutRotation.act(SIMD3<Float>(0, 0, 1))
            for side: Float in [-1, 1] {
                let half = Self.fruit(target, side: side, slice: hit)
                half.position = position + hit.normal * (side * 0.025)
                half.orientation = hit.cutRotation
                root.addChild(half)
                let velocity = hit.normal * (side * 0.5) + hit.direction * 0.18 + SIMD3<Float>(0, 0.4, 0)
                debris.append(Debris(entity: half, velocity: velocity, spin: tangent * (side * 0.8), lifetime: 3))
            }
            let capRadius = sqrt(max(0, target.radius * target.radius - hit.offset * hit.offset))
            let planeCenter = position + hit.normal * hit.offset
            for index in 0..<14 {
                let angle = Float(index) * 2 * .pi / 14
                let radial = tangent * cos(angle) + bitangent * sin(angle)
                let juice = ModelEntity(mesh: .generateSphere(radius: 0.022), materials: [UnlitMaterial(color: Self.flesh(target.id))])
                juice.position = planeCenter + radial * (capRadius * 0.35)
                root.addChild(juice)
                let velocity = radial * 0.65 + hit.direction * 0.18 + SIMD3<Float>(0, 0.35, 0)
                debris.append(Debris(entity: juice, velocity: velocity, spin: .zero, lifetime: 1.3))
            }
        }

        private func animateDebris(_ dt: Double) {
            for index in debris.indices {
                debris[index].age += dt
                debris[index].velocity.y -= Float(dt) * 2.7
                debris[index].entity.position += debris[index].velocity * Float(dt)
                let spin = debris[index].spin
                let speed = simd_length(spin)
                if speed > 0 { debris[index].entity.orientation *= simd_quatf(angle: speed * Float(dt), axis: spin / speed) }
                if debris[index].entity.position.y < -1.15 {
                    debris[index].entity.position.y = -1.15
                    debris[index].velocity.y = abs(debris[index].velocity.y) * 0.18
                    debris[index].velocity.x *= 0.94
                }
                let remaining = debris[index].lifetime - debris[index].age
                debris[index].entity.scale = SIMD3(repeating: Float(min(1, max(0, remaining / 0.6))))
            }
            debris.removeAll {
                if $0.age >= $0.lifetime { $0.entity.removeFromParent(); return true }
                return false
            }
        }

        private static func segment(_ entity: Entity, from start: SIMD3<Float>, to end: SIMD3<Float>, width: Float) {
            let delta = end - start
            let length = simd_length(delta)
            entity.position = (start + end) * 0.5
            if length > 0.00001 { entity.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: delta / length) }
            entity.scale = [width, length, width]
        }

        private static func box(_ parent: Entity, size: SIMD3<Float>, color: NSColor, position: SIMD3<Float>, metallic: Bool = false) {
            let entity = ModelEntity(mesh: .generateBox(size: size, cornerRadius: 0.01), materials: [SimpleMaterial(color: color, roughness: metallic ? 0.22 : 0.7, isMetallic: metallic)])
            entity.position = position; parent.addChild(entity)
        }

        private static func makeSword(_ parent: Entity) {
            box(parent, size: [0.075, 0.26, 0.06], color: NSColor(red: 0.12, green: 0.08, blue: 0.06, alpha: 1), position: [0, -0.02, 0])
            for y: Float in [-0.11, -0.065, -0.02, 0.025, 0.07] {
                box(parent, size: [0.085, 0.012, 0.07], color: NSColor(red: 0.52, green: 0.31, blue: 0.10, alpha: 1), position: [0, y, 0], metallic: true)
            }
            box(parent, size: [0.42, 0.065, 0.09], color: NSColor(red: 0.8, green: 0.57, blue: 0.18, alpha: 1), position: [0, 0.13, 0], metallic: true)
            var descriptor = MeshDescriptor(name: "Sword blade")
            descriptor.positions = .init([
                [-0.065, 0.17, 0], [0, 0.17, 0.035], [0.065, 0.17, 0], [0, 0.17, -0.035],
                [-0.045, 1.25, 0], [0, 1.25, 0.026], [0.045, 1.25, 0], [0, 1.25, -0.026], [0, 1.50, 0]
            ])
            descriptor.primitives = .triangles([0, 5, 4, 0, 1, 5, 1, 6, 5, 1, 2, 6, 2, 7, 6, 2, 3, 7, 3, 4, 7, 3, 0, 4, 4, 5, 8, 5, 6, 8, 6, 7, 8, 7, 4, 8])
            if let mesh = try? MeshResource.generate(from: [descriptor]) {
                let blade = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: NSColor(white: 0.85, alpha: 1), roughness: 0.17, isMetallic: true)])
                parent.addChild(blade)
            }
        }

        private static func flesh(_ id: Int) -> NSColor {
            id == 1 ? NSColor(red: 1, green: 0.73, blue: 0.14, alpha: 1) : NSColor(red: 0.95, green: 0.15 + Double(id) * 0.035, blue: 0.23, alpha: 1)
        }

        private static func fruit(_ target: WatermelonTarget, side: Float, slice: SwordSlice? = nil) -> Entity {
            let fruit = Entity()
            let offset = slice?.offset ?? 0
            let cutRotation = slice?.cutRotation ?? MotionQuaternion.identity.rotation
            let capRadius = sqrt(max(0, target.radius * target.radius - offset * offset))
            var skin = SimpleMaterial(color: .systemGreen, roughness: 0.5, isMetallic: false)
            if let texture = skinTexture(target.id) { skin.color = .init(texture: .init(texture)) }
            if let mesh = sphereMesh(radius: target.radius, side: side, offset: offset, cutRotation: cutRotation) {
                fruit.addChild(ModelEntity(mesh: mesh, materials: [skin]))
            }
            if side != 0 {
                for (radius, x, color) in [(capRadius * 0.99, offset - side * 0.001, NSColor(red: 0.85, green: 0.94, blue: 0.64, alpha: 1)),
                                           (capRadius * 0.90, offset - side * 0.003, flesh(target.id))] {
                    if let mesh = disc(radius: radius, normal: -side) {
                        let cap = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: color, roughness: 0.55, isMetallic: false)])
                        cap.position.x = x; fruit.addChild(cap)
                    }
                }
                for index in 0..<9 {
                    let angle = Float(index) * 2 * .pi / 9
                    let seed = ModelEntity(mesh: .generateSphere(radius: 1), materials: [SimpleMaterial(color: NSColor(white: 0.035, alpha: 1), isMetallic: false)])
                    seed.scale = [0.005, 0.022, 0.012]
                    seed.position = [offset - side * 0.007, cos(angle) * capRadius * 0.58, sin(angle) * capRadius * 0.58]
                    fruit.addChild(seed)
                }
            }
            return fruit
        }

        private static func sphereMesh(radius: Float, side: Float, offset: Float, cutRotation: simd_quatf) -> MeshResource? {
            let rows = 32, columns = 64
            let boundary = acos(min(1, max(-1, offset / radius)))
            let lower: Float = side < 0 ? boundary : 0
            let upper: Float = side > 0 ? boundary : .pi
            var points: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = []
            var indices: [UInt32] = []
            for row in 0...rows {
                let theta = lower + (upper - lower) * Float(row) / Float(rows)
                for column in 0...columns {
                    let phi = Float(column) * 2 * .pi / Float(columns)
                    let normal = SIMD3<Float>(cos(theta), sin(theta) * cos(phi), sin(theta) * sin(phi))
                    points.append(normal * radius); normals.append(normal)
                    // Keep skin stripes in the original hanging-fruit orientation.
                    let originalNormal = cutRotation.act(normal)
                    var longitude = atan2(originalNormal.z, originalNormal.y)
                    if longitude < 0 { longitude += 2 * .pi }
                    uv.append([longitude / (2 * .pi), acos(min(1, max(-1, originalNormal.x))) / .pi])
                    if row < rows && column < columns {
                        let a = UInt32(row * (columns + 1) + column), b = a + UInt32(columns + 1)
                        indices += [a, b, a + 1, a + 1, b, b + 1]
                    }
                }
            }
            var descriptor = MeshDescriptor(name: "Watermelon rind")
            descriptor.positions = .init(points); descriptor.normals = .init(normals)
            descriptor.textureCoordinates = .init(uv); descriptor.primitives = .triangles(indices)
            return try? MeshResource.generate(from: [descriptor])
        }

        private static func disc(radius: Float, normal: Float) -> MeshResource? {
            var points: [SIMD3<Float>] = [.zero], indices: [UInt32] = []
            for index in 0...64 {
                let angle = Float(index) * 2 * .pi / 64
                points.append([0, cos(angle) * radius, sin(angle) * radius])
                if index < 64 { indices += normal > 0 ? [0, UInt32(index + 1), UInt32(index + 2)] : [0, UInt32(index + 2), UInt32(index + 1)] }
            }
            var descriptor = MeshDescriptor(name: "Watermelon cut surface")
            descriptor.positions = .init(points)
            descriptor.normals = .init(Array(repeating: [normal, 0, 0], count: points.count))
            descriptor.primitives = .triangles(indices)
            return try? MeshResource.generate(from: [descriptor])
        }

        private static func skinTexture(_ id: Int) -> TextureResource? {
            let image = NSImage(size: NSSize(width: 512, height: 256))
            image.lockFocus()
            let base = id == 1 ? NSColor(red: 0.56, green: 0.68, blue: 0.17, alpha: 1) : id == 2 ? NSColor(red: 0.36, green: 0.64, blue: 0.34, alpha: 1) : NSColor(red: 0.19, green: 0.46, blue: 0.15, alpha: 1)
            base.setFill(); NSRect(x: 0, y: 0, width: 512, height: 256).fill()
            let count = id == 2 ? 14 : 10
            for index in -1...count {
                let path = NSBezierPath()
                let x = CGFloat(index) * 512 / CGFloat(count)
                path.move(to: NSPoint(x: x, y: 0))
                path.curve(to: NSPoint(x: x, y: 256), controlPoint1: NSPoint(x: x + 18, y: 85), controlPoint2: NSPoint(x: x - 18, y: 170))
                path.lineWidth = id == 1 ? 13 : 22
                NSColor(red: 0.05, green: 0.22 + Double(id) * 0.03, blue: 0.08, alpha: 0.85).setStroke(); path.stroke()
            }
            image.unlockFocus()
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return try? TextureResource.generate(from: cg, options: .init(semantic: .color))
        }
    }
}
