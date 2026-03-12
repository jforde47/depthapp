import Foundation

struct CSVExporter {

    static func export(samples: [JointDepthSample]) throws -> URL {
        var csv = "frame_number,timestamp,pelvis_depth,head_depth,left_foot_depth,right_foot_depth,pelvis_delta,head_delta,left_foot_delta,right_foot_delta\n"

        for s in samples {
            let line = [
                "\(s.frameNumber)",
                String(format: "%.4f", s.timestamp),
                String(format: "%.4f", s.pelvisDepth),
                String(format: "%.4f", s.headDepth),
                String(format: "%.4f", s.leftFootDepth),
                String(format: "%.4f", s.rightFootDepth),
                String(format: "%.4f", s.pelvisDelta),
                String(format: "%.4f", s.headDelta),
                String(format: "%.4f", s.leftFootDelta),
                String(format: "%.4f", s.rightFootDelta)
            ].joined(separator: ",")
            csv += line + "\n"
        }

        let filename = "depth_recording_\(Int(Date().timeIntervalSince1970)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
