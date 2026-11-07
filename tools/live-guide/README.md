# Foreground LAN scan guide (experimental)

The iPhone scanner can stream magnetic samples and pose/status to a Windows PC. Tap to speak inside the scanner, review the local transcription, then Send. A separate Codex guide returns text and the iPhone reads it aloud. This does **not** embed or attach to an existing ChatGPT/Codex conversation and is not a full-duplex voice call. Reply latency depends on Codex.

## PC setup

1. Install Node.js 22+ and [Codex CLI](https://learn.chatgpt.com/docs/non-interactive-mode). Run `codex login` using your account, then `codex login status`. Account usage limits apply; this mode does not require a separate voice API key. The PC needs internet for Codex, must stay awake, and must have the CLI available on PATH.
2. From this repository run `powershell -ExecutionPolicy Bypass -File tools/live-guide/start-guide.ps1` (or `node tools/live-guide/server.mjs --guide`). The script only starts the local receiver. Leave its terminal open. If Windows asks about Node network access, allow **Private networks** on your trusted home network. Do not expose port 8788 to the internet or allow Public networks.
3. Read the PC's private IPv4 address and random pairing code from the terminal. VPN/virtual adapter addresses may also be listed; choose your Wi-Fi/Ethernet home-network address. Dashboard: `http://127.0.0.1:8787`. No pairing code is needed for the PC-only dashboard; it binds only to loopback.
4. Start a scan on iPhone; enable magnetic recording. Open **Live scan guide**, enter the address and pairing code, then **Connect to ready PC**. Permit Local Network access. Your iPhone and PC must be on the same trusted LAN without client isolation. The phone uses TCP port 8788.
5. Start scanning. Open the guide sheet to **Tap to speak**, **Done speaking**, review/edit and **Send question**. Permit microphone and speech access. Recognition is required to stay on-device and may be unavailable for your selected language; type instead. There is a 45-second microphone limit per tap. The microphone stops when you close the guide panel. Replies can be spoken while you continue scanning.
6. **Stop guided session**, leaving the scanner/app, locking the phone, finishing/discarding the scan, closing the receiver or a lost heartbeat stops the link. No automatic reconnection/listening. A foreground permission dialog can also stop the link: grant permission, then reconnect. Ctrl+C stops the PC receiver. Reconnecting starts a fresh conversation and measurement buffer.

## Data and privacy

The LAN link is paired, private-IPv4-only on iPhone, bounded, single-phone and **unencrypted**. It is for a trusted home network, not a public Wi-Fi deployment. No camera photos, mesh, raw audio or Apple/OpenAI passwords are transmitted. A phone that knows the code can submit text and measurements to the guide, so keep the code private; it changes on receiver restart.

The PC keeps up to 3000 readings in RAM. `data/live/latest.json` is updated once per second with the last-minute summary, last readings, status, question and reply. This lets a human or an active coding assistant read current data; it does not cause a closed/idle chat to monitor anything. The dashboard and snapshot explicitly show freshness. Context/conversation and measurement summaries go to OpenAI through the installed Codex CLI when you Send; normal account data policies and usage limits apply. Replies are local iOS speech synthesis. Audio is not uploaded by this integration.

Optional `data/live/context.txt` (up to 12000 characters) can contain prior scan findings; loaded at receiver startup. All `data/live/` files are gitignored. Nothing from previous chats is automatically imported. Questions and replies also appear in the local snapshot. Codex is run ephemerally with read-only sandbox, approvals disabled, user config omitted and shell tool disabled; prompts explicitly forbid tool use. No app commands, settings changes or arbitrary PC command endpoints exist in this protocol. Do not enable external tools or broaden the sandbox for this receiver.

For telemetry only, omit `--guide`: no Codex call is made, and questions return a clear error. Delete `data/live/` to remove the receiver snapshot/context after use; exported iPhone scans are separate. The snapshot can remain after closing, with timestamps; always check freshness/connection.

## Interpretation

Enable magnetic recording and scan with normal AR tracking to get fresh field samples (about 5 Hz). Positions use the current ARKit world; **Y is not measured floor height**. Each connection is a new coordinate/conversation scope. Distinct scans are not automatically aligned. Room indices distinguish rooms, and no floor-height labeling or world-vector conversion is inferred. Calibration quality is a sensor flag, not proof of an undistorted field. Field strength alone cannot establish interference with a Rebocap tracker or identify a source. Repeat matched routes/orientations and test moving one suspected object at a time.

## Verification

`node --test tools/live-guide/*.test.mjs` covers sample validation, freshness, pairing, connection limits, fragmented Unicode questions, telemetry snapshots and malformed-data disconnect. Native compilation is checked by the unsigned iOS workflow. Physical microphone permission, on-device speech availability, speaker playback, background transitions, firewall and AR+audio behavior require a real-device test; successful compilation is not that test.
