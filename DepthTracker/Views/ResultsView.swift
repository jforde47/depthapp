import SwiftUI

struct ResultsView: View {
    @Bindable var viewModel: RecordingViewModel
    @State private var isPreparingZIP = false

    private var hasLidarData: Bool {
        viewModel.samples.contains { !$0.lidarPelvisDepth.isNaN }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Chart
                Text("Joint Depth Over Time")
                    .font(.headline)

                DepthChartView(samples: viewModel.samples)
                    .padding(.horizontal)

                // Stats
                if !viewModel.samples.isEmpty {
                    statsSection
                }

                // Export ZIP
                if let zipURL = viewModel.zipURL {
                    ShareLink(item: zipURL) {
                        Label("Export ZIP (CSV + Video + Chart + Summary)", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                } else {
                    Button {
                        prepareZIPExport()
                    } label: {
                        if isPreparingZIP {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Prepare ZIP Export", systemImage: "archivebox")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparingZIP)
                    .padding(.horizontal)
                }

                // Individual CSV export
                if let url = viewModel.csvURL {
                    ShareLink(item: url) {
                        Label("Export CSV Only", systemImage: "tablecells")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                }

                if let error = viewModel.exportError {
                    Text("Export error: \(error)")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                // New recording button
                Button("New Recording") {
                    viewModel.reset()
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.headline)

            Text("Total frames: \(viewModel.samples.count)")
                .font(.subheadline)
            Text(String(format: "Duration: %.1fs", viewModel.elapsedTime))
                .font(.subheadline)

            if hasLidarData {
                HStack(spacing: 4) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption2)
                    Text("LiDAR depth data included")
                        .font(.caption)
                }
                .foregroundStyle(.cyan)
            }

            Divider()

            // Skeleton depth stats
            Text("Skeleton Depth")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            let pelvisDepths = viewModel.samples.map(\.pelvisDepth).filter { !$0.isNaN }
            let headDepths = viewModel.samples.map(\.headDepth).filter { !$0.isNaN }
            let leftFootDepths = viewModel.samples.map(\.leftFootDepth).filter { !$0.isNaN }
            let rightFootDepths = viewModel.samples.map(\.rightFootDepth).filter { !$0.isNaN }

            statsRow("Pelvis", depths: pelvisDepths)
            statsRow("Head", depths: headDepths)
            statsRow("L Foot", depths: leftFootDepths)
            statsRow("R Foot", depths: rightFootDepths)

            // LiDAR depth stats
            if hasLidarData {
                Divider()

                Text("LiDAR Depth")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.cyan)

                let lidarPelvis = viewModel.samples.map(\.lidarPelvisDepth).filter { !$0.isNaN }
                let lidarHead = viewModel.samples.map(\.lidarHeadDepth).filter { !$0.isNaN }
                let lidarLFoot = viewModel.samples.map(\.lidarLeftFootDepth).filter { !$0.isNaN }
                let lidarRFoot = viewModel.samples.map(\.lidarRightFootDepth).filter { !$0.isNaN }

                statsRow("Pelvis", depths: lidarPelvis)
                statsRow("Head", depths: lidarHead)
                statsRow("L Foot", depths: lidarLFoot)
                statsRow("R Foot", depths: lidarRFoot)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    @ViewBuilder
    private func statsRow(_ label: String, depths: [Float]) -> some View {
        if let minVal = depths.min(), let maxVal = depths.max() {
            let avg = depths.reduce(0, +) / Float(depths.count)
            HStack {
                Text(label)
                    .fontWeight(.medium)
                    .frame(width: 60, alignment: .leading)
                Text(String(format: "Min: %.2fm", minVal))
                    .font(.caption)
                Text(String(format: "Max: %.2fm", maxVal))
                    .font(.caption)
                Text(String(format: "Avg: %.2fm", avg))
                    .font(.caption)
            }
        }
    }

    private func prepareZIPExport() {
        isPreparingZIP = true

        let chartView = DepthChartView(samples: viewModel.samples)
            .frame(width: 800, height: 400)
            .padding()
            .background(.white)

        let renderer = ImageRenderer(content: chartView)
        renderer.scale = 2.0
        let chartImageData = renderer.uiImage?.pngData()

        viewModel.generateZIP(chartImageData: chartImageData)
        isPreparingZIP = false
    }
}
