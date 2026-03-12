import SwiftUI
import RealityKit
import ARKit

struct CameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session = session
        arView.renderOptions = [.disablePersonOcclusion, .disableDepthOfField, .disableMotionBlur]
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
