import Foundation

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
}

struct ChartDataPoint: Identifiable {
    let id = UUID()
    let frame: Int
    let depth: Float
    let joint: String
}
