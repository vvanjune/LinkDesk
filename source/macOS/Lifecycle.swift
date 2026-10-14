import Foundation
import AppKit
import CoreGraphics

struct MacDesktopSnapshot { var ready: Bool; var signature: String }
struct MacDesktopStability {
    private var previous: String?
    private var since = Date.distantPast
    mutating func observe(_ snapshot: MacDesktopSnapshot, at now: Date, duration: TimeInterval = 5) -> Bool {
        guard snapshot.ready else { previous = nil; return false }
        guard previous == snapshot.signature else { previous = snapshot.signature; since = now; return false }
        return now.timeIntervalSince(since) >= duration
    }
}
enum MacDesktopState {
    static func read() -> MacDesktopSnapshot {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              let foreground = NSWorkspace.shared.frontmostApplication,
              foreground.bundleIdentifier != "com.apple.loginwindow" else { return MacDesktopSnapshot(ready: false, signature: "") }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success, count > 0 else { return MacDesktopSnapshot(ready: false, signature: "") }
        let awake = ids.prefix(Int(count)).filter { CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0 }
        guard !awake.isEmpty else { return MacDesktopSnapshot(ready: false, signature: "") }
        return MacDesktopSnapshot(ready: true, signature: awake.sorted().map { id in let r = CGDisplayBounds(id); return "\(id):\(r.origin.x):\(r.origin.y):\(r.width):\(r.height)" }.joined(separator: ";"))
    }
}
