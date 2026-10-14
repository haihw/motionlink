import AppKit
import RealityKit
import SwiftUI

/// Model axes match a portrait iPhone: +X right, +Y toward the top, +Z out of the screen.
struct PhoneModelView: NSViewRepresentable {
    let orientation: MotionQuaternion
    let movement: MotionEstimate
    let rotationRate: MotionVector

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.environment.background = .color(NSColor(red: 0.035, green: 0.05, blue: 0.09, alpha: 1))
        let anchor = AnchorEntity(world: .zero)
        let phone = Self.makePhone()
        phone.position = [0, 0.28, 0]
        anchor.addChild(phone)
        context.coordinator.phone = phone

        let instruments = Entity()
        instruments.position = phone.position
        anchor.addChild(instruments)
        let gimbal = Entity()
        instruments.addChild(gimbal)
        context.coordinator.gimbal = gimbal
        for axis in 0..<3 {
            if let mesh = Self.torus(radius: [1.02, 1.09, 1.16][axis]) {
                let ring = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: Self.axisColor(axis, intensity: 0.22))])
                if axis == 0 { ring.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0]) }
                if axis == 1 { ring.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0]) }
                gimbal.addChild(ring)
                context.coordinator.rings.append(ring)
            }
        }
        for direction in MotionDirection.allCases {
            let arrow = Self.makeArrow(color: Self.axisColor(direction.axis, intensity: 0.18), width: 0.6)
            arrow.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: direction.vector)
            arrow.scale = [1, 1.42, 1]
            instruments.addChild(arrow)
            context.coordinator.axes.append(arrow)
        }
        let travel = Self.makeArrow(color: NSColor(red: 0.32, green: 0.91, blue: 0.77, alpha: 1))
        let acceleration = Self.makeArrow(color: .systemOrange, width: 0.65)
        travel.isEnabled = false; acceleration.isEnabled = false
        instruments.addChild(travel); instruments.addChild(acceleration)
        context.coordinator.travel = travel
        context.coordinator.acceleration = acceleration

        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 42
        camera.position = [1.45, 0.9, 4.2]
        camera.look(at: [0, 0.18, 0], from: camera.position, relativeTo: nil)
        anchor.addChild(camera)

        let key = DirectionalLight()
        key.light.intensity = 2200
        key.light.color = .white
        key.look(at: .zero, from: [2, 3, 4], relativeTo: nil)
        anchor.addChild(key)
        let fill = PointLight()
        fill.light.intensity = 1600
        fill.light.color = NSColor(red: 0.25, green: 0.8, blue: 1, alpha: 1)
        fill.position = [-2, 1, 2]
        anchor.addChild(fill)
        let rim = PointLight()
        rim.light.intensity = 1800
        rim.light.color = NSColor(red: 0.4, green: 1, blue: 0.75, alpha: 1)
        rim.position = [2, 1, -2]
        anchor.addChild(rim)

        let gridMaterial = UnlitMaterial(color: NSColor(white: 0.16, alpha: 1))
        for index in -8...8 {
            let coordinate = Float(index) * 0.25
            let xLine = ModelEntity(mesh: .generateBox(size: [4, 0.002, 0.002]), materials: [gridMaterial])
            xLine.position = [0, coordinate, -0.7]
            let yLine = ModelEntity(mesh: .generateBox(size: [0.002, 4, 0.002]), materials: [gridMaterial])
            yLine.position = [coordinate, 0, -0.7]
            anchor.addChild(xLine); anchor.addChild(yLine)
        }
        view.scene.addAnchor(anchor)
        view.setAccessibilityLabel("3D iPhone with gyroscope rings, highlighted motion axes, a green movement arrow, and an amber acceleration arrow")
        return view
    }

    func updateNSView(_ view: ARView, context: Context) {
        let coordinator = context.coordinator
        // Apply quaternions directly: no Euler-angle discontinuities or animation backlog.
        coordinator.phone?.orientation = orientation.rotation
        coordinator.gimbal?.orientation = orientation.rotation
        let direction = movement.direction
        for (index, arrow) in coordinator.axes.enumerated() {
            let axis = MotionDirection.allCases[index]
            let level: Float = movement.strength(for: axis) > 0.35 ? 1 : 0.18
            if coordinator.axisLevels[index] != level {
                Self.colorArrow(arrow, color: Self.axisColor(axis.axis, intensity: level))
                coordinator.axisLevels[index] = level
            }
        }
        let localDirection = orientation.rotation.inverse.act(direction)
        for (axis, ring) in coordinator.rings.enumerated() {
            let rotation = min(1, abs(rotationRate.simdValue[axis]) / 1.5)
            let level = max(0.22, max(abs(localDirection[axis]), rotation))
            if abs(coordinator.ringLevels[axis] - level) > 0.04 {
                ring.model?.materials = [UnlitMaterial(color: Self.axisColor(axis, intensity: level))]
                coordinator.ringLevels[axis] = level
            }
        }
        Self.updateArrow(coordinator.travel, direction: direction, length: Float(1.1 + min(movement.speed, 2) * 0.2))
        let acceleration = movement.hasAcceleration && movement.isAvailable ? movement.acceleration.simdValue : .zero
        Self.updateArrow(coordinator.acceleration, direction: acceleration, length: Float(0.95 + min(movement.acceleration.magnitude, 5) * 0.09))
        if movement.isAvailable {
            view.setAccessibilityValue("\(movement.directionLabel), acceleration \(String(format: "%.2f", movement.acceleration.magnitude)) meters per second squared, estimated speed \(String(format: "%.2f", movement.speed)) meters per second")
        } else { view.setAccessibilityValue("Motion measurements unavailable") }
    }

    @MainActor final class Coordinator {
        var phone: Entity?
        var gimbal: Entity?
        var rings: [ModelEntity] = []
        var axes: [Entity] = []
        var travel: Entity?
        var acceleration: Entity?
        var axisLevels: [Float] = Array(repeating: 0.18, count: 6)
        var ringLevels: [Float] = Array(repeating: 0.22, count: 3)
    }

    private static func updateArrow(_ arrow: Entity?, direction: SIMD3<Float>, length: Float) {
        guard let arrow else { return }
        let magnitude = simd_length(direction)
        arrow.isEnabled = magnitude > 0.0001
        guard arrow.isEnabled else { return }
        arrow.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: direction / magnitude)
        arrow.scale = [1, length, 1]
    }

    private static func axisColor(_ axis: Int, intensity: Float) -> NSColor {
        let colors: [SIMD3<Float>] = [[0.15, 0.72, 1], [0.32, 0.91, 0.77], [1, 0.45, 0.15]]
        let rgb = colors[axis] * intensity
        return NSColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }

    private static func colorArrow(_ arrow: Entity, color: NSColor) {
        for child in arrow.children {
            (child as? ModelEntity)?.model?.materials = [UnlitMaterial(color: color)]
        }
    }

    private static func makeArrow(color: NSColor, width: Float = 1) -> Entity {
        let arrow = Entity()
        let shaft = ModelEntity(mesh: .generateBox(size: [0.028 * width, 0.82, 0.028 * width]), materials: [UnlitMaterial(color: color)])
        shaft.position = [0, 0.41, 0]
        arrow.addChild(shaft)
        var descriptor = MeshDescriptor(name: "Arrowhead")
        descriptor.positions = .init([[-0.5, 0, -0.5], [0.5, 0, -0.5], [0.5, 0, 0.5], [-0.5, 0, 0.5], [0, 1, 0]])
        descriptor.primitives = .triangles([0, 4, 1, 1, 4, 2, 2, 4, 3, 3, 4, 0, 0, 1, 2, 0, 2, 3])
        if let mesh = try? MeshResource.generate(from: [descriptor]) {
            let head = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
            head.scale = [0.12 * width, 0.18, 0.12 * width]
            head.position = [0, 0.82, 0]
            arrow.addChild(head)
        }
        return arrow
    }

    private static func torus(radius: Float) -> MeshResource? {
        let segments = 96, sides = 8
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for segment in 0..<segments {
            let theta = Float(segment) * 2 * .pi / Float(segments)
            for side in 0..<sides {
                let phi = Float(side) * 2 * .pi / Float(sides)
                let normal = SIMD3<Float>(cos(theta) * cos(phi), sin(theta) * cos(phi), sin(phi))
                positions.append(SIMD3(radius * cos(theta), radius * sin(theta), 0) + normal * 0.009)
                normals.append(normal)
                let a = UInt32(segment * sides + side)
                let b = UInt32(((segment + 1) % segments) * sides + side)
                let c = UInt32(((segment + 1) % segments) * sides + (side + 1) % sides)
                let d = UInt32(segment * sides + (side + 1) % sides)
                indices += [a, b, c, a, c, d]
            }
        }
        var descriptor = MeshDescriptor(name: "Gyroscope ring")
        descriptor.positions = .init(positions)
        descriptor.normals = .init(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    private static func makePhone() -> Entity {
        let phone = Entity()
        let frame = SimpleMaterial(color: NSColor(white: 0.38, alpha: 1), roughness: 0.25, isMetallic: true)
        let dark = SimpleMaterial(color: NSColor(white: 0.018, alpha: 1), roughness: 0.3, isMetallic: false)
        let back = SimpleMaterial(color: NSColor(red: 0.12, green: 0.15, blue: 0.2, alpha: 1), roughness: 0.6, isMetallic: true)
        addBox(to: phone, size: [0.72, 1.48, 0.085], radius: 0.065, material: frame)
        addBox(to: phone, size: [0.69, 1.45, 0.012], radius: 0.06, material: dark, position: [0, 0, 0.043])
        addBox(to: phone, size: [0.69, 1.45, 0.012], radius: 0.06, material: back, position: [0, 0, -0.043])
        var screen = UnlitMaterial(color: NSColor(red: 0.08, green: 0.45, blue: 0.43, alpha: 1))
        if let texture = screenTexture() { screen.color = .init(texture: .init(texture)) }
        addBox(to: phone, size: [0.648, 1.392, 0.004], radius: 0.048, material: screen, position: [0, 0, 0.051])
        addBox(to: phone, size: [0.205, 0.048, 0.006], radius: 0.023, material: dark, position: [0, 0.625, 0.056])
        addBox(to: phone, size: [0.21, 0.008, 0.005], radius: 0.004,
               material: UnlitMaterial(color: .white), position: [0, -0.66, 0.056])
        addBox(to: phone, size: [0.018, 0.16, 0.032], radius: 0.009, material: frame, position: [0.366, 0.24, 0])
        for y: Float in [0.28, 0.06] {
            addBox(to: phone, size: [0.018, 0.13, 0.032], radius: 0.009, material: frame, position: [-0.366, y, 0])
        }
        addBox(to: phone, size: [0.31, 0.34, 0.024], radius: 0.05, material: back, position: [-0.15, 0.48, -0.065])
        for position: SIMD3<Float> in [[-0.225, 0.56, -0.09], [-0.085, 0.46, -0.09], [-0.225, 0.39, -0.09]] {
            let lens = ModelEntity(mesh: .generateSphere(radius: 0.053), materials: [frame])
            lens.scale = [1, 0.14, 1]
            lens.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            lens.position = position
            phone.addChild(lens)
            let glass = ModelEntity(mesh: .generateSphere(radius: 0.039), materials: [
                SimpleMaterial(color: NSColor(red: 0.02, green: 0.04, blue: 0.09, alpha: 1), roughness: 0.05, isMetallic: true)])
            glass.scale = [1, 0.2, 1]
            glass.orientation = lens.orientation
            glass.position = position + SIMD3(0, 0, -0.008)
            phone.addChild(glass)
        }
        return phone
    }

    private static func addBox(to parent: Entity, size: SIMD3<Float>, radius: Float,
                               material: any RealityKit.Material, position: SIMD3<Float> = .zero) {
        let entity = ModelEntity(mesh: .generateBox(size: size, cornerRadius: radius), materials: [material])
        entity.position = position
        parent.addChild(entity)
    }

    private static func screenTexture() -> TextureResource? {
        let image = NSImage(size: NSSize(width: 512, height: 1024))
        image.lockFocus()
        NSColor(red: 0.025, green: 0.1, blue: 0.16, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 512, height: 1024).fill()
        for index in 0..<15 {
            let path = NSBezierPath()
            let offset = CGFloat(index) * 32
            path.move(to: NSPoint(x: -100, y: 80 + offset))
            path.curve(to: NSPoint(x: 600, y: 330 + offset), controlPoint1: NSPoint(x: 170, y: 800 + offset), controlPoint2: NSPoint(x: 390, y: -150 + offset))
            path.lineWidth = 18
            NSColor(red: 0.15, green: 0.8, blue: 0.65, alpha: CGFloat(index + 1) / 22).setStroke()
            path.stroke()
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 76, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        ("9:41" as NSString).draw(in: NSRect(x: 0, y: 765, width: 512, height: 110), withAttributes: attributes)
        ("MotionLink" as NSString).draw(in: NSRect(x: 0, y: 695, width: 512, height: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: paragraph])
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return try? TextureResource.generate(from: cg, options: .init(semantic: .color))
    }
}
