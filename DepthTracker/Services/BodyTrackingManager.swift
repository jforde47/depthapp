import ARKit
import AVFoundation
import CoreGraphics
import RealityKit

class BodyTrackingManager: NSObject, ARSessionDelegate {

    let session = ARSession()

    /// Called on each frame when recording is active
    var onSample: ((JointDepthSample) -> Void)?

    private var isRecording = false
    private var frameCount = 0
    private var recordingStartTime: TimeInterval = 0
    private var previousDepths: [String: Float] = [:]

    // Clean video recording (no overlay)
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoStartTime: CMTime?

    // Skeleton overlay video recording
    private var skeletonWriter: AVAssetWriter?
    private var skeletonWriterInput: AVAssetWriterInput?
    private var skeletonPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var skeletonVideoStartTime: CMTime?
    var skeletonVideoURL: URL?

    private var videoCompletion: (() -> Void)?

    // Reusable CIContext for pixel buffer conversion
    private let ciContext = CIContext()

    // Last known body data for skeleton rendering (used when didUpdate frame fires)
    private var lastBodyAnchor: ARBodyAnchor?

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
        lastBodyAnchor = nil

        // Skeleton overlay video URL
        let skeletonFilename = videoOutputURL.deletingPathExtension().lastPathComponent + "_skeleton.mp4"
        skeletonVideoURL = FileManager.default.temporaryDirectory.appendingPathComponent(skeletonFilename)

        setupVideoWriter(outputURL: videoOutputURL)
        setupSkeletonWriter(outputURL: skeletonVideoURL!)
        isRecording = true
    }

    func stopRecording(completion: @escaping () -> Void) {
        isRecording = false
        videoCompletion = completion
        finishAllVideoWriting()
    }

    // MARK: - Video Writer Setup

    private static let videoWidth = 1920
    private static let videoHeight = 1080

    private func makeWriterAndInput(outputURL: URL) -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)? {
        try? FileManager.default.removeItem(at: outputURL)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return nil }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.videoWidth,
            AVVideoHeightKey: Self.videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.videoWidth,
            kCVPixelBufferHeightKey as String: Self.videoHeight
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attrs
        )

        writer.add(input)
        writer.startWriting()

        return (writer, input, adaptor)
    }

    private func setupVideoWriter(outputURL: URL) {
        guard let (w, i, a) = makeWriterAndInput(outputURL: outputURL) else { return }
        assetWriter = w
        assetWriterInput = i
        pixelBufferAdaptor = a
        videoStartTime = nil
    }

    private func setupSkeletonWriter(outputURL: URL) {
        guard let (w, i, a) = makeWriterAndInput(outputURL: outputURL) else { return }
        skeletonWriter = w
        skeletonWriterInput = i
        skeletonPixelBufferAdaptor = a
        skeletonVideoStartTime = nil
    }

    private func appendFrame(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        startTime: inout CMTime?
    ) {
        guard writer.status == .writing else { return }

        let time = CMTime(seconds: timestamp, preferredTimescale: 600)

        if startTime == nil {
            startTime = time
            writer.startSession(atSourceTime: time)
        }

        guard input.isReadyForMoreMediaData else { return }

        if let scaled = scalePixelBuffer(pixelBuffer, to: CGSize(width: Self.videoWidth, height: Self.videoHeight)) {
            adaptor.append(scaled, withPresentationTime: time)
        }
    }

    private func scalePixelBuffer(_ source: CVPixelBuffer, to size: CGSize) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: source)
        let scaleX = size.width / CGFloat(CVPixelBufferGetWidth(source))
        let scaleY = size.height / CGFloat(CVPixelBufferGetHeight(source))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var outputBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer)

        if let outputBuffer {
            ciContext.render(scaled, to: outputBuffer)
        }
        return outputBuffer
    }

    private func finishAllVideoWriting() {
        let group = DispatchGroup()

        // Finish clean video
        if let writer = assetWriter {
            group.enter()
            assetWriterInput?.markAsFinished()
            writer.finishWriting { group.leave() }
        }

        // Finish skeleton video
        if let writer = skeletonWriter {
            group.enter()
            skeletonWriterInput?.markAsFinished()
            writer.finishWriting { group.leave() }
        }

        group.notify(queue: .main) { [weak self] in
            self?.assetWriter = nil
            self?.assetWriterInput = nil
            self?.pixelBufferAdaptor = nil
            self?.videoStartTime = nil
            self?.skeletonWriter = nil
            self?.skeletonWriterInput = nil
            self?.skeletonPixelBufferAdaptor = nil
            self?.skeletonVideoStartTime = nil
            self?.videoCompletion?()
            self?.videoCompletion = nil
        }
    }

    // MARK: - Skeleton Overlay Rendering

    /// Project all joints to 2D, draw skeleton + depth text on top of camera frame.
    private func renderSkeletonOverlay(
        onto pixelBuffer: CVPixelBuffer,
        bodyAnchor: ARBodyAnchor,
        frame: ARFrame,
        depths: [String: Float]
    ) -> CVPixelBuffer? {
        let width = Self.videoWidth
        let height = Self.videoHeight

        // Scale source to output size
        guard let scaledBuffer = scalePixelBuffer(pixelBuffer, to: CGSize(width: width, height: height)) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(scaledBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(scaledBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(scaledBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(scaledBuffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // CGContext has origin at bottom-left; camera image is top-left.
        // Flip vertically so our drawing matches the image.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let viewportSize = CGSize(width: width, height: height)
        let skeleton = bodyAnchor.skeleton
        let definition = skeleton.definition

        // Collect 2D projected positions for all joints
        var jointScreenPositions: [Int: CGPoint] = [:]
        let jointNames = definition.jointNames

        for (index, jointName) in jointNames.enumerated() {
            let jointKey = ARSkeleton.JointName(rawValue: jointName)
            guard let modelTransform = skeleton.modelTransform(for: jointKey) else { continue }
            let worldTransform = bodyAnchor.transform * modelTransform
            let worldPos = SIMD3<Float>(worldTransform.columns.3.x,
                                         worldTransform.columns.3.y,
                                         worldTransform.columns.3.z)
            let screenPoint = frame.camera.projectPoint(worldPos,
                                                         orientation: .portrait,
                                                         viewportSize: viewportSize)
            jointScreenPositions[index] = screenPoint
        }

        // Draw bones (lines from child to parent)
        let parentIndices = definition.parentIndices
        ctx.setStrokeColor(CGColor(red: 0, green: 1, blue: 0.4, alpha: 0.9))
        ctx.setLineWidth(3.0)

        for (childIndex, parentIndex) in parentIndices.enumerated() {
            guard parentIndex >= 0,
                  let childPt = jointScreenPositions[childIndex],
                  let parentPt = jointScreenPositions[parentIndex] else { continue }
            ctx.move(to: childPt)
            ctx.addLine(to: parentPt)
        }
        ctx.strokePath()

        // Draw joint dots
        ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1.0))
        for (_, pt) in jointScreenPositions {
            ctx.fillEllipse(in: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8))
        }

        // Draw depth text box (pelvis, left foot, right foot)
        drawDepthTextBox(ctx: ctx, depths: depths, width: width)

        return scaledBuffer
    }

    private func drawDepthTextBox(ctx: CGContext, depths: [String: Float], width: Int) {
        let lines: [(String, Float?)] = [
            ("Pelvis",  depths["pelvis"]),
            ("L Foot",  depths["leftFoot"]),
            ("R Foot",  depths["rightFoot"])
        ]

        let boxWidth: CGFloat = 220
        let lineHeight: CGFloat = 22
        let padding: CGFloat = 10
        let boxHeight = padding * 2 + lineHeight * CGFloat(lines.count) + lineHeight * 0.3  // header
        let boxX = CGFloat(width) - boxWidth - 16
        let boxY: CGFloat = 16

        // Background
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
        let boxRect = CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
        ctx.fill(boxRect)

        // Border
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        ctx.setLineWidth(1)
        ctx.stroke(boxRect)

        // Text
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 14, nil)
        var yOffset = boxY + padding

        for (label, depthVal) in lines {
            let depthStr: String
            if let d = depthVal, !d.isNaN {
                depthStr = String(format: "%.3f m", d)
            } else {
                depthStr = "-- m"
            }

            let text = "\(label): \(depthStr)"
            let attrString = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            ])

            let line = CTLineCreateWithAttributedString(attrString)
            ctx.textPosition = CGPoint(x: boxX + padding, y: yOffset + lineHeight - 4)
            CTLineDraw(line, ctx)
            yOffset += lineHeight
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording else { return }

        let timestamp = frame.timestamp

        // Write clean video frame
        if let writer = assetWriter, let input = assetWriterInput, let adaptor = pixelBufferAdaptor {
            appendFrame(pixelBuffer: frame.capturedImage, timestamp: timestamp,
                       writer: writer, input: input, adaptor: adaptor, startTime: &videoStartTime)
        }

        // Write skeleton overlay frame (if we have body data)
        if let body = lastBodyAnchor,
           let sWriter = skeletonWriter, let sInput = skeletonWriterInput, let sAdaptor = skeletonPixelBufferAdaptor,
           sWriter.status == .writing {
            // Compute depths for text overlay
            let inverseCam = simd_inverse(frame.camera.transform)
            var depths: [String: Float] = [:]
            for (jointName, label) in Self.trackedJoints {
                let key = ARSkeleton.JointName(rawValue: jointName)
                if let mt = body.skeleton.modelTransform(for: key) {
                    let wt = body.transform * mt
                    let cs = inverseCam * wt
                    depths[label] = -cs.columns.3.z
                }
            }

            if let overlayBuffer = renderSkeletonOverlay(onto: frame.capturedImage, bodyAnchor: body, frame: frame, depths: depths) {
                let time = CMTime(seconds: timestamp, preferredTimescale: 600)
                if skeletonVideoStartTime == nil {
                    skeletonVideoStartTime = time
                    sWriter.startSession(atSourceTime: time)
                }
                if sInput.isReadyForMoreMediaData {
                    sAdaptor.append(overlayBuffer, withPresentationTime: time)
                }
            }
        } else if let sWriter = skeletonWriter, let sInput = skeletonWriterInput, let sAdaptor = skeletonPixelBufferAdaptor {
            // No body detected yet — write plain frame to skeleton video too
            appendFrame(pixelBuffer: frame.capturedImage, timestamp: timestamp,
                       writer: sWriter, input: sInput, adaptor: sAdaptor, startTime: &skeletonVideoStartTime)
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard isRecording,
              let frame = session.currentFrame else { return }

        for anchor in anchors {
            guard let bodyAnchor = anchor as? ARBodyAnchor else { continue }
            lastBodyAnchor = bodyAnchor
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
                depths[label] = previousDepths[label] ?? .nan
                continue
            }

            let jointWorldTransform = bodyAnchor.transform * jointModelTransform
            let jointCameraSpace = inverseCameraTransform * jointWorldTransform
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

        // Extract ALL joint world-space positions
        var allJointPositions: [String: SIMD3<Float>] = [:]
        let skeleton = bodyAnchor.skeleton
        let jointNames = skeleton.definition.jointNames

        for jointName in jointNames {
            let jointKey = ARSkeleton.JointName(rawValue: jointName)
            guard let modelTransform = skeleton.modelTransform(for: jointKey) else { continue }
            let worldTransform = bodyAnchor.transform * modelTransform
            allJointPositions[jointName] = SIMD3<Float>(
                worldTransform.columns.3.x,
                worldTransform.columns.3.y,
                worldTransform.columns.3.z
            )
        }

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
            rightFootDelta: rightFootDelta,
            allJointPositions: allJointPositions
        )

        previousDepths = depths
        frameCount += 1

        DispatchQueue.main.async { [weak self] in
            self?.onSample?(sample)
        }
    }
}
