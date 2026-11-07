# Experimental magnetic survey extension

This local modification adds opt-in magnetic capture to the native iPhone scanner
and a browser viewer at `/magnetic.html`. It is not a browser sensor-access bypass.
The original project remains the room/photo/mesh capture pipeline.

## Capture and view

1. On a Mac, install Xcode and XcodeGen, then run `xcodegen generate` in
   `apps/house-capture`. Open the generated project, set your own unique bundle ID
   and signing team, and run a Release build on your LiDAR iPhone.
2. Before starting a room, enable **Record magnetic measurements**. Remove magnetic
   cases, wallets and charging accessories. Wait for sensor calibration and stable
   visual tracking. The status shows strength, calibration accuracy and sample count.
3. Move slowly through the region of interest at actual tracker heights. Record
   stationary repeat measurements near suspected objects and away from them. Keep
   the same room scan running so all measurements share its coordinate frame.
4. Finish the room before leaving: this saves `magnetic/room-N.json`. Share the room
   ZIP and extract it. A crash during a room can lose that room's magnetic data.
5. On the computer, run `npm ci`, `npm run dev`, then open
   `http://localhost:5188/magnetic.html`. Select the extracted folder containing
   `manifest.json`. No files are uploaded. Select a room, orbit the scan, filter Y,
   and click a point to inspect its values. Mobile browsers can use the folder picker
   where supported; desktop Chrome/Edge is the initial tested target.

## What is recorded

- Approximately 5 samples/second, capped at 9,000 per room (about 30 minutes).
- Calibrated Core Motion magnetic device vector and magnitude in microtesla.
- Calibration accuracy: -1 uncalibrated, 0 low, 1 medium, 2 high.
- ARKit camera position and column-major camera-to-world transform in session meters,
  +Y up, right-handed. Camera location approximates the actual magnetic sensor location.
- Both monotonic timestamps and their absolute difference, at most 100 ms. Latest
  Core Motion readings are paired with AR frames, not interpolated or hardware synchronized.
- Core Motion attitude quaternion (x, y, z, w), reference frame
  xArbitraryCorrectedZVertical. This is **not** an ARKit-world magnetic direction.

Capture pauses when the existing controller cannot establish reliable tracking or
the user pauses recording. Motion updates stop on user pause, room finish, session
finish and abandon. Resume preserves earlier measurements. Room-only exports and
imports keep only that room's magnetic file. Permanent room deletion removes it.
Old bundles without `magneticFiles` still decode normally.

## Interpretation and current limits

The first viewer shows measured points, not an interpolated field volume. Blue to
orange means lower to higher **within that room**, not good to bad. Color scale is
fixed across height filters; hiding uncalibrated samples recomputes the scale.
Uncalibrated samples are hidden by default; low accuracy is still shown and labeled
when selected. Y is relative to the scan origin, not automatically the floor.

Field strength alone cannot identify all Rebocap heading problems. A direction change
can occur without a large magnitude change. World-space vector conversion, direction
deviation against a stable reference, repeated-session comparison, uncertainty-aware
interpolation and live Rebocap ingestion are **not implemented** in this first version.
Device-to-camera axes and timing must be validated physically before adding direction
arrows. Native capture quality and calibration behavior are not yet verified on iPhone.

## Validation

`node --test tests/magnetic-data.test.ts` tests units, timing, positions, magnitudes,
calibration/height filtering and malformed inputs. `npm run build` type-checks and
builds all browser entries. A Mac/Xcode build and physical-iPhone tests remain necessary.
Use the app's existing selftest after generating the Xcode project.

The optional browser test uses synthetic data: install the runner with
`npm install --no-save --package-lock=false @playwright/test`, then run
`node tests/magnetic-browser.mjs`. It launches installed Microsoft Edge headlessly,
serves the viewer on port 5190, and checks local import, a PLY mesh, filters, invalid
ranges, mobile layout, and captures without magnetic data. Screenshots and fixtures
are test data, not measurements from your room.

On-device checks: deny/re-enable motion access; pause/background/resume; finish two
rooms; share one and verify isolation; import it; discard/delete a room; rotate at a
fixed location; repeat a route at constant height; compare against a calibrated
Rebocap tracker. Inspect timing residuals, calibration quality and AR tracking failures.

This prototype does not change project ownership, publish a fork, distribute an iOS
binary or establish App Store readiness. Preserve the upstream MIT license and separate
demo asset terms. See the original app README for existing capture limitations.
