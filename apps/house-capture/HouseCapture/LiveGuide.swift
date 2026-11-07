import AVFoundation
import ARKit
import Network
import Speech
import SwiftUI

/// Opt-in, foreground-only LAN telemetry. Never sends photos, meshes or raw audio.
@MainActor
final class LiveGuide: ObservableObject {
  static let shared = LiveGuide()
  @Published var host = UserDefaults.standard.string(forKey: "guideHost") ?? "" {
    didSet { UserDefaults.standard.set(host, forKey: "guideHost") }
  }
  @Published var code = GuideSecret.load() { didSet { GuideSecret.save(code) } }
  @Published private(set) var status = "Guide disconnected"
  @Published private(set) var connected = false
  @Published private(set) var connecting = false
  @Published private(set) var reply = ""
  @Published var question = ""
  @Published private(set) var listening = false
  @Published private(set) var preparingSpeech = false
  @Published private(set) var busy = false
  @Published var speakReplies = UserDefaults.standard.object(forKey: "guideSpeak") as? Bool ?? true {
    didSet { UserDefaults.standard.set(speakReplies, forKey: "guideSpeak"); if !speakReplies { stopSpeaking() } }
  }
  @Published var speechLanguage = UserDefaults.standard.string(forKey: "guideLanguage") ?? "en-US" {
    didSet { UserDefaults.standard.set(speechLanguage, forKey: "guideLanguage") }
  }
  @Published var autoSendSpeech = UserDefaults.standard.object(forKey: "guideAutoSend") as? Bool ?? true {
    didSet { UserDefaults.standard.set(autoSendSpeech, forKey: "guideAutoSend") }
  }
  @Published var voiceIdentifier = UserDefaults.standard.string(forKey: "guideVoice") ?? "" {
    didSet { UserDefaults.standard.set(voiceIdentifier, forKey: "guideVoice") }
  }
  @Published var speechRate = UserDefaults.standard.object(forKey: "guideRate") as? Double ?? 0.48 {
    didSet { UserDefaults.standard.set(speechRate, forKey: "guideRate") }
  }
  @Published private(set) var guideAvailable = false
  private var connection: NWConnection?
  private var buffer = Data()
  private var pending = 0
  private var lastStatus = -Double.infinity
  private var lastSample = -Double.infinity
  private var lastDepth = -Double.infinity
  private var lastReceived = Date()
  private var watchdog: Timer?
  private let engine = AVAudioEngine()
  private let speaker = AVSpeechSynthesizer()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognition: SFSpeechRecognitionTask?
  private var micTimer: Timer?
  private var silenceTimer: Timer?
  private var tapInstalled = false
  private var generation = UUID()
  private var speechGeneration = UUID()

  var availableVoices: [AVSpeechSynthesisVoice] {
    let prefix = String(speechLanguage.prefix(2))
    return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice) }
      .sorted { a, b in a.quality.rawValue != b.quality.rawValue ? a.quality.rawValue > b.quality.rawValue : a.name < b.name }
  }
  static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
    switch voice.quality { case .premium: return "Premium"; case .enhanced: return "Enhanced"; default: return "Standard" }
  }
  private var selectedVoice: AVSpeechSynthesisVoice? {
    let voices = availableVoices
    if let chosen = voices.first(where: { $0.identifier == voiceIdentifier }) { return chosen }
    // Prefer quality first, then the selected locale among equal-quality voices.
    return voices.sorted { a, b in
      if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
      if (a.language == speechLanguage) != (b.language == speechLanguage) { return a.language == speechLanguage }
      return a.name < b.name
    }.first ?? AVSpeechSynthesisVoice(language: speechLanguage)
  }
  var selectedVoiceDescription: String {
    guard let voice = selectedVoice else { return "No matching iPhone voice available" }
    return "Using \(voice.name) · \(Self.qualityLabel(voice))"
  }
  func stopSpeaking() { speaker.stopSpeaking(at: .immediate) }
  private func speak(_ text: String) {
    stopSpeaking()
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
      try AVAudioSession.sharedInstance().setActive(true)
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = selectedVoice
      utterance.rate = Float(min(0.60, max(0.35, speechRate)))
      utterance.preUtteranceDelay = 0.1
      speaker.speak(utterance)
    } catch { status = "Audio playback unavailable; reply is shown as text" }
  }
  func previewVoice() {
    stopListening()
    speak(speechLanguage.hasPrefix("de") ? "Ich bin bereit. Bewege das iPhone langsam und halte die Messhöhe gleich." : "I'm ready. Move the iPhone slowly and keep the measurement height steady.")
  }
  func replayReply() { if !reply.isEmpty { stopListening(); speak(reply) } }
  func preparePermissions() async {
    let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
    let mic = await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
    status = speech == .authorized && mic ? "Speech permissions ready" : "Enable microphone and speech in iPhone Settings, or type"
  }

  func connect() {
    disconnect()
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    let parts = octets.compactMap { Int($0) }
    guard octets.count == 4, parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }),
          parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])),
          code.count >= 12 else { status = "Enter a private IPv4 address and the PC pairing code"; return }
    UserDefaults.standard.set(host, forKey: "guideHost")
    let id = generation
    let c = NWConnection(host: NWEndpoint.Host(host), port: 8788, using: .tcp)
    connection = c
    connecting = true
    status = "Connecting to PC…"
    c.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        switch state {
        case .ready:
          self.send(["type": "hello", "version": 1, "token": self.code])
          self.receive(c, id: id)
        case .failed, .cancelled:
          self.disconnect(); self.status = "Connection ended; check PC and Wi-Fi"
        default: break
        }
      }
    }
    c.start(queue: .global(qos: .utility))
    lastReceived = Date()
    watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        if Date().timeIntervalSince(self.lastReceived) > 15 {
          self.disconnect(); self.status = "PC not responding; reconnect when ready"
        }
      }
    }
  }

  func disconnect() {
    generation = UUID()
    stopListening()
    speaker.stopSpeaking(at: .immediate)
    connection?.cancel(); connection = nil
    watchdog?.invalidate(); watchdog = nil
    buffer.removeAll(); pending = 0
    connected = false; connecting = false; busy = false; guideAvailable = false
    question = ""; reply = ""
    lastSample = -.infinity; lastStatus = -.infinity; lastDepth = -.infinity
    status = "Guide disconnected"
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func update(phase: String, paused: Bool, tracking: String, room: Int, name: String, sample: MagneticRecorder.Sample?) {
    guard connected else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastStatus >= 1 {
      lastStatus = now
      send(["type": "status", "phase": phase, "paused": paused, "tracking": tracking, "room": room, "roomName": String(name.prefix(80))])
    }
    if !paused, phase == "scanning", let sample, sample.timestamp != lastSample, now - sample.timestamp < 1,
       let data = try? JSONEncoder().encode(sample), let object = try? JSONSerialization.jsonObject(with: data) {
      lastSample = sample.timestamp
      send(["type": "sample", "sample": object])
    }
  }

  /// A bounded, one-Hz depth summary, never an RGB image or full depth buffer.
  func updateLiDAR(_ frame: ARFrame, room: Int) {
    guard connected, frame.timestamp - lastDepth >= 1, case .normal = frame.camera.trackingState,
          let depth = frame.sceneDepth else { return }
    lastDepth = frame.timestamp
    let map = depth.depthMap
    CVPixelBufferLockBaseAddress(map, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(map) else { return }
    let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
    let strideBytes = CVPixelBufferGetBytesPerRow(map)
    var readings: [Float] = []
    for y in stride(from: 0, to: height, by: 8) {
      let row = base.advanced(by: y * strideBytes).assumingMemoryBound(to: Float.self)
      for x in stride(from: 0, to: width, by: 8) {
        let d = row[x]
        if d.isFinite, d > 0, d <= 10 { readings.append(d) }
      }
    }
    let pose = frame.camera.transform.columns.3
    var summary: [String: Any] = ["type": "lidar", "timestamp": frame.timestamp, "room": room,
      "width": width, "height": height, "sampleStride": 8, "validSampledPoints": readings.count,
      "meshAnchors": frame.anchors.filter { $0 is ARMeshAnchor }.count,
      "position": [pose.x, pose.y, pose.z]]
    if let near = readings.min(), let far = readings.max() { summary["nearestMeters"] = near; summary["farthestMeters"] = far }
    send(summary)
  }

  func ask() {
    let text = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
    guard connected, guideAvailable, !busy, !text.isEmpty else { return }
    stopListening()
    speaker.stopSpeaking(at: .immediate)
    busy = true; status = "Guide is thinking…"
    send(["type": "question", "text": text])
    question = ""
  }

  private func send(_ object: [String: Any]) {
    guard let c = connection, pending < 8, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(10); pending += 1
    let id = generation
    c.send(content: data, completion: .contentProcessed { [weak self] error in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        self.pending = max(0, self.pending - 1)
        if error != nil { self.disconnect() }
      }
    })
  }

  private func receive(_ c: NWConnection, id: UUID) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        if let data { self.buffer.append(data) }
        guard self.buffer.count <= 32768 else { self.disconnect(); return }
        while let end = self.buffer.firstIndex(of: 10) {
          let line = self.buffer.prefix(upTo: end)
          self.buffer.removeSubrange(...end)
          guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { continue }
          self.lastReceived = Date()
          if type == "ready" {
            self.connected = true; self.connecting = false
            self.guideAvailable = obj["guideEnabled"] as? Bool ?? true
            self.status = self.guideAvailable ? "Guide ready · live data connected" : "Telemetry connected · PC guide is off"
          }
          if type == "reply", let text = obj["text"] as? String {
            self.busy = false; self.reply = String(text.prefix(4000)); self.status = "Guide ready"
            if self.speakReplies && !self.listening {
              self.speak(self.reply)
            }
          }
          if type == "error" { self.busy = false; self.status = String((obj["text"] as? String ?? "Guide error").prefix(500)) }
        }
        if done || error != nil { self.disconnect() } else { self.receive(c, id: id) }
      }
    }
  }

  func startListening() async {
    guard connected, guideAvailable, !busy, !listening, !preparingSpeech else { return }
    stopListening()
    preparingSpeech = true
    let id = generation
    let speechID = speechGeneration
    defer { if speechGeneration == speechID { preparingSpeech = false } }
    let permission = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    let mic = await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
    }
    guard generation == id, speechGeneration == speechID, connected else { return }
    guard permission == .authorized, mic else { status = "Enable microphone and speech access in Settings, or type"; return }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: speechLanguage)), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
      status = "On-device speech unavailable for this language; type your question"; return
    }
    speaker.stopSpeaking(at: .immediate)
    do {
      try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
      try AVAudioSession.sharedInstance().setActive(true)
      let r = SFSpeechAudioBufferRecognitionRequest()
      r.requiresOnDeviceRecognition = true; r.shouldReportPartialResults = true
      request = r
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else { status = "Microphone unavailable; type instead"; return }
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in r.append(buffer) }
      tapInstalled = true
      recognition = recognizer.recognitionTask(with: r) { [weak self] result, error in
        Task { @MainActor in
          guard let self, self.generation == id, self.speechGeneration == speechID, self.listening else { return }
          if let result {
            let text = String(result.bestTranscription.formattedString.prefix(2000))
            if text != self.question {
              self.question = text
              self.silenceTimer?.invalidate()
              if self.autoSendSpeech, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
                  Task { @MainActor in self?.finishSpeaking() }
                }
              }
            }
          }
          if result?.isFinal == true { self.finishSpeaking() }
          else if error != nil { self.stopListening(); self.status = "Speech interrupted; review or type your question" }
        }
      }
      listening = true; question = ""
      engine.prepare(); try engine.start()
      status = autoSendSpeech ? "Listening · sends after a short pause · Cancel to discard" : "Listening · tap Done, review, then Send"
      micTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
        Task { @MainActor in self?.stopListening() }
      }
    } catch { stopListening(); status = "Could not start microphone; type instead" }
  }

  func stopListening() {
    speechGeneration = UUID()
    listening = false
    preparingSpeech = false
    micTimer?.invalidate(); micTimer = nil
    silenceTimer?.invalidate(); silenceTimer = nil
    engine.stop()
    if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    request?.endAudio(); recognition?.cancel()
    request = nil; recognition = nil
  }
  func finishSpeaking() {
    let sendAutomatically = autoSendSpeech && listening
    stopListening()
    if sendAutomatically { ask() }
    else { status = "Review your question, then Send" }
  }
  func cancelSpeech() { stopListening(); question = ""; status = "Question cancelled" }
}

struct LiveGuidePanel: View {
  @ObservedObject var guide: LiveGuide
  var body: some View {
    Form {
      Section("Guided scan") {
        NavigationLink("Connection & voice settings") { GuideSettingsScreen(guide: guide) }
        Button(guide.connected || guide.connecting ? "Stop guided session" : "Connect to ready PC") {
          if guide.connected || guide.connecting { guide.disconnect() } else { guide.connect() }
        }
        Text(guide.status).font(.footnote)
      }
      if guide.connected {
        Section("Speak or type") {
          Button(guide.listening ? "Done speaking" : "Tap to speak") {
            if guide.listening { guide.finishSpeaking() } else { Task { await guide.startListening() } }
          }.disabled(guide.busy || guide.preparingSpeech || !guide.guideAvailable)
          if guide.listening { Button("Cancel question", role: .cancel, action: guide.cancelSpeech) }
          TextField("Review or type your question", text: $guide.question, axis: .vertical).lineLimit(2...5)
          Button("Send question", action: guide.ask).disabled(guide.busy || !guide.guideAvailable || guide.listening || guide.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if !guide.reply.isEmpty { Text(guide.reply).textSelection(.enabled) }
          if !guide.reply.isEmpty { Button("Read reply again", action: guide.replayReply) }
          Button("Stop playback", action: guide.stopSpeaking)
        }
      }
      Section("What is shared") {
        Text("Live magnetic readings, camera positions, LiDAR summaries and scan status go to your PC. Questions and measurement summaries go through Codex to OpenAI using your PC login and account limits. No photos, full mesh or raw microphone audio are sent. Speech stays on-device. The unencrypted LAN connection stops when this app becomes inactive.").font(.footnote)
      }
    }
    .navigationTitle("Live scan guide")
    .onDisappear { guide.stopListening() }
  }
}

struct ScanGuideBar: View {
  @ObservedObject var guide: LiveGuide
  let showDetails: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button(guide.connected || guide.connecting ? "Stop guide" : "Connect guide") {
          if guide.connected || guide.connecting { guide.disconnect() }
          else if guide.host.isEmpty || guide.code.isEmpty { showDetails() }
          else { guide.connect() }
        }.buttonStyle(.bordered)
        Button {
          if guide.listening { guide.finishSpeaking() } else { Task { await guide.startListening() } }
        } label: {
          Label(guide.listening ? "Done" : "Talk to guide", systemImage: guide.listening ? "stop.circle.fill" : "mic.fill")
        }.buttonStyle(.borderedProminent)
          .disabled(!guide.connected || !guide.guideAvailable || guide.busy || guide.preparingSpeech)
        Button(action: showDetails) { Image(systemName: "text.bubble") }.accessibilityLabel("Guide text and settings")
      }
      Text(guide.status).font(.caption).lineLimit(2)
      if guide.listening || guide.preparingSpeech {
        HStack {
          Text(guide.question.isEmpty ? "Microphone preparing…" : guide.question).font(.caption).lineLimit(3)
          Spacer()
          Button("Cancel", action: guide.cancelSpeech)
        }
      } else if !guide.reply.isEmpty {
        Text(guide.reply).font(.caption).lineLimit(3)
        Button("Stop voice", action: guide.stopSpeaking).font(.caption)
      }
    }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
  }
}
