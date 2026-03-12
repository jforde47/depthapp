import SwiftUI

struct RecordingControlsView: View {
    @Bindable var viewModel: RecordingViewModel

    var body: some View {
        VStack {
            Spacer()

            if viewModel.state == .recording {
                // Live stats overlay
                VStack(spacing: 4) {
                    Text("REC")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.red)
                    Text("Frames: \(viewModel.frameCount)")
                        .font(.caption)
                        .monospacedDigit()
                    Text(String(format: "%.1fs", viewModel.elapsedTime))
                        .font(.caption)
                        .monospacedDigit()
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 8)
            }

            // Record button
            Button {
                if viewModel.state == .idle {
                    viewModel.startRecording()
                } else if viewModel.state == .recording {
                    viewModel.stopRecording()
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 72, height: 72)

                    if viewModel.state == .recording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.red)
                            .frame(width: 28, height: 28)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 60, height: 60)
                    }
                }
            }
            .padding(.bottom, 40)
        }
    }
}
