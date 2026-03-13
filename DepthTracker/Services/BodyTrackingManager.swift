import ARKit
import AVFoundation
import CoreGraphics
import Vision
import UIKit

class BodyTrackingManager: NSObject, ARSessionDelegate {

    let session = ARSession()

    /// Called on each frame when recording is active
    var onSample: ((JointDepthSample) -> Void)?

    /// Whether device has LiDAR hardware
    private(set) var hasLidarHardware = false
    /// Whether LiDAR scene depth is active for the current session
    private(set) var isLidarAvailable = false

    private var isRecording = false
    private var currentlyUsingFrontCamera = false

    // Vision 3D body pose
    private let bodyPose3DRequest = VNDetectHumanBodyPose3DRequest()
    private var lastPoseObservation: VNHumanBodyPose3DObservation?
    private var lastPoseTimestamp: TimeInterval = 0

    // Recording state
    private var frameCount = 0
    private var recordingStartTime: TimeInterval = 0
    private var previousDepths: [String: Float] = [:]

    // Video dimensions (computed from first frame to match camera aspect)
    private var videoWidth = 0
    private var videoHeight = 0

    // Clean video recording
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

    private var pendingVideoURL: URL?
    private var videoCompletion: (() -> Void)?

    private let ciContext = CIContext()

    // Processing queue for AR delegate + Vision
    private let processingQueue = DispatchQueue(label: "com.depthtracker.processing", qos: .userInteractive)

    // Joints tracked for depth CSV
    private static let trackedJoints: [(visionName: VNHumanBodyPose3DObservation.JointName, label: String)] = [
        (.root, "pelvis"),
        (.centerHead, "head"),
        (.leftAnkle, "leftFoot"),
        (.rightAnkle, "rightFoot"),
    ]

    // All joints for skeleton overlay
    private static let allSkeletonJoints: [VNHumanBodyPose3DObservation.JointName] = [
        .root, .spine, .centerShoulder, .centerHead, .topHead,
        .leftShoulder, .rightShoulder,
        .leftElbow, .rightElbow,
        .leftWrist, .rightWrist,
        .leftHip, .rightHip,
        .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle,
    ]

    // Human-readable joint name strings for CSV columns
    private static let jointNameStrings: [VNHumanBodyPose3DObservation.JointName: String] = [
        .root: "root",
        .spine: "spine",
        .centerShoulder: "center_shoulder",
        .centerHead: "center_head",
        .topHead: "top_head",
        .leftShoulder: "left_shoulder",
        .rightShoulder: "right_shoulder",
        .leftElbow: "left_elbow",
        .rightElbow: "right_elbow",
        .leftWrist: "left_wrist",
        .rightWrist: "right_wrist",
        .leftHip: "left_hip",
        .rightHip: "right_hip",
        .leftKnee: "left_knee",
        .rightKnee: "right_knee",
        .leftAnkle: "left_ankle",
        .rightAnkle: "right_ankle",
    ]

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = processingQueue
        hasLidarHardware = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    // MARK: - Session Management

    func startSession(useFrontCamera: Bool = false) {
        currentlyUsingFrontCamera = useFrontCamera

        if useFrontCamera {
            guard ARFaceTrackingConfiguration.isSupported else {
                print("ARFaceTrackingConfiguration is not supported on this device.")
                return
            }
            isLidarAvailable = false
            let config = ARFaceTrackingConfiguration()
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        } else {
            // Use ARWorldTrackingConfiguration — supports .sceneDepth for LiDAR
            guard ARWorldTrackingConfiguration.isSupported else {
                print("ARWorldTrackingConfiguration is not supported on this device.")
                return
            }
            let config = ARWorldTrackingConfiguration()

            if hasLidarHardware {
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
        lastPoseObservation = nil
        videoWidth = 0
        videoHeight = 0

        pendingVideoURL = videoOutputURL

        let skeletonFilename = videoOutputURL.deletingPathExtension().lastPathComponent + "_skeleton.mp4"
        skeletonVideoURL = FileManager.default.temporaryDirectory.appendingPathComponent(skeletonFilename)

        isRecording = true
    }

    func stopRecording(completion: @escaping () -> Void) {
        isRecording = false
        videoCompletion = completion
        finishAllVideoWriting()
    }

    // MARK: - Vision Body Pose Detection

    private func detectBody3D(frame: ARFrame) -> VNHumanBodyPose3DObservation? {
        // Provide camera intrinsics for better 3D estimation
        let intrinsicsData = withUnsafeBytes(of: frame.camera.intrinsics) { Data($0) }
        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.capturedImage,
            orientation: .right,
            options: [.cameraIntrinsics: intrinsicsData as NSData]
        )

        do {
            try handler.perform([bodyPose3DRequest])
        } catch {
            return nil
        }

        return bodyPose3DRequest.results?.first
    }

    // MARK: - LiDAR Depth Map Sampling

    private func sampleLidarDepth(for worldPosition: SIMD3<Float>, frame: ARFrame) -> Float {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return .nan
        }

        let depthMap = depthData.depthMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        let depthMapSize = CGSize(width: depthWidth, height: depthHeight)
        let projected = frame.camera.projectPoint(
            worldPosition,
            orientation: .landscapeRight,
            viewportSize: depthMapSize
        )

        let px = Int(projected.x)
        let py = Int(projected.y)

        guard px >= 0, px < depthWidth, py >= 0, py < depthHeight else { return .nan }

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

    // MARK: - Video Writer Setup

    private func setupWritersFromFirstFrame(_ frame: ARFrame) {
        let camW = CVPixelBufferGetWidth(frame.capturedImage)
        let camH = CVPixelBufferGetHeight(frame.capturedImage)

        // Portrait: swap landscape dimensions
        let portraitW = camH
        let portraitH = camW

        // Scale to 1080 width, maintain native camera aspect ratio
        let targetWidth = 1080
        let scale = Double(targetWidth) / Double(portraitW)
        let targetHeight = Int(round(Double(portraitH) * scale))

        // Ensure even dimensions for H.264
        videoWidth = targetWidth
        videoHeight = targetHeight & ~1

        if let url = pendingVideoURL {
            setupVideoWriter(outputURL: url)
        }
        if let url = skeletonVideoURL {
            setupSkeletonWriter(outputURL: url)
        }
        pendingVideoURL = nil
    }

    private func makeWriterAndInput(outputURL: URL) -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)? {
        try? FileManager.default.removeItem(at: outputURL)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return nil }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight
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

    // MARK: - Image Processing

    /// Rotate landscape camera buffer 90° CW to portrait, scale to video dimensions (uniform).
    private func rotateAndScaleToPortrait(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: source)
        let rotated = ciImage.oriented(.right)

        let scaleX = CGFloat(videoWidth) / rotated.extent.width
        let scaleY = CGFloat(videoHeight) / rotated.extent.height
        let scaled = rotated.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var outputBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, videoWidth, videoHeight,
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

    // MARK: - Skeleton Overlay Rendering

    private func renderSkeletonOverlay(
        onto pixelBuffer: CVPixelBuffer,
        observation: VNHumanBodyPose3DObservation,
        frame: ARFrame,
        depths: [String: Float],
        lidarDepths: [String: Float]
    ) -> CVPixelBuffer? {
        let width = videoWidth
        let height = videoHeight

        guard let portraitBuffer = rotateAndScaleToPortrait(pixelBuffer) else { return nil }

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

        // Flip for top-left origin (matches UIKit and projectPoint(.portrait) coords)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let viewportSize = CGSize(width: width, height: height)

        // Project all joints to 2D portrait coordinates
        var jointScreenPositions: [VNHumanBodyPose3DObservation.JointName: CGPoint] = [:]

        for jointName in Self.allSkeletonJoints {
            guard let joint = try? observation.recognizedPoint(jointName) else { continue }
            let cameraPos = observation.cameraOriginMatrix * joint.position
            let worldPos4 = frame.camera.transform * cameraPos
            let worldPos = SIMD3<Float>(worldPos4.columns.3.x, worldPos4.columns.3.y, worldPos4.columns.3.z)
            let screenPoint = frame.camera.projectPoint(worldPos, orientation: .portrait, viewportSize: viewportSize)
            jointScreenPositions[jointName] = screenPoint
        }

        // Draw bones (green lines)
        ctx.setStrokeColor(CGColor(red: 0, green: 1, blue: 0.4, alpha: 0.9))
        ctx.setLineWidth(3.0)

        for jointName in Self.allSkeletonJoints {
            guard let childPt = jointScreenPositions[jointName],
                  let parentName = try? observation.parentJointName(for: jointName),
                  let parentPt = jointScreenPositions[parentName] else { continue }
            ctx.move(to: childPt)
            ctx.addLine(to: parentPt)
        }
        ctx.strokePath()

        // Draw joint dots (red)
        ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1.0))
        for (_, pt) in jointScreenPositions {
            ctx.fillEllipse(in: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10))
        }

        // Draw depth text box using UIKit for correct text rendering in flipped context
        UIGraphicsPushContext(ctx)
        drawDepthTextBox(depths: depths, lidarDepths: lidarDepths, width: width)
        UIGraphicsPopContext()

        return portraitBuffer
    }

    // MARK: - Depth Text Box (UIKit drawing)

    private func drawDepthTextBox(depths: [String: Float], lidarDepths: [String: Float], width: Int) {
        let hasLidar = !lidarDepths.isEmpty && lidarDepths.values.contains { !$0.isNaN }

        struct DepthLine {
            let label: String
            let skeletonDepth: Float?
            let lidarDepth: Float?
        }

        let lines: [DepthLine] = [
            DepthLine(label: "Pelvis", skeletonDepth: depths["pelvis"], lidarDepth: lidarDepths["pelvis"]),
            DepthLine(label: "L Foot", skeletonDepth: depths["leftFoot"], lidarDepth: lidarDepths["leftFoot"]),
            DepthLine(label: "R Foot", skeletonDepth: depths["rightFoot"], lidarDepth: lidarDepths["rightFoot"]),
        ]

        let font = UIFont(name: "Menlo-Bold", size: 16) ?? UIFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        let smallFont = UIFont(name: "Menlo", size: 13) ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        let boxWidth: CGFloat = hasLidar ? 340 : 220
        let lineHeight: CGFloat = 24
        let padding: CGFloat = 10
        let headerHeight: CGFloat = hasLidar ? lineHeight + 4 : 0
        let boxHeight = padding * 2 + headerHeight + lineHeight * CGFloat(lines.count)
        let boxX = CGFloat(width) - boxWidth - 16
        let boxY: CGFloat = 16

        // Background
        let boxRect = CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
        let bgPath = UIBezierPath(roundedRect: boxRect, cornerRadius: 8)
        UIColor(white: 0, alpha: 0.7).setFill()
        bgPath.fill()
        UIColor(white: 1, alpha: 0.4).setStroke()
        bgPath.lineWidth = 1
        bgPath.stroke()

        var yOffset = boxY + padding

        // Header row
        if hasLidar {
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: smallFont,
                .foregroundColor: UIColor(white: 1, alpha: 0.5)
            ]
            ("         Skel    LiDAR" as NSString).draw(
                at: CGPoint(x: boxX + padding, y: yOffset),
                withAttributes: headerAttrs
            )
            yOffset += lineHeight + 4
        }

        // Data rows
        for item in lines {
            let skelStr = formatDepth(item.skeletonDepth)

            if hasLidar {
                let lidarStr = formatDepth(item.lidarDepth)
                let fullText = "\(item.label): \(skelStr) \(lidarStr)"
                let attrText = NSMutableAttributedString(string: fullText, attributes: [
                    .font: font,
                    .foregroundColor: UIColor.white
                ])
                let lidarRange = NSRange(location: "\(item.label): \(skelStr) ".count, length: lidarStr.count)
                if lidarRange.location + lidarRange.length <= fullText.count {
                    attrText.addAttribute(.foregroundColor, value: UIColor.cyan, range: lidarRange)
                }
                attrText.draw(at: CGPoint(x: boxX + padding, y: yOffset))
            } else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.white
                ]
                ("\(item.label): \(skelStr)" as NSString).draw(
                    at: CGPoint(x: boxX + padding, y: yOffset),
                    withAttributes: attrs
                )
            }

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

        // Setup video writers on first frame (to match camera resolution)
        if videoWidth == 0 {
            setupWritersFromFirstFrame(frame)
        }

        let timestamp = frame.timestamp

        // Detect body pose via Vision (rear camera only)
        var bodyObs: VNHumanBodyPose3DObservation?
        if !currentlyUsingFrontCamera {
            bodyObs = detectBody3D(frame: frame)
            if bodyObs != nil {
                lastPoseObservation = bodyObs
                lastPoseTimestamp = timestamp
            }
        }

        // Use recent observation if current frame detection failed
        let effectiveObs: VNHumanBodyPose3DObservation?
        if bodyObs != nil {
            effectiveObs = bodyObs
        } else if let last = lastPoseObservation, timestamp - lastPoseTimestamp < 0.3 {
            effectiveObs = last
        } else {
            effectiveObs = nil
        }

        // Write clean video frame (portrait)
        if let writer = assetWriter, let input = assetWriterInput, let adaptor = pixelBufferAdaptor {
            appendPortraitFrame(pixelBuffer: frame.capturedImage, timestamp: timestamp,
                               writer: writer, input: input, adaptor: adaptor, startTime: &videoStartTime)
        }

        // Write skeleton overlay frame
        if let obs = effectiveObs,
           let sWriter = skeletonWriter, let sInput = skeletonWriterInput, let sAdaptor = skeletonPixelBufferAdaptor,
           sWriter.status == .writing {

            var depths: [String: Float] = [:]
            var lidarDepths: [String: Float] = [:]

            for (jointName, label) in Self.trackedJoints {
                guard let joint = try? obs.recognizedPoint(jointName) else {
                    depths[label] = .nan
                    lidarDepths[label] = .nan
                    continue
                }
                let cameraPos = obs.cameraOriginMatrix * joint.position
                depths[label] = -cameraPos.columns.3.z

                let worldPos4 = frame.camera.transform * cameraPos
                let worldPos = SIMD3<Float>(worldPos4.columns.3.x, worldPos4.columns.3.y, worldPos4.columns.3.z)
                lidarDepths[label] = sampleLidarDepth(for: worldPos, frame: frame)
            }

            if let overlayBuffer = renderSkeletonOverlay(
                onto: frame.capturedImage,
                observation: obs,
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
            // No body detected — write plain portrait frame
            appendPortraitFrame(pixelBuffer: frame.capturedImage, timestamp: timestamp,
                               writer: sWriter, input: sInput, adaptor: sAdaptor, startTime: &skeletonVideoStartTime)
        }

        // Emit CSV sample when body is freshly detected this frame
        if let bodyObs {
            processBodyForCSV(bodyObs, frame: frame)
        }
    }

    // MARK: - CSV Data Processing

    private func processBodyForCSV(_ observation: VNHumanBodyPose3DObservation, frame: ARFrame) {
        var depths: [String: Float] = [:]
        var lidarDepths: [String: Float] = [:]

        for (jointName, label) in Self.trackedJoints {
            guard let joint = try? observation.recognizedPoint(jointName) else {
                depths[label] = previousDepths[label] ?? .nan
                lidarDepths[label] = .nan
                continue
            }

            let cameraPos = observation.cameraOriginMatrix * joint.position
            let depth = -cameraPos.columns.3.z
            depths[label] = depth

            let worldPos4 = frame.camera.transform * cameraPos
            let worldPos = SIMD3<Float>(worldPos4.columns.3.x, worldPos4.columns.3.y, worldPos4.columns.3.z)
            lidarDepths[label] = sampleLidarDepth(for: worldPos, frame: frame)
        }

        let pelvisDelta = previousDepths["pelvis"] != nil ? (depths["pelvis"] ?? 0) - (previousDepths["pelvis"] ?? 0) : 0
        let headDelta = previousDepths["head"] != nil ? (depths["head"] ?? 0) - (previousDepths["head"] ?? 0) : 0
        let leftFootDelta = previousDepths["leftFoot"] != nil ? (depths["leftFoot"] ?? 0) - (previousDepths["leftFoot"] ?? 0) : 0
        let rightFootDelta = previousDepths["rightFoot"] != nil ? (depths["rightFoot"] ?? 0) - (previousDepths["rightFoot"] ?? 0) : 0

        // All joint world-space positions
        var allJointPositions: [String: SIMD3<Float>] = [:]
        for jointName in Self.allSkeletonJoints {
            guard let joint = try? observation.recognizedPoint(jointName) else { continue }
            let cameraPos = observation.cameraOriginMatrix * joint.position
            let worldPos4 = frame.camera.transform * cameraPos
            let key = Self.jointNameStrings[jointName] ?? jointName.rawValue
            allJointPositions[key] = SIMD3<Float>(
                worldPos4.columns.3.x, worldPos4.columns.3.y, worldPos4.columns.3.z
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
