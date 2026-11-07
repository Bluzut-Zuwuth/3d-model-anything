import AVFoundation
import Network
import Speech
import SwiftUI

/// Opt-in, foreground-only LAN telemetry. Never sends photos, meshes or raw audio.
@MainActor
final class LiveGuide: ObservableObject {
  @Published var host = UserDefaults.standard.string(forKey: "guideHost") ?? ""
  @Published var code = ""
  @Published private(set) var status = "Guide disconnected"
  @Published private(set) var connected = false
  @Published private(set) var connecting = false
  @Published private(set) var reply = ""
  @Published var question = ""
  @Published private(set) var listening = false
  @Published private(set) var busy = false
  @Published var speakReplies = true
  private var connection: NWConnection?
  private var buffer = Data()
  private var pending = 0
  private var lastStatus = -Double.infinity
  private var lastSample = -Double.infinity
  private var lastReceived = Date()
  private var watchdog: Timer?
  private let engine = AVAudioEngine()
  private let speaker = AVSpeechSynthesizer()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognition: SFSpeechRecognitionTask?
  private var micTimer: Timer?
  private var tapInstalled = false
  private var generation = UUID()
  private var speechGeneration = UUID()

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
    connected = false; connecting = false; busy = false
    lastSample = -.infinity; lastStatus = -.infinity
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

  func ask() {
    let text = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
    guard connected, !busy, !text.isEmpty else { return }
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
          if type == "ready" { self.connected = true; self.connecting = false; self.status = "PC ready · live measurements connected" }
          if type == "reply", let text = obj["text"] as? String {
            self.busy = false; self.reply = String(text.prefix(4000)); self.status = "Guide ready"
            if self.speakReplies && !self.listening {
              try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
              try? AVAudioSession.sharedInstance().setActive(true)
              self.speaker.speak(AVSpeechUtterance(string: self.reply))
            }
          }
          if type == "error" { self.busy = false; self.status = String((obj["text"] as? String ?? "Guide error").prefix(500)) }
        }
        if done || error != nil { self.disconnect() } else { self.receive(c, id: id) }
      }
    }
  }

  func startListening() async {
    guard connected, !busy, !listening else { return }
    let id = generation
    let permission = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    let mic = await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
    }
    guard generation == id, connected else { return }
    guard permission == .authorized, mic else { status = "Enable microphone and speech access in Settings, or type"; return }
    guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
      status = "On-device speech unavailable for this language; type your question"; return
    }
    speaker.stopSpeaking(at: .immediate)
    stopListening()
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
      let speechID = speechGeneration
      recognition = recognizer.recognitionTask(with: r) { [weak self] result, error in
        Task { @MainActor in
          guard let self, self.generation == id, self.speechGeneration == speechID, self.listening else { return }
          if let result { self.question = String(result.bestTranscription.formattedString.prefix(2000)) }
          if error != nil || result?.isFinal == true { self.stopListening() }
        }
      }
      listening = true; question = ""
      engine.prepare(); try engine.start()
      status = "Listening locally · tap Done, review, then Send"
      micTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
        Task { @MainActor in self?.stopListening() }
      }
    } catch { stopListening(); status = "Could not start microphone; type instead" }
  }

  func stopListening() {
    speechGeneration = UUID()
    listening = false
    micTimer?.invalidate(); micTimer = nil
    engine.stop()
    if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    request?.endAudio(); recognition?.cancel()
    request = nil; recognition = nil
  }
}

struct LiveGuidePanel: View {
  @ObservedObject var guide: LiveGuide
  var body: some View {
    Form {
      Section("Optional guided scan") {
        Text("Run the PC receiver first. Both devices must use trusted Wi-Fi. This opens a separate guide session; it does not attach this app to an existing chat.").font(.footnote)
        TextField("PC private IPv4, e.g. 192.168.1.10", text: $guide.host).keyboardType(.decimalPad).disabled(guide.connected)
        SecureField("PC pairing code", text: $guide.code).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(guide.connected)
        Button(guide.connected || guide.connecting ? "Stop guided session" : "Connect to ready PC") {
          if guide.connected || guide.connecting { guide.disconnect() } else { guide.connect() }
        }
        Text(guide.status).font(.footnote)
      }
      if guide.connected {
        Section("Speak or type") {
          Toggle("Read replies aloud", isOn: $guide.speakReplies)
          Button(guide.listening ? "Done speaking" : "Tap to speak") {
            if guide.listening { guide.stopListening() } else { Task { await guide.startListening() } }
          }.disabled(guide.busy)
          TextField("Review or type your question", text: $guide.question, axis: .vertical).lineLimit(2...5)
          Button("Send question", action: guide.ask).disabled(guide.busy || guide.listening || guide.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if !guide.reply.isEmpty { Text(guide.reply).textSelection(.enabled) }
        }
      }
      Section("What is shared") {
        Text("Live field strength, sensor quality, camera positions, room name and scan status go to your PC. Questions and a compact measurement summary go through Codex to OpenAI using your PC login and account limits. Photos, meshes and raw microphone audio are not sent. Speech stays on-device; type if unavailable. LAN transport is unencrypted: use only a private trusted network. Stops when this app becomes inactive.").font(.footnote)
      }
    }
    .navigationTitle("Live scan guide")
    .onDisappear { guide.stopListening() }
  }
}
