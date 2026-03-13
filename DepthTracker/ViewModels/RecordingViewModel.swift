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
    private var audioPlayer: AVAudioPlayer?

    init() {
        bodyTrackingManager.onSample = { [weak self] sample in
            guard let self else { return }
            self.samples.append(sample)
            self.frameCount = sample.frameNumber + 1
            self.elapsedTime = sample.timestamp
        }

        // Configure audio session for playback (ignores silent switch)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try audioSession.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
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
        // Play a system sound via AVAudioPlayer (respects .playback category, ignores silent switch)
        // Try common system sound paths
        let soundPaths = [
            "/System/Library/Audio/UISounds/begin_record.caf",
            "/System/Library/Audio/UISounds/BeginRecording.caf",
            "/System/Library/Audio/UISounds/New/Fanfare.caf",
            "/System/Library/Audio/UISounds/short_low_high.caf"
        ]

        for path in soundPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                do {
                    audioPlayer = try AVAudioPlayer(contentsOf: url)
                    audioPlayer?.volume = 1.0
                    audioPlayer?.play()
                    return
                } catch {
                    continue
                }
            }
        }

        // Fallback: generate a short beep tone programmatically
        if let toneData = generateBeepToneData() {
            do {
                audioPlayer = try AVAudioPlayer(data: toneData)
                audioPlayer?.volume = 1.0
                audioPlayer?.play()
            } catch {
                // Last resort: system sound (won't play on silent mode)
                AudioServicesPlayAlertSound(1113)
            }
        }
    }

    /// Generate a short 440Hz beep as WAV data
    private func generateBeepToneData() -> Data? {
        let sampleRate: Double = 44100
        let duration: Double = 0.3
        let frequency: Double = 880 // Hz (A5 — audible, attention-getting)
        let numSamples = Int(sampleRate * duration)

        var samples = [Int16](repeating: 0, count: numSamples)
        for i in 0..<numSamples {
            let t = Double(i) / sampleRate
            // Apply fade-in/out envelope to avoid clicks
            let envelope: Double
            let fadeLen = 0.02
            if t < fadeLen {
                envelope = t / fadeLen
            } else if t > duration - fadeLen {
                envelope = (duration - t) / fadeLen
            } else {
                envelope = 1.0
            }
            samples[i] = Int16(sin(2.0 * .pi * frequency * t) * Double(Int16.max) * 0.7 * envelope)
        }

        // Build WAV header
        let dataSize = numSamples * 2
        let fileSize = 44 + dataSize
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // chunk size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(44100).littleEndian) { Array($0) }) // sample rate
        data.append(contentsOf: withUnsafeBytes(of: UInt32(88200).littleEndian) { Array($0) }) // byte rate
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })  // block align
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits per sample
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

        samples.withUnsafeBufferPointer { ptr in
            data.append(UnsafeBufferPointer(start: UnsafeRawPointer(ptr.baseAddress!).assumingMemoryBound(to: UInt8.self),
                                           count: dataSize))
        }

        return data
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
