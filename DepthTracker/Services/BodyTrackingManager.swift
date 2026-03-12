import ARKit
import RealityKit

class BodyTrackingManager: NSObject, ARSessionDelegate {

    let session = ARSession()

    /// Called on each frame when recording is active
    var onSample: ((JointDepthSample) -> Void)?

    private var isRecording = false
    private var frameCount = 0
    private var recordingStartTime: TimeInterval = 0
    private var previousDepths: [String: Float] = [:]

    private static let trackedJoints: [(name: String, label: String)] = [
        ("hips_joint",       "pelvis"),
        ("head_joint",       "head"),
        ("left_foot_joint",  "leftFoot"),
        ("right_foot_joint", "rightFoot")
    ]

    override init() {
        super.init()
        session.delegate = self
    }

    func startSession() {
        guard ARBodyTrackingConfiguration.isSupported else {
            print("ARBodyTrackingConfiguration is not supported on this device.")
            return
        }
        let config = ARBodyTrackingConfiguration()
        config.automaticSkeletonScaleEstimationEnabled = true
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stopSession() {
        session.pause()
    }

    func startRecording() {
        frameCount = 0
        recordingStartTime = 0
        previousDepths = [:]
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard isRecording,
              let frame = session.currentFrame else { return }

        for anchor in anchors {
            guard let bodyAnchor = anchor as? ARBodyAnchor else { continue }
            processBody(bodyAnchor, frame: frame)
        }
    }

    // MARK: - Joint Depth Extraction

    private func processBody(_ bodyAnchor: ARBodyAnchor, frame: ARFrame) {
        let cameraTransform = frame.camera.transform
        let inverseCameraTransform = simd_inverse(cameraTransform)

        var depths: [String: Float] = [:]

        for (jointName, label) in Self.trackedJoints {
            let jointKey = ARSkeleton.JointName(rawValue: jointName)
            guard let jointModelTransform = bodyAnchor.skeleton.modelTransform(for: jointKey) else {
                // Joint not tracked this frame — carry forward last known value
                depths[label] = previousDepths[label] ?? .nan
                continue
            }

            // World-space position of joint
            let jointWorldTransform = bodyAnchor.transform * jointModelTransform
            // Camera-space position
            let jointCameraSpace = inverseCameraTransform * jointWorldTransform
            // Depth = distance along camera's viewing axis (camera looks along -Z)
            let depth = -jointCameraSpace.columns.3.z
            depths[label] = depth
        }

        // Compute deltas
        let pelvisDelta = (previousDepths["pelvis"] != nil)
            ? (depths["pelvis"] ?? 0) - (previousDepths["pelvis"] ?? 0)
            : 0
        let headDelta = (previousDepths["head"] != nil)
            ? (depths["head"] ?? 0) - (previousDepths["head"] ?? 0)
            : 0
        let leftFootDelta = (previousDepths["leftFoot"] != nil)
            ? (depths["leftFoot"] ?? 0) - (previousDepths["leftFoot"] ?? 0)
            : 0
        let rightFootDelta = (previousDepths["rightFoot"] != nil)
            ? (depths["rightFoot"] ?? 0) - (previousDepths["rightFoot"] ?? 0)
            : 0

        // Set recording start time on first frame
        if frameCount == 0 {
            recordingStartTime = frame.timestamp
        }
        let timestamp = frame.timestamp - recordingStartTime

        let sample = JointDepthSample(
            frameNumber: frameCount,
            timestamp: timestamp,
            pelvisDepth: depths["pelvis"] ?? .nan,
            headDepth: depths["head"] ?? .nan,
            leftFootDepth: depths["leftFoot"] ?? .nan,
            rightFootDepth: depths["rightFoot"] ?? .nan,
            pelvisDelta: pelvisDelta,
            headDelta: headDelta,
            leftFootDelta: leftFootDelta,
            rightFootDelta: rightFootDelta
        )

        previousDepths = depths
        frameCount += 1

        DispatchQueue.main.async { [weak self] in
            self?.onSample?(sample)
        }
    }
}
