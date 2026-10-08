import Foundation
import RoomPlan
import simd

/// A merged RoomPlan scan as the plain JSON the worker reads (worker/roomplan.py).
/// Our own format rather than RoomPlan's Codable encoding, so the server side does
/// not depend on how Apple happens to encode simd types.
enum ScanExport {
    static func json(_ s: CapturedStructure, names: [String?]) throws -> Data {
        var root: [String: Any] = ["version": 1]
        root["rooms"] = s.rooms.enumerated().map { i, r -> [String: Any] in
            [
                "name": (i < names.count ? names[i] : nil).flatMap { $0.isEmpty ? nil : $0 } as Any? ?? NSNull(),
                "floor": r.floors.first.map(floorCorners) ?? [],
                "sections": r.sections.map { ["label": "\($0.label)", "center": v3($0.center)] },
            ]
        }
        root["walls"] = s.walls.map(surface)
        root["doors"] = s.doors.map(surface)
        root["windows"] = s.windows.map(surface)
        root["openings"] = s.openings.map(surface)
        root["objects"] = s.objects.map { o -> [String: Any] in
            ["category": "\(o.category)", "dimensions": v3(o.dimensions), "transform": m4(o.transform)]
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func surface(_ s: CapturedRoom.Surface) -> [String: Any] {
        [
            "id": s.identifier.uuidString,
            "parent": s.parentIdentifier?.uuidString as Any? ?? NSNull(),
            "dimensions": v3(s.dimensions),
            "transform": m4(s.transform),
        ]
    }

    /// The floor outline in world coordinates (RoomPlan gives it in the floor's own frame).
    static func floorCorners(_ f: CapturedRoom.Surface) -> [[Float]] {
        var local = f.polygonCorners
        if local.count < 3 {
            let w = f.dimensions.x / 2, h = f.dimensions.y / 2
            local = [[-w, -h, 0], [w, -h, 0], [w, h, 0], [-w, h, 0]]
        }
        return local.map { p in
            let q = f.transform * SIMD4<Float>(p.x, p.y, p.z, 1)
            return [q.x, q.y, q.z]
        }
    }

    static func v3(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }

    /// Column-major, like simd stores it.
    static func m4(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}
