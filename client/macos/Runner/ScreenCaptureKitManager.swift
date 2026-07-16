import Cocoa
import FlutterMacOS
import WebRTC
import flutter_webrtc
import CoreMedia
import CoreVideo
import CoreGraphics
import IOSurface

/// Native screen capture bridge that feeds a WebRTC video track **without** the
/// stride shear produced by flutter_webrtc's built-in `getDisplayMedia`.
///
/// ## Why
/// flutter_webrtc's desktop capturer pulls the display at its native resolution
/// and converts the `CVPixelBuffer` to I420 assuming `rowStride == width * 4`.
/// When the native width is not a multiple of 64 (e.g. a Retina built-in at
/// 2940px -> `2940 * 4 = 11760`, not a multiple of the OS's 256-byte
/// row alignment), the real `bytesPerRow` has padding and the frame is sheared
/// ("歪扭"). That shear is baked into the raw buffer, so re-encoding (e.g. the
/// local-preview loopback) can never fix it, and the macOS path silently
/// ignores `exact` width/height constraints.
///
/// ## What we do
/// We use CoreGraphics' `CGDisplayStream` (stable across SDK versions, unlike
/// ScreenCaptureKit's churning API). It scales the chosen display down to the
/// exact target size (width snapped to a multiple of 64, height even) and
/// delivers each frame as an `IOSurface` -> `CVPixelBuffer`, which we wrap in
/// `RTCCVPixelBuffer`. `RTCCVPixelBuffer` reads the buffer's *real*
/// `bytesPerRow` instead of assuming `width * 4`, so the stride mismatch
/// disappears at the source. The track/stream is registered with flutter_webrtc
/// so `addTrack` / the renderer resolve it by id, transparently to the app.
final class ScreenCaptureKitManager: NSObject {

  static let channelName = "dev.remotedesktop/screen_capture_kit"

  private var activeStream: CGDisplayStream?
  private var activeCapturer: RTCVideoCapturer?
  private var activeStreamId: String?
  private var trackIds = [String: String]()

  static func register(with messenger: FlutterBinaryMessenger) {
    let manager = ScreenCaptureKitManager()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      manager.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: "Missing arguments", details: nil))
        return
      }
      start(args: args, result: result)
    case "stop":
      guard let args = call.arguments as? [String: Any],
            let streamId = args["streamId"] as? String else {
        result(nil)
        return
      }
      stop(streamId: streamId, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(args: [String: Any], result: @escaping FlutterResult) {
    let width = (args["width"] as? NSNumber)?.intValue ?? 0
    let height = (args["height"] as? NSNumber)?.intValue ?? 0
    let fps = max(1, (args["fps"] as? NSNumber)?.intValue ?? 30)
    let sourceId = args["sourceId"] as? String

    guard width > 0, height > 0 else {
      result(FlutterError(code: "bad_args", message: "width/height required", details: nil))
      return
    }

    // Resolve the display. flutter_webrtc reports screen source ids as the
    // numeric CGDirectDisplayID; fall back to the main display.
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    if let sourceId = sourceId, let parsed = UInt32(sourceId) {
      displayID = CGDirectDisplayID(parsed)
    }

    guard let plugin = FlutterWebRTCPlugin.sharedSingleton(),
          let factory = plugin.peerConnectionFactory else {
      result(FlutterError(code: "plugin", message: "flutter_webrtc plugin not ready", details: nil))
      return
    }

    let source = factory.videoSource(forScreenCast: true)
    let capturer = RTCVideoCapturer(delegate: source)
    let trackId = UUID().uuidString
    let streamId = UUID().uuidString
    let track = factory.videoTrack(with: source, trackId: trackId)
    let stream = factory.mediaStream(withStreamId: streamId)
    stream.addVideoTrack(track)

    // 'BGRA' four-char code -> 32-bit little-endian ARGB8888, RTCCVPixelBuffer-friendly.
    let kBGRA32 = Int32(bitPattern: 0x42475241)

    // Honor the requested frame rate via CGDisplayStream's minimum-frame-time property.
    let properties: CFDictionary = [
      CGDisplayStream.minimumFrameTime: NSNumber(value: 1.0 / Double(fps))
    ] as CFDictionary

    let handler: CGDisplayStreamFrameAvailableHandler = { [weak self] status, _, frameSurface, _ in
      guard let self = self, status == .frameComplete, let surface = frameSurface else { return }
      guard let capturer = self.activeCapturer, let delegate = capturer.delegate else { return }

      // Wrap the IOSurface so we can read its REAL bytesPerRow.
      var srcPB: Unmanaged<CVPixelBuffer>?
      guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &srcPB) == kCVReturnSuccess,
            let unmanaged = srcPB else { return }
      let src = unmanaged.takeRetainedValue()
      CVPixelBufferLockBaseAddress(src, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }

      // Copy into a tightly-packed CVPixelBuffer (dest bytesPerRow == width * 4).
      // Because `width` is already a multiple of 64 (see Dart side), width * 4 is a
      // multiple of 256, so the destination is row-aligned with NO stride shear, and
      // we fully decouple from CGDisplayStream's IOSurface reuse lifecycle.
      var dstPB: CVPixelBuffer?
      guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &dstPB)
              == kCVReturnSuccess,
            let dst = dstPB else { return }
      CVPixelBufferLockBaseAddress(dst, [])
      defer { CVPixelBufferUnlockBaseAddress(dst, []) }

      let srcRow = CVPixelBufferGetBytesPerRow(src)
      let dstRow = CVPixelBufferGetBytesPerRow(dst)
      let rows = min(srcRow, dstRow)
      guard let srcBase = CVPixelBufferGetBaseAddress(src),
            let dstBase = CVPixelBufferGetBaseAddress(dst) else { return }
      for y in 0..<height {
        memcpy(dstBase + y * dstRow, srcBase + y * srcRow, rows)
      }

      // RTCCVPixelBuffer reads the destination's real bytesPerRow -> no stride shear.
      let rtcPB = RTCCVPixelBuffer(pixelBuffer: dst)
      let t = Int64(CFAbsoluteTimeGetCurrent() * 1_000_000_000)
      let vframe = RTCVideoFrame(buffer: rtcPB, rotation: ._0, timeStampNs: t)
      delegate.capturer(capturer, didCapture: vframe)
    }

    guard let cgStream = CGDisplayStream(
      dispatchQueueDisplay: displayID,
      outputWidth: width,
      outputHeight: height,
      pixelFormat: kBGRA32,
      properties: properties,
      queue: DispatchQueue(label: "cg-display-stream"),
      handler: handler) else {
      result(FlutterError(code: "create", message: "CGDisplayStreamCreate failed", details: nil))
      return
    }

    activeStream = cgStream
    activeCapturer = capturer
    activeStreamId = streamId
    trackIds[streamId] = trackId

    guard cgStream.start() == .success else {
      activeStream = nil
      activeCapturer = nil
      activeStreamId = nil
      trackIds.removeValue(forKey: streamId)
      result(FlutterError(code: "start", message: "CGDisplayStreamStart failed", details: nil))
      return
    }

    let localTrack = LocalTrackImpl(track)
    plugin.localTracks?.setValue(localTrack, forKey: trackId)
    plugin.localStreams?.setValue(stream, forKey: streamId)
    result([
      "streamId": streamId,
      "trackId": trackId,
      "width": width,
      "height": height,
    ])
  }

  private func stop(streamId: String, result: @escaping FlutterResult) {
    guard streamId == activeStreamId, let cgStream = activeStream else {
      result(nil)
      return
    }
    cgStream.stop()
    activeStream = nil
    activeCapturer = nil
    activeStreamId = nil
    let trackId = trackIds[streamId]
    trackIds.removeValue(forKey: streamId)
    if let plugin = FlutterWebRTCPlugin.sharedSingleton(), let trackId = trackId {
      plugin.localTracks?.removeObject(forKey: trackId)
      plugin.localStreams?.removeObject(forKey: streamId)
    }
    result(nil)
  }
}

/// Minimal `LocalTrack` wrapper so flutter_webrtc can resolve our native track by id.
private final class LocalTrackImpl: NSObject, LocalTrack {
  let _track: RTCMediaStreamTrack
  init(_ track: RTCMediaStreamTrack) { self._track = track }
  func track() -> RTCMediaStreamTrack { _track }
}
