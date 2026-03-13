import ARKit
import AVFoundation
import CoreGraphics
import RealityKit

class BodyTrackingManager: NSObject, ARSessionDelegate {

    let session = ARSession()

    /// Called on each frame when recording is active
    var onSample: ((JointDepthSample) -> Void)?

    /// Whether device has LiDAR hardware
    private(set) var hasLidarHardware = false
    /// Whether scene depth is actively being delivered in frames
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

    // Last known body data for skeleton rendering
    private var lastBodyAnchor: ARBodyAnchor?

    // Portrait video dimensions
    private static let videoWidth = 1080
    private static let videoHeight = 1920

    private static let trackedJoints: [(name: String, label: String)] = [
        ("hips_joint",       "pelvis"),
        ("head_joint",       "head"),
        ("left_foot_joint",  "leftFoot"),
        ("right_foot_joint", "rightFoot")
    ]

    override init() {
        super.init()
        session.delegate = self

        // Detect LiDAR hardware by checking if ANY config supports sceneDepth
        hasLidarHardware = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
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

            // Try to enable LiDAR scene depth on body tracking config
            // This works on iOS 16+ with LiDAR devices
            if ARBodyTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics.insert(.sceneDepth)
                isLidarAvailable = true
            } else if hasLidarHardware {
                // Device has LiDAR but ARBodyTrackingConfiguration doesn't support
                // .sceneDepth on this iOS version. We'll still try to read
                // frame.sceneDepth at runtime — some OS versions populate it anyway.
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
        // The depth map aligns with the camera's native orientation (landscape right).
        let depthMapSize = CGSize(width: depthWidth, height: depthHeight)
        let projected = frame.camera.projectPoint(
            worldPosition,
            orientation: .landscapeRight,
            viewportSize: depthMapSize
        )

        let px = Int(projected.x)
        let py = Int(projected.y)

        guard px >= 0, px < depthWidth, py >= 0, py < depthHeight else {
            return .nan
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return .nan }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        let rowPtr = baseAddress.advanced(by: py * bytesPerRow)
        let pixelPtr = rowPtr.advanced(by: px * MemoryLayout<Float32>.size)
        let depth = pixelPtr.assumingMemoryBound(to: Float32.self).pointee

        guard depth > 0, !depth.isNaN, !depth.isInfinite else { return .nan }
        return depth
    }

    // MARK: - Video Writer Setup (Portrait: 1080x1920)

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

    /// Rotate the landscape camera buffer 90° clockwise to portrait, then scale to output size.
    private func rotateAndScaleToPortrait(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: source)

        // Rotate 90° clockwise: .right gives landscape → portrait
        let rotated = ciImage.oriented(.right)

        // Scale to exact output dimensions
        let scaleX = CGFloat(Self.videoWidth) / rotated.extent.width
        let scaleY = CGFloat(Self.videoHeight) / rotated.extent.height
        let scaled = rotated.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var outputBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.videoWidth,
            kCVPixelBufferHeightKey as String: Self.videoHeight
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Self.videoWidth, Self.videoHeight,
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer)

        if let outputBuffer {
            ciContext.render(scaled, to: outputBuffer)
        }
        return outputBuffer
    }

    private func appendPortraitFrame(
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

        if let portraitBuffer = rotateAndScaleToPortrait(pixelBuffer) {
            adaptor.append(portraitBuffer, withPresentationTime: time)
        }
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

    // MARK: - Skeleton Overlay Rendering (Portrait)

    /// Rotate camera image to portrait, project joints to portrait viewport, draw skeleton + text.
    private func renderSkeletonOverlay(
        onto pixelBuffer: CVPixelBuffer,
        bodyAnchor: ARBodyAnchor,
        frame: ARFrame,
        depths: [String: Float],
        lidarDepths: [String: Float]
    ) -> CVPixelBuffer? {
        let width = Self.videoWidth   // 1080
        let height = Self.videoHeight // 1920

        // Rotate landscape camera image to portrait
        guard let portraitBuffer = rotateAndScaleToPortrait(pixelBuffer) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(portraitBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(portraitBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(portraitBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(portraitBuffer)

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

        // CGContext origin is bottom-left; flip to top-left for drawing
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // Portrait viewport matching our video output size
        let viewportSize = CGSize(width: width, height: height)
        let skeleton = bodyAnchor.skeleton
        let definition = skeleton.definition

        // Project all joints to 2D portrait coordinates
        var jointScreenPositions: [Int: CGPoint] = [:]
        let jointNames = definition.jointNames

        for (index, jointName) in jointNames.enumerated() {
            let jointKey = ARSkeleton.JointName(rawValue: jointName)
            guard let modelTransform = skeleton.modelTransform(for: jointKey) else { continue }
            let worldTransform = bodyAnchor.transform * modelTransform
            let worldPos = SIMD3<Float>(worldTransform.columns.3.x,
                                         worldTransform.columns.3.y,
                                         worldTransform.columns.3.z)
            // Project using .portrait orientation so coordinates match our rotated image
            let screenPoint = frame.camera.projectPoint(worldPos,
                                                         orientation: .portrait,
                                                         viewportSize: viewportSize)
            jointScreenPositions[index] = screenPoint
        }

        // Draw bones (green lines)
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

        // Draw joint dots (red)
        ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1.0))
        for (_, pt) in jointScreenPositions {
            ctx.fillEllipse(in: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10))
        }

        // Draw depth text box (top-right corner)
        drawDepthTextBox(ctx: ctx, depths: depths, lidarDepths: lidarDepths, width: width)

        return portraitBuffer
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

        let fontSize: CGFloat = 18
        let boxWidth: CGFloat = hasLidar ? 380 : 260
        let lineHeight: CGFloat = 28
        let padding: CGFloat = 12
        let headerHeight: CGFloat = hasLidar ? lineHeight + 4 : 0
        let boxHeight = padding * 2 + headerHeight + lineHeight * CGFloat(lines.count)
        let boxX = CGFloat(width) - boxWidth - 20
        let boxY: CGFloat = 20

        // Background
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.7))
        let boxRect = CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
        let cornerRadius: CGFloat = 10
        let roundedPath = CGPath(roundedRect: boxRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(roundedPath)
        ctx.fillPath()

        // Border
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.4))
        ctx.setLineWidth(1)
        ctx.addPath(roundedPath)
        ctx.strokePath()

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let smallFont = CTFontCreateWithName("Menlo" as CFString, fontSize - 3, nil)
        let whiteColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let cyanColor = CGColor(red: 0.3, green: 0.9, blue: 1, alpha: 1)
        let dimColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.5)
        var yOffset = boxY + padding

        if hasLidar {
            let header = NSAttributedString(string: "           Skel    LiDAR", attributes: [
                .font: smallFont,
                .foregroundColor: dimColor
            ])
            let headerLine = CTLineCreateWithAttributedString(header)
            ctx.textPosition = CGPoint(x: boxX + padding, y: yOffset + lineHeight - 5)
            CTLineDraw(headerLine, ctx)
            yOffset += lineHeight + 4
        }

        for item in lines {
            let skelStr = formatDepth(item.skeletonDepth)

            let text: NSMutableAttributedString
            if hasLidar {
                let lidarStr = formatDepth(item.lidarDepth)
                text = NSMutableAttributedString(
                    string: "\(item.label): \(skelStr) \(lidarStr)",
                    attributes: [.font: font, .foregroundColor: whiteColor]
                )
                let lidarRange = NSRange(
                    location: "\(item.label): \(skelStr) ".count,
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
            ctx.textPosition = CGPoint(x: boxX + padding, y: yOffset + lineHeight - 5)
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

        // Write clean video frame (portrait)
        if let writer = assetWriter, let input = assetWriterInput, let adaptor = pixelBufferAdaptor {
            appendPortraitFrame(pixelBuffer: frame.capturedImage, timestamp: timestamp,
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
            // No body yet — write plain portrait frame
            appendPortraitFrame(pixelBuffer: frame.capturedImage, timestamp: timestamp,
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

            let worldPos = SIMD3<Float>(
                jointWorldTransform.columns.3.x,
                jointWorldTransform.columns.3.y,
                jointWorldTransform.columns.3.z
            )
            lidarDepths[label] = sampleLidarDepth(for: worldPos, frame: frame)
        }

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
