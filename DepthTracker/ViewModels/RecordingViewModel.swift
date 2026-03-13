import Foundation
import AVFoundation
import Observation

enum RecordingState {
    case idle
    case countdown
    case recording
    case completed
}

@Observable
class RecordingViewModel {

    var state: RecordingState = .idle
    var samples: [JointDepthSample] = []
    var frameCount: Int = 0
    var elapsedTime: TimeInterval = 0
    var csvURL: URL?
    var exportError: String?

    // Timer
    var timerDuration: Int = 3  // seconds, range 1-10
    var countdownRemaining: Int = 0

    // Camera
    var useFrontCamera: Bool = false
    var lidarAvailable: Bool { bodyTrackingManager.isLidarAvailable }

    // Video
    var videoURL: URL?
    var skeletonVideoURL: URL?

    // ZIP export
    var zipURL: URL?

    let bodyTrackingManager = BodyTrackingManager()
    private var countdownTimer: Timer?

    init() {
        bodyTrackingManager.onSample = { [weak self] sample in
            guard let self else { return }
            self.samples.append(sample)
            self.frameCount = sample.frameNumber + 1
            self.elapsedTime = sample.timestamp
        }
    }

    func startSession() {
        bodyTrackingManager.startSession(useFrontCamera: useFrontCamera)
    }

    func toggleCamera() {
        useFrontCamera.toggle()
        bodyTrackingManager.startSession(useFrontCamera: useFrontCamera)
    }

    func beginCountdown() {
        samples = []
        frameCount = 0
        elapsedTime = 0
        csvURL = nil
        videoURL = nil
        skeletonVideoURL = nil
        zipURL = nil
        exportError = nil
        countdownRemaining = timerDuration
        state = .countdown

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.countdownRemaining -= 1
            if self.countdownRemaining <= 0 {
                timer.invalidate()
                self.countdownTimer = nil
                self.playStartBeep()
                self.startRecording()
            }
        }
    }

    func startRecording() {
        state = .recording

        // Start video recording
        let filename = "depth_video_\(Int(Date().timeIntervalSince1970)).mp4"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        videoURL = url
        bodyTrackingManager.startRecording(videoOutputURL: url)
    }

    func stopRecording() {
        bodyTrackingManager.stopRecording { [weak self] in
            guard let self else { return }
            self.skeletonVideoURL = self.bodyTrackingManager.skeletonVideoURL
            self.state = .completed
            self.generateExports()
        }
    }

    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
        state = .idle
    }

    func reset() {
        samples = []
        frameCount = 0
        elapsedTime = 0
        csvURL = nil
        videoURL = nil
        skeletonVideoURL = nil
        zipURL = nil
        exportError = nil
        state = .idle
    }

    private func playStartBeep() {
        AudioServicesPlaySystemSound(1113) // "begin_record" tone
    }

    private func generateExports() {
        do {
            csvURL = try CSVExporter.export(samples: samples)
        } catch {
            exportError = error.localizedDescription
        }
    }

    func generateZIP(chartImageData: Data?) {
        do {
            zipURL = try ZIPExporter.export(
                csvURL: csvURL,
                videoURL: videoURL,
                skeletonVideoURL: skeletonVideoURL,
                chartImageData: chartImageData,
                samples: samples,
                duration: elapsedTime
            )
        } catch {
            exportError = error.localizedDescription
        }
    }
}
