import ARKit
import CoreMotion
import Foundation
import UIKit

/// Experimental measurements, not a tracker-interference classifier. Camera position
/// approximates sensor position; no unverified camera/device axis conversion is applied.
@MainActor
final class MagneticRecorder {
  struct Sample: Codable {
    var room: Int
    var timestamp: TimeInterval
    var motionTimestamp: TimeInterval
    var poseDeltaSeconds: Double
    var position: [Float]
    var cameraTransform: [Float]
    var fieldDeviceMicrotesla: [Double]
    var magnitudeMicrotesla: Double
    var calibrationAccuracy: Int
    var deviceAttitudeQuaternion: [Double]
  }

  struct Recording: Codable {
    var format = "magnetic-capture/1"
    var units = "microtesla"
    var coordinateSystem = "ARKit session world, meters, +Y up, right-handed; camera position approximates magnetometer position. Magnetic vectors remain in Core Motion device coordinates."
    var attitudeReferenceFrame = "xArbitraryCorrectedZVertical; not an ARKit-world magnetic direction"
    var device = UIDevice.modelIdentifier
    var sampleLimitReached: Bool
    var samples: [Sample]
  }

  private let motion = CMMotionManager()
  private(set) var samples: [Sample] = []
  private var room = 0
  private var lastTimestamp: TimeInterval = -.infinity
  private(set) var status = "Magnetic recording off"
  private var enabled = false
  static let sampleLimit = 9_000 // bounded: about 30 minutes at 5 Hz

  func start(room: Int, enabled: Bool) {
    stop()
    self.room = room
    self.enabled = enabled
    samples.removeAll(keepingCapacity: true)
    lastTimestamp = -.infinity
    guard enabled else { status = "Magnetic recording off"; return }
    guard motion.isDeviceMotionAvailable, motion.isMagnetometerAvailable,
          CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryCorrectedZVertical) else {
      status = "Magnetic sensor unavailable"
      return
    }
    resume()
    status = "Waiting for magnetic sensor calibration"
  }

  func stop() { motion.stopDeviceMotionUpdates() }

  func resume() {
    guard enabled, motion.isDeviceMotionAvailable, motion.isMagnetometerAvailable,
          samples.count < Self.sampleLimit,
          CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryCorrectedZVertical) else { return }
    motion.deviceMotionUpdateInterval = 1.0 / 30
    motion.showsDeviceMovementDisplay = true
    motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical)
  }

  func discard(room: Int) {
    guard self.room == room else { return }
    stop()
    enabled = false
    samples.removeAll()
  }

  func consider(_ frame: ARFrame) {
    guard enabled else { return }
    guard samples.count < Self.sampleLimit else {
      status = "Magnetic sample limit reached; finish this room"
      stop()
      return
    }
    guard frame.timestamp - lastTimestamp >= 0.2,
          case .normal = frame.camera.trackingState,
          let data = motion.deviceMotion else { return }
    let delta = abs(frame.timestamp - data.timestamp)
    // Both frameworks use monotonic seconds since boot. Reject stale pairings;
    // export the actual residual rather than pretending they are simultaneous.
    guard delta <= 0.1 else { status = "Waiting for fresh magnetic readings"; return }
    let field = data.magneticField
    let b = [field.field.x, field.field.y, field.field.z]
    guard b.allSatisfy({ $0.isFinite }) else { return }
    let magnitude = sqrt(b.reduce(0) { $0 + $1 * $1 })
    let t = frame.camera.transform
    let q = data.attitude.quaternion
    samples.append(Sample(
      room: room, timestamp: frame.timestamp, motionTimestamp: data.timestamp,
      poseDeltaSeconds: delta,
      position: [t.columns.3.x, t.columns.3.y, t.columns.3.z],
      cameraTransform: (0..<4).flatMap { c in (0..<4).map { r in t[c][r] } },
      fieldDeviceMicrotesla: b, magnitudeMicrotesla: magnitude,
      calibrationAccuracy: Int(field.accuracy.rawValue),
      deviceAttitudeQuaternion: [q.x, q.y, q.z, q.w]
    ))
    lastTimestamp = frame.timestamp
    let accuracy = field.accuracy == .uncalibrated ? "uncalibrated" : "accuracy \(field.accuracy.rawValue)"
    status = String(format: "%.1f µT · %@ · %d samples", magnitude, accuracy, samples.count)
  }

  func save(in bundle: ScanBundle) throws {
    guard enabled else { return }
    let folder = bundle.file("magnetic")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let recording = Recording(sampleLimitReached: samples.count >= Self.sampleLimit, samples: samples)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(recording).write(to: bundle.file("magnetic/room-\(room).json"), options: .atomic)
  }
}
