import SwiftUI

struct RecordingControlsView: View {
    @Bindable var viewModel: RecordingViewModel

    var body: some View {
        VStack {
            // Top bar: camera toggle + timer picker
            if viewModel.state == .idle {
                HStack {
                    // Camera flip button
                    Button {
                        viewModel.toggleCamera()
                    } label: {
                        Image(systemName: "camera.rotate")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Spacer()

                    // Timer picker
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .foregroundStyle(.white)
                        Picker("Timer", selection: $viewModel.timerDuration) {
                            ForEach(1...10, id: \.self) { sec in
                                Text("\(sec)s").tag(sec)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                if viewModel.useFrontCamera {
                    Text("Front camera — body tracking unavailable")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 4)
                } else if viewModel.lidarAvailable {
                    HStack(spacing: 4) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.caption2)
                        Text("LiDAR Active")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 4)
                }
            }

            Spacer()

            // Countdown overlay
            if viewModel.state == .countdown {
                Text("\(viewModel.countdownRemaining)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
                    .contentTransition(.numericText())
                    .animation(.default, value: viewModel.countdownRemaining)

                Spacer()
            }

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

            // Record / Stop / Cancel button
            if viewModel.state == .countdown {
                Button {
                    viewModel.cancelCountdown()
                } label: {
                    Text("Cancel")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.red.opacity(0.8), in: Capsule())
                }
                .padding(.bottom, 40)
            } else {
                Button {
                    if viewModel.state == .idle {
                        viewModel.beginCountdown()
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
}
