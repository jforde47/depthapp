import SwiftUI
import Charts

struct DepthChartView: View {
    let samples: [JointDepthSample]

    private var chartData: [ChartDataPoint] {
        // Downsample if recording is long (>1800 frames ≈ 30s at 60fps)
        let stride = samples.count > 1800 ? max(samples.count / 600, 1) : 1

        var points: [ChartDataPoint] = []
        for i in Swift.stride(from: 0, to: samples.count, by: stride) {
            let s = samples[i]
            points.append(ChartDataPoint(frame: s.frameNumber, depth: s.pelvisDepth, joint: "Pelvis"))
            points.append(ChartDataPoint(frame: s.frameNumber, depth: s.headDepth, joint: "Head"))
            points.append(ChartDataPoint(frame: s.frameNumber, depth: s.leftFootDepth, joint: "L Foot"))
            points.append(ChartDataPoint(frame: s.frameNumber, depth: s.rightFootDepth, joint: "R Foot"))
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
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartYAxisLabel("Depth (meters)")
        .chartXAxisLabel("Frame")
        .chartLegend(position: .top)
        .frame(minHeight: 300)
    }
}
