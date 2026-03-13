import Foundation

struct CSVExporter {

    static func export(samples: [JointDepthSample]) throws -> URL {
        // Collect all unique joint names across all frames, sorted for consistent column order
        var allJointNames: Set<String> = []
        for s in samples {
            allJointNames.formUnion(s.allJointPositions.keys)
        }
        let sortedJointNames = allJointNames.sorted()

        // Build header
        var headerColumns = [
            "frame_number",
            "timestamp",
            "pelvis_depth",
            "head_depth",
            "left_foot_depth",
            "right_foot_depth",
            "pelvis_delta",
            "head_delta",
            "left_foot_delta",
            "right_foot_delta",
            "lidar_pelvis_depth",
            "lidar_head_depth",
            "lidar_left_foot_depth",
            "lidar_right_foot_depth"
        ]

        // Add 3 columns (x, y, z) per joint
        for jointName in sortedJointNames {
            headerColumns.append("\(jointName)_x")
            headerColumns.append("\(jointName)_y")
            headerColumns.append("\(jointName)_z")
        }

        var csv = headerColumns.joined(separator: ",") + "\n"

        for s in samples {
            var columns = [
                "\(s.frameNumber)",
                String(format: "%.4f", s.timestamp),
                String(format: "%.4f", s.pelvisDepth),
                String(format: "%.4f", s.headDepth),
                String(format: "%.4f", s.leftFootDepth),
                String(format: "%.4f", s.rightFootDepth),
                String(format: "%.4f", s.pelvisDelta),
                String(format: "%.4f", s.headDelta),
                String(format: "%.4f", s.leftFootDelta),
                String(format: "%.4f", s.rightFootDelta),
                s.lidarPelvisDepth.isNaN ? "" : String(format: "%.4f", s.lidarPelvisDepth),
                s.lidarHeadDepth.isNaN ? "" : String(format: "%.4f", s.lidarHeadDepth),
                s.lidarLeftFootDepth.isNaN ? "" : String(format: "%.4f", s.lidarLeftFootDepth),
                s.lidarRightFootDepth.isNaN ? "" : String(format: "%.4f", s.lidarRightFootDepth)
            ]

            for jointName in sortedJointNames {
                if let pos = s.allJointPositions[jointName] {
                    columns.append(String(format: "%.6f", pos.x))
                    columns.append(String(format: "%.6f", pos.y))
                    columns.append(String(format: "%.6f", pos.z))
                } else {
                    columns.append("")
                    columns.append("")
                    columns.append("")
                }
            }

            csv += columns.joined(separator: ",") + "\n"
        }

        let filename = "depth_recording_\(Int(Date().timeIntervalSince1970)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
