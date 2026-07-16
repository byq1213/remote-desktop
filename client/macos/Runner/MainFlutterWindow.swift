import Cocoa
import FlutterMacOS
import CoreGraphics

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Remote input channel: replays viewer mouse/keyboard events on this
    // machine. Requires the app to be trusted for Accessibility
    // (System Settings → Privacy & Security → Accessibility).
    let inputChannel = FlutterMethodChannel(
      name: "remote_desktop/input",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    inputChannel.setMethodCallHandler { call, result in
      RemoteInput.handle(call: call, result: result)
    }

    super.awakeFromNib()
  }
}

/// Replays remote control events using CoreGraphics CGEvent.
enum RemoteInput {
  /// Prompt for Accessibility permission on first use (no-op if already granted).
  static func ensureTrusted() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  static func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: "Missing arguments", details: nil))
      return
    }

    switch call.method {
    case "mouse":
      ensureTrusted()
      guard let action = args["action"] as? String else {
        result(FlutterError(code: "bad_args", message: "Missing action", details: nil)); return
      }
      let x = (args["x"] as? NSNumber)?.doubleValue ?? 0
      let y = (args["y"] as? NSNumber)?.doubleValue ?? 0
      let button = (args["button"] as? NSNumber)?.intValue ?? 0
      let delta = (args["delta"] as? NSNumber)?.doubleValue ?? 0
      postMouse(action: action, x: x, y: y, button: button, delta: delta)
      result(nil)

    case "key":
      ensureTrusted()
      guard let action = args["action"] as? String,
            let keyCode = (args["keyCode"] as? NSNumber)?.intValue else {
        result(FlutterError(code: "bad_args", message: "Missing action/keyCode", details: nil)); return
      }
      postKey(action: action, keyCode: Int64(keyCode))
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func postMouse(action: String, x: Double, y: Double, button: Int, delta: Double) {
    let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
    let mouseButton: CGMouseButton =
      button == 1 ? .right : (button == 2 ? .center : .left)

    let eventType: CGEventType
    switch action {
    case "move": eventType = .mouseMoved
    case "down": eventType = (button == 1) ? .rightMouseDown : (button == 2 ? .otherMouseDown : .leftMouseDown)
    case "up":   eventType = (button == 1) ? .rightMouseUp   : (button == 2 ? .otherMouseUp   : .leftMouseUp)
    case "wheel":
      if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                             wheel1: Int32(delta), wheel2: 0, wheel3: 0) {
        wheel.post(tap: CGEventTapLocation.cghidEventTap)
      }
      return
    default: return
    }

    guard let event = CGEvent(mouseEventSource: nil, mouseType: eventType,
                              mouseCursorPosition: point, mouseButton: mouseButton) else { return }
    event.post(tap: CGEventTapLocation.cghidEventTap)
  }

  static func postKey(action: String, keyCode: Int64) {
    let down = (action == "down")
    // Dart sends the USB HID usage id (keyboard page 0x07); map it to the
    // macOS virtual keycode (kVK_*) used by CGEvent.
    let vk = macVK(fromUsbHid: UInt16(keyCode))
    guard let code = vk else {
      print("RemoteInput: no macOS keycode mapping for USB HID \(keyCode)")
      return
    }
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
    event.post(tap: CGEventTapLocation.cghidEventTap)
  }

  /// Map a USB HID keyboard usage id to a macOS virtual keycode (kVK_*).
  static func macVK(fromUsbHid usage: UInt16) -> CGKeyCode? {
    let map: [UInt16: CGKeyCode] = [
      // letters
      0x04: 0x00, 0x05: 0x0B, 0x06: 0x08, 0x07: 0x02, 0x08: 0x0E, 0x09: 0x03,
      0x0A: 0x05, 0x0B: 0x04, 0x0C: 0x22, 0x0D: 0x26, 0x0E: 0x28, 0x0F: 0x25,
      0x10: 0x2E, 0x11: 0x2D, 0x12: 0x1F, 0x13: 0x23, 0x14: 0x0C, 0x15: 0x0F,
      0x16: 0x01, 0x17: 0x11, 0x18: 0x20, 0x19: 0x09, 0x1A: 0x0D, 0x1B: 0x07,
      0x1C: 0x10, 0x1D: 0x06,
      // digits
      0x1E: 0x1D, 0x1F: 0x12, 0x20: 0x13, 0x21: 0x14, 0x22: 0x15, 0x23: 0x17,
      0x24: 0x16, 0x25: 0x1A, 0x26: 0x1C, 0x27: 0x19,
      // controls & editing
      0x28: 0x24, 0x29: 0x35, 0x2A: 0x33, 0x2B: 0x30, 0x2C: 0x31,
      0x2D: 0x1B, 0x2E: 0x18, 0x2F: 0x21, 0x30: 0x1E, 0x31: 0x2A,
      0x33: 0x29, 0x34: 0x27, 0x35: 0x32, 0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C,
      0x39: 0x39,
      // function keys
      0x3A: 0x7A, 0x3B: 0x78, 0x3C: 0x63, 0x3D: 0x76, 0x3E: 0x60, 0x3F: 0x61,
      0x40: 0x62, 0x41: 0x64, 0x42: 0x65, 0x43: 0x6D, 0x44: 0x67, 0x45: 0x6F,
      0x68: 0x69, 0x69: 0x6B, 0x6A: 0x71, 0x6B: 0x6A, 0x6C: 0x40, 0x6D: 0x4F,
      0x6E: 0x50, 0x6F: 0x5A,
      // navigation
      0x4A: 0x73, 0x4B: 0x74, 0x4C: 0x75, 0x4D: 0x77, 0x4E: 0x79,
      0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E,
      // keypad
      0x54: 0x4B, 0x55: 0x43, 0x56: 0x4E, 0x57: 0x45, 0x58: 0x4C,
      0x59: 0x53, 0x5A: 0x54, 0x5B: 0x55, 0x5C: 0x56, 0x5D: 0x57,
      0x5E: 0x58, 0x5F: 0x59, 0x60: 0x5B, 0x61: 0x5C, 0x62: 0x52, 0x63: 0x41,
      // modifiers
      0xE0: 0x3B, 0xE1: 0x38, 0xE2: 0x3A, 0xE3: 0x37,
      0xE4: 0x3E, 0xE5: 0x3C, 0xE6: 0x3D, 0xE7: 0x37,
    ]
    return map[usage]
  }
}
