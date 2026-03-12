import SwiftUI

struct ResultsView: View {
    @Bindable var viewModel: RecordingViewModel

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

                // Export
                if let url = viewModel.csvURL {
                    ShareLink(item: url) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
        let pelvisDepths = viewModel.samples.map(\.pelvisDepth).filter { !$0.isNaN }
        let headDepths = viewModel.samples.map(\.headDepth).filter { !$0.isNaN }
        let leftFootDepths = viewModel.samples.map(\.leftFootDepth).filter { !$0.isNaN }
        let rightFootDepths = viewModel.samples.map(\.rightFootDepth).filter { !$0.isNaN }

        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.headline)

            Text("Total frames: \(viewModel.samples.count)")
                .font(.subheadline)
            Text(String(format: "Duration: %.1fs", viewModel.elapsedTime))
                .font(.subheadline)

            Divider()

            statsRow("Pelvis", depths: pelvisDepths)
            statsRow("Head", depths: headDepths)
            statsRow("L Foot", depths: leftFootDepths)
            statsRow("R Foot", depths: rightFootDepths)
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
}
