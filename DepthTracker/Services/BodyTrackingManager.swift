import ARKit
import AVFoundation
import RealityKit

class BodyTrackingManager: NSObject, ARSessionDelegate {

    let session = ARSession()

    /// Called on each frame when recording is active
    var onSample: ((JointDepthSample) -> Void)?

    private var isRecording = false
    private var frameCount = 0
    private var recordingStartTime: TimeInterval = 0
    private var previousDepths: [String: Float] = [:]

    // Video recording
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoStartTime: CMTime?
    private var videoCompletion: (() -> Void)?

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

    func startSession(useFrontCamera: Bool = false) {
        if useFrontCamera {
            guard ARFaceTrackingConfiguration.isSupported else {
                print("ARFaceTrackingConfiguration is not supported on this device.")
                return
            }
            let config = ARFaceTrackingConfiguration()
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        } else {
            guard ARBodyTrackingConfiguration.isSupported else {
                print("ARBodyTrackingConfiguration is not supported on this device.")
                return
            }
            let config = ARBodyTrackingConfiguration()
            config.automaticSkeletonScaleEstimationEnabled = true
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    func stopSession() {
        session.pause()
    }

    func startRecording(videoOutputURL: URL) {
        frameCount = 0
        recordingStartTime = 0
        previousDepths = [:]
        setupVideoWriter(outputURL: videoOutputURL)
        isRecording = true
    }

    func stopRecording(completion: @escaping () -> Void) {
        isRecording = false
        videoCompletion = completion
        finishVideoWriting()
    }

    // MARK: - Video Writer Setup

    private func setupVideoWriter(outputURL: URL) {
        // Clean up existing file
        try? FileManager.default.removeItem(at: outputURL)

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1920,
                AVVideoHeightKey: 1080,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6_000_000
                ]
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true

            let sourcePixelAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1080
            ]

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: sourcePixelAttributes
            )

            writer.add(input)
            writer.startWriting()

            assetWriter = writer
            assetWriterInput = input
            pixelBufferAdaptor = adaptor
            videoStartTime = nil
        } catch {
            print("Failed to create AVAssetWriter: \(error)")
        }
    }

    private func writeVideoFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        guard let writer = assetWriter,
              let input = assetWriterInput,
              let adaptor = pixelBufferAdaptor,
              writer.status == .writing else { return }

        let time = CMTime(seconds: timestamp, preferredTimescale: 600)

        if videoStartTime == nil {
            videoStartTime = time
            writer.startSession(atSourceTime: time)
        }

        guard input.isReadyForMoreMediaData else { return }

        // Scale pixel buffer to output size
        if let scaledBuffer = scalePixelBuffer(pixelBuffer, to: CGSize(width: 1920, height: 1080)) {
            adaptor.append(scaledBuffer, withPresentationTime: time)
        }
    }

    private func scalePixelBuffer(_ source: CVPixelBuffer, to size: CGSize) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: source)
        let scaleX = size.width / CGFloat(CVPixelBufferGetWidth(source))
        let scaleY = size.height / CGFloat(CVPixelBufferGetHeight(source))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let context = CIContext()
        var outputBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer)

        if let outputBuffer {
            context.render(scaled, to: outputBuffer)
        }
        return outputBuffer
    }

    private func finishVideoWriting() {
        guard let writer = assetWriter else {
            DispatchQueue.main.async { self.videoCompletion?() }
            return
        }

        assetWriterInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            DispatchQueue.main.async {
                self?.assetWriter = nil
                self?.assetWriterInput = nil
                self?.pixelBufferAdaptor = nil
                self?.videoStartTime = nil
                self?.videoCompletion?()
                self?.videoCompletion = nil
            }
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording else { return }
        writeVideoFrame(frame.capturedImage, timestamp: frame.timestamp)
    }

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
