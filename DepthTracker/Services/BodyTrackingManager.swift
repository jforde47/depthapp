import ARKit
import AVFoundation
import CoreGraphics
import RealityKit

class BodyTrackingManager: NSObject, ARSessionDelegate {

    let session = ARSession()

    /// Called on each frame when recording is active
    var onSample: ((JointDepthSample) -> Void)?

    /// Whether LiDAR scene depth is available and enabled
    private(set) var isLidarAvailable = false

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
            isLidarAvailable = false
            let config = ARFaceTrackingConfiguration()
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        } else {
            guard ARBodyTrackingConfiguration.isSupported else {
                print("ARBodyTrackingConfiguration is not supported on this device.")
                return
            }
            let config = ARBodyTrackingConfiguration()
            config.automaticSkeletonScaleEstimationEnabled = true

            // Enable LiDAR scene depth if device supports it
            if ARBodyTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics.insert(.sceneDepth)
                isLidarAvailable = true
            } else {
                isLidarAvailable = false
            }

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

    // MARK: - LiDAR Depth Map Sampling

    /// Sample the LiDAR depth map at a joint's projected 2D position.
    /// Returns depth in meters, or NaN if unavailable.
    private func sampleLidarDepth(
        for worldPosition: SIMD3<Float>,
        frame: ARFrame
    ) -> Float {
        // Prefer smoothed depth (temporally filtered, less noisy)
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return .nan
        }

        let depthMap = depthData.depthMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        // Project world point to depth map coordinates.
        // The depth map is aligned with the camera image in its native orientation (landscape right).
        let depthMapSize = CGSize(width: depthWidth, height: depthHeight)
        let projected = frame.camera.projectPoint(
            worldPosition,
            orientation: .landscapeRight,
            viewportSize: depthMapSize
        )

        let px = Int(projected.x)
        let py = Int(projected.y)

        // Bounds check
        guard px >= 0, px < depthWidth, py >= 0, py < depthHeight else {
            return .nan
        }

        // Sample the Float32 depth map
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return .nan }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        let rowPtr = baseAddress.advanced(by: py * bytesPerRow)
        let pixelPtr = rowPtr.advanced(by: px * MemoryLayout<Float32>.size)
        let depth = pixelPtr.assumingMemoryBound(to: Float32.self).pointee

        // Filter out invalid readings (zero or negative)
        guard depth > 0, !depth.isNaN, !depth.isInfinite else { return .nan }

        return depth
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

        if let writer = assetWriter {
            group.enter()
            assetWriterInput?.markAsFinished()
            writer.finishWriting { group.leave() }
        }

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
        depths: [String: Float],
        lidarDepths: [String: Float]
    ) -> CVPixelBuffer? {
        let width = Self.videoWidth
        let height = Self.videoHeight

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

        // Flip vertically so drawing matches image (CGContext origin is bottom-left)
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

        // Draw bones
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

        // Draw depth text box
        drawDepthTextBox(ctx: ctx, depths: depths, lidarDepths: lidarDepths, width: width)

        return scaledBuffer
    }

    private func drawDepthTextBox(
        ctx: CGContext,
        depths: [String: Float],
        lidarDepths: [String: Float],
        width: Int
    ) {
        let hasLidar = !lidarDepths.isEmpty && lidarDepths.values.contains(where: { !$0.isNaN })

        struct DepthLine {
            let label: String
            let skeletonDepth: Float?
            let lidarDepth: Float?
        }

        let lines: [DepthLine] = [
            DepthLine(label: "Pelvis", skeletonDepth: depths["pelvis"], lidarDepth: lidarDepths["pelvis"]),
            DepthLine(label: "L Foot", skeletonDepth: depths["leftFoot"], lidarDepth: lidarDepths["leftFoot"]),
            DepthLine(label: "R Foot", skeletonDepth: depths["rightFoot"], lidarDepth: lidarDepths["rightFoot"])
        ]

        let boxWidth: CGFloat = hasLidar ? 340 : 220
        let lineHeight: CGFloat = 22
        let padding: CGFloat = 10
        let headerHeight: CGFloat = hasLidar ? lineHeight + 4 : 0
        let boxHeight = padding * 2 + headerHeight + lineHeight * CGFloat(lines.count)
        let boxX = CGFloat(width) - boxWidth - 16
        let boxY: CGFloat = 16

        // Background
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.7))
        let boxRect = CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
        ctx.fill(boxRect)

        // Border
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        ctx.setLineWidth(1)
        ctx.stroke(boxRect)

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 13, nil)
        let smallFont = CTFontCreateWithName("Menlo" as CFString, 11, nil)
        let whiteColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let cyanColor = CGColor(red: 0.3, green: 0.9, blue: 1, alpha: 1)
        let dimColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.5)
        var yOffset = boxY + padding

        // Header row if LiDAR is active
        if hasLidar {
            let header = NSAttributedString(string: "         Skeleton   LiDAR", attributes: [
                .font: smallFont,
                .foregroundColor: dimColor
            ])
            let headerLine = CTLineCreateWithAttributedString(header)
            ctx.textPosition = CGPoint(x: boxX + padding, y: yOffset + lineHeight - 4)
            CTLineDraw(headerLine, ctx)
            yOffset += lineHeight + 4
        }

        for item in lines {
            let skelStr = formatDepth(item.skeletonDepth)

            let text: NSMutableAttributedString
            if hasLidar {
                let lidarStr = formatDepth(item.lidarDepth)
                text = NSMutableAttributedString(
                    string: "\(item.label): \(skelStr)  \(lidarStr)",
                    attributes: [.font: font, .foregroundColor: whiteColor]
                )
                // Color the LiDAR portion cyan
                let lidarRange = NSRange(
                    location: "\(item.label): \(skelStr)  ".count,
                    length: lidarStr.count
                )
                text.addAttribute(.foregroundColor, value: cyanColor, range: lidarRange)
            } else {
                text = NSMutableAttributedString(
                    string: "\(item.label): \(skelStr)",
                    attributes: [.font: font, .foregroundColor: whiteColor]
                )
            }

            let line = CTLineCreateWithAttributedString(text)
            ctx.textPosition = CGPoint(x: boxX + padding, y: yOffset + lineHeight - 4)
            CTLineDraw(line, ctx)
            yOffset += lineHeight
        }
    }

    private func formatDepth(_ depth: Float?) -> String {
        guard let d = depth, !d.isNaN else { return " --  m" }
        return String(format: "%5.3fm", d)
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
            let inverseCam = simd_inverse(frame.camera.transform)
            var depths: [String: Float] = [:]
            var lidarDepths: [String: Float] = [:]

            for (jointName, label) in Self.trackedJoints {
                let key = ARSkeleton.JointName(rawValue: jointName)
                if let mt = body.skeleton.modelTransform(for: key) {
                    let wt = body.transform * mt
                    let cs = inverseCam * wt
                    depths[label] = -cs.columns.3.z

                    // Sample LiDAR depth at this joint's position
                    let worldPos = SIMD3<Float>(wt.columns.3.x, wt.columns.3.y, wt.columns.3.z)
                    lidarDepths[label] = sampleLidarDepth(for: worldPos, frame: frame)
                }
            }

            if let overlayBuffer = renderSkeletonOverlay(
                onto: frame.capturedImage,
                bodyAnchor: body,
                frame: frame,
                depths: depths,
                lidarDepths: lidarDepths
            ) {
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
        var lidarDepths: [String: Float] = [:]

        for (jointName, label) in Self.trackedJoints {
            let jointKey = ARSkeleton.JointName(rawValue: jointName)
            guard let jointModelTransform = bodyAnchor.skeleton.modelTransform(for: jointKey) else {
                depths[label] = previousDepths[label] ?? .nan
                lidarDepths[label] = .nan
                continue
            }

            let jointWorldTransform = bodyAnchor.transform * jointModelTransform
            let jointCameraSpace = inverseCameraTransform * jointWorldTransform
            let depth = -jointCameraSpace.columns.3.z
            depths[label] = depth

            // Sample LiDAR depth map at this joint's projected position
            let worldPos = SIMD3<Float>(
                jointWorldTransform.columns.3.x,
                jointWorldTransform.columns.3.y,
                jointWorldTransform.columns.3.z
            )
            lidarDepths[label] = sampleLidarDepth(for: worldPos, frame: frame)
        }

        // Compute deltas (from skeleton depth)
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
            lidarPelvisDepth: lidarDepths["pelvis"] ?? .nan,
            lidarHeadDepth: lidarDepths["head"] ?? .nan,
            lidarLeftFootDepth: lidarDepths["leftFoot"] ?? .nan,
            lidarRightFootDepth: lidarDepths["rightFoot"] ?? .nan,
            allJointPositions: allJointPositions
        )

        previousDepths = depths
        frameCount += 1

        DispatchQueue.main.async { [weak self] in
            self?.onSample?(sample)
        }
    }
}
