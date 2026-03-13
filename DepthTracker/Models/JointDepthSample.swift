import Foundation
import simd

struct JointDepthSample: Identifiable {
    let id = UUID()
    let frameNumber: Int
    let timestamp: TimeInterval  // seconds since recording start
    let pelvisDepth: Float       // meters from camera
    let headDepth: Float
    let leftFootDepth: Float
    let rightFootDepth: Float
    let pelvisDelta: Float       // frame-to-frame depth change
    let headDelta: Float
    let leftFootDelta: Float
    let rightFootDelta: Float

    /// World-space (x, y, z) positions for ALL skeleton joints.
    /// Keys are ARKit joint names (e.g. "hips_joint", "left_hand_joint", etc.)
    let allJointPositions: [String: SIMD3<Float>]
}

struct ChartDataPoint: Identifiable {
    let id = UUID()
    let frame: Int
    let depth: Float
    let joint: String
}
