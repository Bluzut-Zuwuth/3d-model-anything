import ARKit
import AVFoundation
import SceneKit
import SwiftUI

/// No ScanBundle, house, room, photos or depth-file writer. All capture state is RAM-only.
@MainActor
final class LiveSurvey: ObservableObject {
  let view = ARSCNView(frame: .zero)
  let guide = LiveGuide.shared
  private let magnetic = MagneticRecorder()
  private var timer: Timer?
  private var runID = UUID()
  @Published private(set) var running = false
  @Published private(set) var starting = false
  @Published private(set) var status = "Ready for a live survey"
  @Published private(set) var magneticStatus = "Magnetic sensor waiting"
  @Published private(set) var position = "Position waiting"
  @Published private(set) var meshCount = 0

  func start() async {
    guard !running, !starting else { return }
    let id = runID
    starting = true
    defer { if runID == id { starting = false } }
    var authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    if !authorized { authorized = await AVCaptureDevice.requestAccess(for: .video) }
    guard runID == id else { return }
    guard authorized else { status = "Enable camera access in iPhone Settings"; return }
    guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
          ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else { status = "This mode needs a LiDAR iPhone or iPad"; return }
    let config = ARWorldTrackingConfiguration()
    config.sceneReconstruction = .mesh
    config.frameSemantics.insert(.sceneDepth)
    config.planeDetection = [.horizontal, .vertical]
    view.automaticallyUpdatesLighting = true
    view.debugOptions = [.showFeaturePoints]
    view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    magnetic.retainsSamples = false
    magnetic.start(room: 0, enabled: true)
    running = true; status = "Establishing tracking…"
    UIApplication.shared.isIdleTimerDisabled = true
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
  }
  private func tick() {
    guard running, let frame = view.session.currentFrame else { return }
    let normal: Bool
    if case .normal = frame.camera.trackingState { normal = true } else { normal = false }
    let fresh = ProcessInfo.processInfo.systemUptime - frame.timestamp < 1
    status = normal && fresh ? "Live · nothing saved on iPhone" : "Tracking not ready · measurements waiting"
    if normal && fresh { magnetic.consider(frame); guide.updateLiDAR(frame, room: 0) }
    magneticStatus = magnetic.status
    let p = frame.camera.transform.columns.3
    position = String(format: "World position: %.2f, %.2f, %.2f m", p.x, p.y, p.z)
    meshCount = frame.anchors.filter { $0 is ARMeshAnchor }.count
    guide.update(phase: "scanning", paused: !normal || !fresh, tracking: String(describing: frame.camera.trackingState),
      room: 0, name: "Live unsaved survey", sample: magnetic.samples.last)
  }
  func stop() {
    runID = UUID()
    timer?.invalidate(); timer = nil
    view.session.pause()
    // A new ARSession releases the previous session's in-memory mesh and map.
    view.session = ARSession()
    magnetic.discard(room: 0)
    guide.disconnect()
    running = false; starting = false; meshCount = 0; position = "Position cleared"
    magneticStatus = "Measurements cleared"; status = "Stopped · phone survey data cleared"
    UIApplication.shared.isIdleTimerDisabled = false
  }
}

private struct LiveSurveyCamera: UIViewRepresentable {
  let view: ARSCNView
  func makeUIView(context: Context) -> ARSCNView { view }
  func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct LiveSurveyScreen: View {
  @StateObject private var survey = LiveSurvey()
  @State private var showingGuide = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    ZStack {
      LiveSurveyCamera(view: survey.view).ignoresSafeArea()
      VStack(spacing: 12) {
        HStack {
          Text("Live survey · not saved").font(.headline)
          Spacer()
          Button("Close") { survey.stop(); dismiss() }
        }.padding().background(.regularMaterial)
        ScanGuideBar(guide: survey.guide) { showingGuide = true }
        Spacer()
        VStack(alignment: .leading, spacing: 8) {
          Text(survey.status).font(.headline)
          Text(survey.magneticStatus).monospacedDigit()
          Text(survey.position).font(.caption.monospaced())
          Text("\(survey.meshCount) LiDAR mesh sections · Y is world position, not floor height").font(.caption)
          Text("No room, scan, photos or depth files are created on this iPhone. A connected PC can keep its readable snapshot.").font(.caption)
          if survey.running {
            Button("Stop & clear", action: survey.stop).buttonStyle(.borderedProminent)
          } else {
            Button(survey.starting ? "Preparing…" : "Start live survey") { Task { await survey.start() } }.buttonStyle(.borderedProminent).disabled(survey.starting)
          }
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
      }
    }
    .sheet(isPresented: $showingGuide) {
      NavigationStack {
        LiveGuidePanel(guide: survey.guide).toolbar { Button("Done") { showingGuide = false } }
      }.presentationDetents([.medium, .large])
    }
    .onDisappear { survey.stop() }
    .task { await survey.start() }
    .onChange(of: scenePhase) { _, phase in if phase != .active { survey.stop() } }
  }
}
