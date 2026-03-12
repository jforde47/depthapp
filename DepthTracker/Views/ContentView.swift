import SwiftUI

struct ContentView: View {
    @State private var viewModel = RecordingViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                if viewModel.state == .completed {
                    ResultsView(viewModel: viewModel)
                } else {
                    // Camera + recording controls
                    CameraView(session: viewModel.bodyTrackingManager.session)
                        .ignoresSafeArea()

                    RecordingControlsView(viewModel: viewModel)
                }
            }
            .onAppear {
                viewModel.startSession()
            }
        }
    }
}
