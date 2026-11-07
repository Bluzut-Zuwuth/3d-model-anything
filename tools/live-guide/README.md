# Live magnetic survey and iPhone guide (experimental)

Use **Live survey · don’t save** on the home screen to begin immediately without making a house or room. The LiDAR AR session and newest magnetic sample stay in RAM; stopping/closing/backgrounding clears them. No ScanBundle, photos, depth files, room files or tracking-map export is created. Camera access is still required for AR tracking. The PC, if connected, separately keeps a readable snapshot.

For exports, use normal room scanning with **LiDAR + magnetic only · save survey**: saves depth/confidence frames, pose, geometry and magnetic samples, omitting new reference photos and depth RGB images. Full room scanning remains available. Existing imported/prior photos are not deleted by this mode. Exported RoomRecord has optional `captureMode: lidar-magnetic` or `full`; earlier scans omit it.

## Set up once

1. PC: install Node.js 22+ and [Codex CLI](https://learn.chatgpt.com/docs/non-interactive-mode). Run `codex login`, then `codex login status`. Account usage limits apply. No separate voice API key is used. The PC must stay awake and have internet for replies.
2. From this repository run `powershell -ExecutionPolicy Bypass -File tools/live-guide/start-guide.ps1`, or `node tools/live-guide/server.mjs --guide`. Leave the terminal open. Allow Node on **Private networks** if Windows Firewall asks; do not allow Public networks or forward the port through your router.
3. In iPhone app **Settings** (gear icon), enter the PC's private IPv4 address and printed pairing code. Choose your home Wi-Fi/Ethernet adapter address, not a VPN/virtual adapter. The phone stores the code in Keychain and preferences in UserDefaults. The PC stores its code in ignored `data/live/pairing-code.txt`, so it survives receiver restarts. To rotate it: restart with `--reset-pairing` and update the phone. Never commit/share this code file.
4. In Settings, prepare microphone/speech permissions and choose English or Deutsch. **Send after I stop speaking** defaults on: one tap listens, then sends recognized text after 1.8 seconds without a transcription change. Turn it off to review before Send. The microphone never starts automatically and stops while the guide replies. Cancel discards a pending spoken question.
5. Pick an installed iPhone voice, preview it and adjust speed. Automatic selection prefers Premium, then Enhanced, then Standard voices for the language. Download an Enhanced/Premium voice in iPhone Accessibility speech settings if desired, return to the app and **Refresh installed voices**. Only voices exposed by Apple's speech API are offered; not every Siri voice is available. If a selected voice is removed, selection falls back to an available voice. Voice audio is synthesized on the phone.

## Use

Open **Live survey · don’t save**, or start a saved room scan. Press **Connect guide**, then **Talk to guide** directly on the scan screen. The guide receives magnetic measurements plus one-Hz LiDAR range summaries and pose/status. It answers when you ask, not as a continuous voice call; latency depends on Codex. The text bubble opens typed questions, full replies, replay and a Settings link.

On-device speech is required; if unavailable for the language, type instead. Each microphone turn is capped at 45 seconds and never re-arms itself. A first-use permission prompt may interrupt a foreground-only session; prepare permissions in Settings, then start/reconnect. Connect/talk are explicit actions; Settings does not auto-connect. Stop, finishing/discarding/leaving a scan, backgrounding/locking the phone, lost heartbeats or closing the receiver ends the connection. Reconnecting starts a fresh guide conversation and coordinate scope. Ctrl+C stops the PC receiver.

Both devices must be on the same trusted LAN without client isolation. iPhone connects to TCP 8788 at a private IPv4 address. The PC dashboard is `http://127.0.0.1:8787`, bound only to loopback; it requires no pairing code because only the PC can read it directly. Use the private network firewall rule rather than disabling your firewall.

## Data and interpretation

The paired LAN transport is **unencrypted**: home/trusted networks only. One authenticated phone is accepted. No camera photos, full mesh, full depth buffer, raw microphone audio or account passwords are transmitted. iPhone sends magnetic samples (~5 Hz) and bounded one-Hz depth summaries (resolution, stride, valid sampled ranges, mesh-anchor count and position). Depth values are subsampled and not confidence-filtered; they are not a complete 3D room model or object recognition.

The PC keeps at most 3000 magnetic readings in RAM and writes `data/live/latest.json` once per second: freshness, status, recent samples, LiDAR summary, question and reply. An active coding assistant can read this when asked; an idle/closed chat does not automatically monitor it. Questions, recent conversation, optional prior context and measurement summaries go to OpenAI through Codex using the PC login and its usage limits. This is a **separate assistant conversation**, not an embedded connection to an existing chat. No model settings, hardware changes or arbitrary PC commands are exposed through this protocol.

Optional private prior findings belong in `data/live/context.txt` (max 12000 characters, loaded at receiver startup). All `data/live/` files are gitignored. Nothing from earlier chats is automatically imported. Codex runs ephemerally with read-only sandbox, user config omitted, shell tool disabled and a prompt forbidding tools. Don't broaden its permissions for this receiver. Telemetry-only mode (omit `--guide`) makes no Codex calls and disables speech questions in the phone UI. Delete the runtime folder after stopping to remove local receiver data and its pairing code; phone exports are separate.

ARKit world Y is **not height above floor**. Distinct AR sessions/rooms are not automatically registered. Device-axis magnetic vectors are not world-axis headings. High calibration quality is not proof of a uniform field. Magnitude alone cannot prove a source, certify an area or predict a Rebocap heading error. Repeat matched positions/heights/orientations and move one suspected object at a time.

## Verification

`node --test tools/live-guide/*.test.mjs` checks magnetic/depth validation, freshness, pairing, fragmented Unicode questions, a readable live snapshot and malformed-data disconnect. Native compilation uses the unsigned iOS workflow. On-device voice availability/quality, silence detection, Keychain persistence, AR+audio behavior and stop/background transitions still require a physical device test. Compile success does not establish these.
