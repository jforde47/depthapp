import SwiftUI
import Charts

struct DepthChartView: View {
    let samples: [JointDepthSample]

    private var hasLidarData: Bool {
        samples.contains { !$0.lidarPelvisDepth.isNaN || !$0.lidarLeftFootDepth.isNaN }
    }

    private var chartData: [ChartDataPoint] {
        // Downsample if recording is long (>1800 frames ≈ 30s at 60fps)
        let stride = samples.count > 1800 ? max(samples.count / 600, 1) : 1
        let showLidar = hasLidarData

        var points: [ChartDataPoint] = []
        for i in Swift.stride(from: 0, to: samples.count, by: stride) {
            let s = samples[i]
            points.append(ChartDataPoint(frame: s.frameNumber, depth: s.pelvisDepth, joint: "Pelvis"))
            points.append(ChartDataPoint(frame: s.frameNumber, depth: s.headDepth, joint: "Head"))
            points.append(ChartDataPoint(frame: s.frameNumber, depth: s.leftFootDepth, joint: "L Foot"))
            points.append(ChartDataPoint(frame: s.frameNumber, depth: s.rightFootDepth, joint: "R Foot"))

            if showLidar {
                if !s.lidarPelvisDepth.isNaN {
                    points.append(ChartDataPoint(frame: s.frameNumber, depth: s.lidarPelvisDepth, joint: "Pelvis (LiDAR)"))
                }
                if !s.lidarHeadDepth.isNaN {
                    points.append(ChartDataPoint(frame: s.frameNumber, depth: s.lidarHeadDepth, joint: "Head (LiDAR)"))
                }
                if !s.lidarLeftFootDepth.isNaN {
                    points.append(ChartDataPoint(frame: s.frameNumber, depth: s.lidarLeftFootDepth, joint: "L Foot (LiDAR)"))
                }
                if !s.lidarRightFootDepth.isNaN {
                    points.append(ChartDataPoint(frame: s.frameNumber, depth: s.lidarRightFootDepth, joint: "R Foot (LiDAR)"))
                }
            }
        }
        return points
    }

    var body: some View {
        Chart(chartData) { point in
            LineMark(
                x: .value("Frame", point.frame),
                y: .value("Depth (m)", point.depth)
            )
            .foregroundStyle(by: .value("Joint", point.joint))
            .lineStyle(StrokeStyle(
                lineWidth: point.joint.contains("LiDAR") ? 2.0 : 1.5,
                dash: point.joint.contains("LiDAR") ? [] : []
            ))
            .opacity(point.joint.contains("LiDAR") ? 0.8 : 1.0)
        }
        .chartYAxisLabel("Depth (meters)")
        .chartXAxisLabel("Frame")
        .chartLegend(position: .top)
        .frame(minHeight: 300)
    }
}
