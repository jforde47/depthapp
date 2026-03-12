import Foundation
import Observation

enum RecordingState {
    case idle
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

    let bodyTrackingManager = BodyTrackingManager()

    init() {
        bodyTrackingManager.onSample = { [weak self] sample in
            guard let self else { return }
            self.samples.append(sample)
            self.frameCount = sample.frameNumber + 1
            self.elapsedTime = sample.timestamp
        }
    }

    func startSession() {
        bodyTrackingManager.startSession()
    }

    func startRecording() {
        samples = []
        frameCount = 0
        elapsedTime = 0
        csvURL = nil
        exportError = nil
        state = .recording
        bodyTrackingManager.startRecording()
    }

    func stopRecording() {
        bodyTrackingManager.stopRecording()
        state = .completed
        generateCSV()
    }

    func reset() {
        samples = []
        frameCount = 0
        elapsedTime = 0
        csvURL = nil
        exportError = nil
        state = .idle
    }

    private func generateCSV() {
        do {
            csvURL = try CSVExporter.export(samples: samples)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
