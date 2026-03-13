import Foundation

struct ZIPExporter {

    /// Creates a ZIP file containing the CSV, videos, chart image, and a summary text file.
    static func export(
        csvURL: URL?,
        videoURL: URL?,
        skeletonVideoURL: URL?,
        chartImageData: Data?,
        samples: [JointDepthSample],
        duration: TimeInterval
    ) throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let folderName = "depth_export_\(timestamp)"
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent(folderName)

        // Clean up and create directory
        try? FileManager.default.removeItem(at: baseDir)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // Copy CSV
        if let csvURL, FileManager.default.fileExists(atPath: csvURL.path) {
            let dest = baseDir.appendingPathComponent("depth_data.csv")
            try FileManager.default.copyItem(at: csvURL, to: dest)
        }

        // Copy clean video
        if let videoURL, FileManager.default.fileExists(atPath: videoURL.path) {
            let dest = baseDir.appendingPathComponent("recording.mp4")
            try FileManager.default.copyItem(at: videoURL, to: dest)
        }

        // Copy skeleton overlay video
        if let skeletonVideoURL, FileManager.default.fileExists(atPath: skeletonVideoURL.path) {
            let dest = baseDir.appendingPathComponent("recording_skeleton.mp4")
            try FileManager.default.copyItem(at: skeletonVideoURL, to: dest)
        }

        // Save chart image
        if let chartImageData {
            let dest = baseDir.appendingPathComponent("depth_chart.png")
            try chartImageData.write(to: dest)
        }

        // Generate summary text
        let summary = generateSummary(samples: samples, duration: duration)
        let summaryURL = baseDir.appendingPathComponent("summary.txt")
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)

        // Create ZIP using NSFileCoordinator
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("depth_export_\(timestamp).zip")
        try? FileManager.default.removeItem(at: zipURL)

        var coordinatorError: NSError?
        var zipError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: baseDir,
            options: .forUploading,
            error: &coordinatorError
        ) { tempZipURL in
            do {
                try FileManager.default.moveItem(at: tempZipURL, to: zipURL)
            } catch {
                zipError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let zipError { throw zipError }

        // Clean up staging directory
        try? FileManager.default.removeItem(at: baseDir)

        return zipURL
    }

    private static func generateSummary(samples: [JointDepthSample], duration: TimeInterval) -> String {
        var lines: [String] = []
        lines.append("Depth Recording Summary")
        lines.append("=======================")
        lines.append("")
        lines.append("Total Frames: \(samples.count)")
        lines.append(String(format: "Duration: %.1f seconds", duration))
        lines.append("")

        // Skeleton-based depth stats
        lines.append("--- Skeleton Depth (ARKit Body Tracking) ---")
        lines.append("")

        let skeletonJoints: [(String, (JointDepthSample) -> Float)] = [
            ("Pelvis",     \.pelvisDepth),
            ("Head",       \.headDepth),
            ("Left Foot",  \.leftFootDepth),
            ("Right Foot", \.rightFootDepth)
        ]

        for (name, accessor) in skeletonJoints {
            appendJointStats(name: name, depths: samples.map(accessor), to: &lines)
        }

        // LiDAR depth stats (if available)
        let hasLidar = samples.contains { !$0.lidarPelvisDepth.isNaN }
        if hasLidar {
            lines.append("--- LiDAR Depth (Scene Depth Map) ---")
            lines.append("")

            let lidarJoints: [(String, (JointDepthSample) -> Float)] = [
                ("Pelvis",     \.lidarPelvisDepth),
                ("Head",       \.lidarHeadDepth),
                ("Left Foot",  \.lidarLeftFootDepth),
                ("Right Foot", \.lidarRightFootDepth)
            ]

            for (name, accessor) in lidarJoints {
                appendJointStats(name: name, depths: samples.map(accessor), to: &lines)
            }
        }

        // Joint count info
        if let first = samples.first {
            lines.append("Total joints tracked per frame: \(first.allJointPositions.count)")
            lines.append("Joint names: \(first.allJointPositions.keys.sorted().joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    private static func appendJointStats(name: String, depths: [Float], to lines: inout [String]) {
        let valid = depths.filter { !$0.isNaN }
        guard let minVal = valid.min(), let maxVal = valid.max() else { return }
        let avg = valid.reduce(0, +) / Float(valid.count)
        lines.append("\(name):")
        lines.append(String(format: "  Min: %.4f m", minVal))
        lines.append(String(format: "  Max: %.4f m", maxVal))
        lines.append(String(format: "  Avg: %.4f m", avg))
        lines.append(String(format: "  Range: %.4f m", maxVal - minVal))
        lines.append("")
    }
}
