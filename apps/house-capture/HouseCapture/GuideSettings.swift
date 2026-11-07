import AVFoundation
import Security
import SwiftUI

enum GuideSecret {
  private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "room-magnetic-guide", kSecAttrAccount as String: "pairing-code"] }
  static func load() -> String {
    var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }
  static func save(_ value: String) {
    if value.isEmpty { SecItemDelete(query as CFDictionary); return }
    let data = Data(value.utf8)
    if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
      var q = query; q[kSecValueData as String] = data
      q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      SecItemAdd(q as CFDictionary, nil)
    }
  }
}

struct GuideSettingsSections: View {
  @ObservedObject var guide: LiveGuide
  @State private var voices: [AVSpeechSynthesisVoice] = []
  var body: some View {
    Section("PC connection") {
      TextField("PC private IPv4", text: $guide.host).keyboardType(.decimalPad)
        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(guide.connected || guide.connecting)
      SecureField("Pairing code", text: $guide.code).textInputAutocapitalization(.never).autocorrectionDisabled()
        .disabled(guide.connected || guide.connecting)
      Text("Saved for your next scan. Pairing code stays in this iPhone’s Keychain. Run the PC guide on your trusted home network before connecting.").font(.caption)
      Button(guide.connected || guide.connecting ? "Disconnect guide" : "Test connection") {
        if guide.connected || guide.connecting { guide.disconnect() } else { guide.connect() }
      }
      Text(guide.status).font(.caption)
    }
    Section("Speaking") {
      Picker("Language", selection: $guide.speechLanguage) {
        Text("English").tag("en-US"); Text("Deutsch").tag("de-DE")
      }.disabled(guide.listening || guide.preparingSpeech)
      Toggle("Read replies aloud", isOn: $guide.speakReplies)
      Toggle("Send after I stop speaking", isOn: $guide.autoSendSpeech)
      Text("With automatic sending on, one tap listens for a question and sends it after a short pause. The microphone stays off while the guide replies. Tap Cancel to discard.").font(.caption)
      Button("Prepare microphone & speech permissions") { Task { await guide.preparePermissions() } }
    }
    Section("iPhone voice") {
      Picker("Voice", selection: $guide.voiceIdentifier) {
        Text("Automatic · best available quality").tag("")
        ForEach(voices, id: \.identifier) { voice in
          Text("\(voice.name) · \(LiveGuide.qualityLabel(voice)) · \(voice.language)").tag(voice.identifier)
        }
      }
      Text(guide.selectedVoiceDescription).font(.caption)
      HStack { Text("Speed"); Slider(value: $guide.speechRate, in: 0.35...0.60, step: 0.01) }
      HStack {
        Button("Preview voice") { guide.previewVoice() }
        Button("Stop playback") { guide.stopSpeaking() }
      }
      Button("Refresh installed voices") { refreshVoices() }
      Text("For a more natural voice, download an Enhanced or Premium voice in iPhone Accessibility speech settings, then return and refresh. Only voices Apple exposes to apps are listed; your Siri voice may not be available.").font(.caption)
    }
    .onAppear { refreshVoices() }
    .onChange(of: guide.speechLanguage) { _, _ in guide.voiceIdentifier = ""; refreshVoices() }
  }
  private func refreshVoices() {
    voices = guide.availableVoices
    if !guide.voiceIdentifier.isEmpty, !voices.contains(where: { $0.identifier == guide.voiceIdentifier }) { guide.voiceIdentifier = "" }
  }
}

struct GuideSettingsScreen: View {
  @ObservedObject var guide: LiveGuide = .shared
  @AppStorage("surveyDefault") private var surveyDefault = false
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    Form {
      Section("Scanning") {
        Toggle("Default to LiDAR + magnetic survey", isOn: $surveyDefault)
        Text("Survey mode saves depth, geometry and magnetic samples without reference photos or depth RGB images. The camera still runs for AR tracking. Full room scanning remains available.").font(.caption)
      }
      GuideSettingsSections(guide: guide)
      Section("Privacy") {
        Text("Nothing connects or listens automatically. Use Connect and Talk on the scan screen. Text and measurement summaries reach OpenAI through your PC’s Codex account when you ask the guide. Local network transport is unencrypted; use a trusted private network.").font(.caption)
      }
    }
    .navigationTitle("Settings")
    .onDisappear { guide.stopListening(); guide.stopSpeaking() }
    .onChange(of: scenePhase) { _, phase in if phase != .active { guide.disconnect() } }
  }
}
