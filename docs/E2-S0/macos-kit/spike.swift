import ApplicationServices
import CoreGraphics
import Foundation

// E-2 spike helper (AnyShare S0-②): CGEvent injection + CGEventTap capture.
// Build: swiftc spike.swift -o spike
// Run:   ./spike status | tap X Y | move DX DY | type TEXT | listen SECONDS

func usage() -> Never {
    print("usage: spike status | tap X Y | move DX DY | type TEXT | listen SECONDS")
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

func mousePoint(_ x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: x, y: y)
}

func postMouse(_ type: CGEventType, _ point: CGPoint, button: CGMouseButton = .left) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    event?.post(tap: .cghidEventTap)
}

switch args[1] {
case "status":
    let trusted = AXIsProcessTrusted()
    print("accessibility trusted: \(trusted)")
    let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
        callback: { _, _, _, _ in nil },
        userInfo: nil
    )
    print("event tap creatable: \(tap != nil)")
    if tap == nil {
        print("hint: grant accessibility in System Settings > Privacy & Security > Accessibility")
    }
    exit(trusted && tap != nil ? 0 : 1)

case "tap":
    guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]) else { usage() }
    let p = mousePoint(x, y)
    postMouse(.mouseMoved, p)
    postMouse(.leftMouseDown, p)
    usleep(40_000)
    postMouse(.leftMouseUp, p)
    print("tap posted at \(x),\(y)")

case "move":
    guard args.count == 4, let dx = Double(args[2]), let dy = Double(args[3]) else { usage() }
    var loc = CGEvent(source: nil)?.location ?? .zero
    loc.x += CGFloat(dx)
    loc.y += CGFloat(dy)
    postMouse(.mouseMoved, loc)
    print("moved to \(loc.x),\(loc.y)")

case "type":
    guard args.count == 3 else { usage() }
    let text = Array(args[2].utf16)
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
    else {
        print("failed to create keyboard events")
        exit(1)
    }
    text.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    print("typed \(text.count) utf16 units")

case "listen":
    guard args.count == 3, let seconds = Double(args[2]) else { usage() }
    let mask = (1 << CGEventType.mouseMoved.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.keyDown.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(mask),
        callback: { _, type, event, _ in
            let loc = event.location
            let now = Date()
            FileHandle.standardError.write("event type=\(type.rawValue) pos=\(Int(loc.x)),\(Int(loc.y)) at=\(now.timeIntervalSince1970)\n".data(using: .utf8)!)
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    ) else {
        print("event tap failed (accessibility permission missing)")
        exit(1)
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        print("run loop source failed")
        exit(1)
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("listening for \(seconds)s, move the mouse and press keys now")
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
        CFRunLoopRunInMode(.defaultMode, 0.1, true)
    }
    print("done")

default:
    usage()
}
