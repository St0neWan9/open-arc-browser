// axtool: accessibility and window helper for scripts/visual-diff.sh.
//
// Build: swiftc -O -o <bin>/axtool scripts/visual-diff/axtool.swift   (visual-diff.sh does this)
// or run directly: swift scripts/visual-diff/axtool.swift <subcommand> ...
//
// Subcommands (all print JSON to stdout, errors to stderr):
//   preflight
//       {"accessibility": bool, "screenRecording": bool}. Only checks; never prompts.
//   frame     --bundle B [--pid P] [--window N]
//       The target window's frame in screen points (top-left origin) and its CGWindowID.
//   set-frame --bundle B [--pid P] [--window N | --match-frame x,y,w,h] --size WxH [--origin X,Y]
//       Moves/resizes the target window (AXPosition/AXSize, the same calls System Events
//       makes), then prints the frame the app actually accepted. Without --origin the window
//       stays where it is, shifted only as needed to fit its screen's visible area. This is the ONLY write the
//       tool ever does to another app, and visual-diff.sh restores the original frame.
//       --fill-if-clamped (our own app only): when the requested frame is the screen's visible
//       frame and AppKit's AX setter left the window 1 pt short, press Window ▸ Fill instead.
//   dump      --bundle B [--pid P] [--window N] [--max-depth N] [--max-nodes N]
//             [--redact --privacy <mapping.json>] [--descend-web]
//       The window's accessibility tree:
//       { "bundle", "pid", "windowNumber", "window": {x,y,w,h} (screen points),
//         "redacted", "truncated",
//         "elements": [ { "index", "depth", "parent", "role", "subrole", "identifier",
//                         "title", "description", "value" (truncated), "enabled",
//                         "frame": {x,y,w,h} (relative to the window's top-left, points),
//                         "visible" } ] }
//       Read-only: reads AX attributes only, never performs AX actions. It does not descend
//       into web content (AXWebArea) unless --descend-web, because page content is private.
//   compose   --a A.png --size-a WxH --b B.png --size-b WxH [--scale S] --side OUT.png
//             --overlay OUT.png [--diff OUT.png] [--label-a TEXT --label-b TEXT]
//       Draws both window captures at their point sizes times S pixels per point (default: the
//       larger backing scale of the two captures),
//       top-left aligned, and writes a side-by-side image, a 50 % overlay (B over A) and an
//       absolute-difference image (black = identical).
//
// App selection: --bundle B picks the lowest-pid process of that bundle id; --pid P picks that
// process instead (several instances of one bundle, e.g. test instances with different data
// directories), and it must belong to bundle B.
//
// Window selection: the app's AXMainWindow when it is a standard window, else its first
// standard window; --window N picks the N-th standard window instead, and
// --match-frame x,y,w,h picks the standard window closest to that frame.
// --window-identifier REGEX first narrows the candidates to standard windows whose
// AXIdentifier matches (the window identifier is only matched, never printed unredacted).
//
// Privacy (--redact): title/description/value become "<redacted>" unless the exact string
// is in `privacy.allowText` of the given JSON file (structure labels like "Go back",
// "Clear", "New Tab"). Identifiers are redacted too, because some carry user text (Arc's
// dock items are named after Spaces, row identifiers can be page titles): an identifier
// is kept only if it matches one of `privacy.identifierRules`
// ({"regex", "keep": "full" | "prefix"}; "prefix" keeps capture group 1 plus "…").
// Redaction happens inside this process, so private text never reaches disk or stdout.

import ApplicationServices
import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Common

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(("axtool: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func printJSON(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else { fail("cannot encode JSON") }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

struct Args {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String], flags known: Set<String>) {
        var rest = raw
        while !rest.isEmpty {
            let a = rest.removeFirst()
            guard a.hasPrefix("--") else { fail("unexpected argument \(a)") }
            if known.contains(a) {
                flags.insert(a)
            } else {
                guard !rest.isEmpty else { fail("missing value for \(a)") }
                values[a] = rest.removeFirst()
            }
        }
    }

    func require(_ key: String) -> String {
        guard let v = values[key] else { fail("\(key) is required") }
        return v
    }

    func int(_ key: String, _ fallback: Int) -> Int {
        guard let v = values[key] else { return fallback }
        guard let i = Int(v) else { fail("\(key) must be an integer") }
        return i
    }

    func pair(_ key: String) -> (Double, Double)? {
        guard let v = values[key] else { return nil }
        let parts = v.split(whereSeparator: { $0 == "x" || $0 == "," }).compactMap { Double($0) }
        guard parts.count == 2 else { fail("\(key) must look like 1920x985 or 10,30") }
        return (parts[0], parts[1])
    }
}

func round2(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }

func frameJSON(_ r: CGRect) -> [String: Any] {
    ["x": round2(r.minX), "y": round2(r.minY), "w": round2(r.width), "h": round2(r.height)]
}

// MARK: - AX access

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}

func string(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = attr(el, name) else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func axValue(_ el: AXUIElement, _ name: String) -> AXValue? {
    guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    return (v as! AXValue)  // type id checked above
}

func frame(of el: AXUIElement) -> CGRect? {
    var p = CGPoint.zero, s = CGSize.zero
    guard let pv = axValue(el, kAXPositionAttribute), AXValueGetValue(pv, .cgPoint, &p),
          let sv = axValue(el, kAXSizeAttribute), AXValueGetValue(sv, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// The app's main process for a bundle id (the lowest pid when several instances run; pass
/// --pid to choose). NSRunningApplication can come back empty when
/// the caller has no window-server session (some sandboxed shells), so this falls back to
/// scanning process executables for `<X>.app/Contents/MacOS/<CFBundleExecutable>`.
func resolvePID(bundle: String) -> pid_t? {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
    if let lowest = running.map(\.processIdentifier).min() {
        return lowest
    }
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var buffer = [CChar](repeating: 0, count: 4096)
    var candidates: [pid_t] = []
    for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { continue }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        // Helpers nested in Frameworks/ have their own bundle ids, so they drop out here.
        guard let b = Bundle(path: bundlePath), b.bundleIdentifier == bundle,
              b.executableURL?.path == path else { continue }
        candidates.append(pid)
    }
    return candidates.min()
}

/// The bundle id of an app's main process, from NSRunningApplication or, like `resolvePID`,
/// from the executable path when NSRunningApplication is empty. nil for other processes.
func bundleIdentifier(pid: pid_t) -> String? {
    if let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier {
        return id
    }
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let path = String(cString: buffer)
    guard let range = path.range(of: ".app/Contents/MacOS/", options: .backwards),
          let b = Bundle(path: String(path[..<range.lowerBound]) + ".app"),
          b.executableURL?.path == path else { return nil }
    return b.bundleIdentifier
}

struct Target {
    let bundle: String
    let pid: pid_t
    let window: AXUIElement
}

func target(_ args: Args) -> Target {
    guard AXIsProcessTrusted() else {
        fail("Accessibility permission is missing for this terminal (System Settings > Privacy & Security > Accessibility)", code: 3)
    }
    let bundle = args.require("--bundle")
    let pid: pid_t
    if let raw = args.values["--pid"] {
        guard let p = pid_t(raw), p > 0 else { fail("--pid must be a process id") }
        guard let owner = bundleIdentifier(pid: p) else { fail("no running app with pid \(p)", code: 4) }
        guard owner == bundle else { fail("pid \(p) is \(owner), not \(bundle)", code: 4) }
        pid = p
    } else {
        guard let p = resolvePID(bundle: bundle) else { fail("no running app with bundle id \(bundle)", code: 4) }
        pid = p
    }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3)
    let all = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    var standard = all.filter { string($0, kAXSubroleAttribute) == "AXStandardWindow" }
    if let pattern = args.values["--window-identifier"] {
        // Only windows whose AXIdentifier matches (e.g. browser windows, not Settings).
        guard let regex = try? NSRegularExpression(pattern: pattern) else { fail("bad --window-identifier \(pattern)") }
        standard = standard.filter { w in
            guard let id = string(w, kAXIdentifierAttribute) else { return false }
            return regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
        }
        if standard.isEmpty { fail("\(bundle) has no standard window whose identifier matches \(pattern)", code: 5) }
    }
    if let raw = args.values["--match-frame"] {
        // The standard window whose frame is closest to x,y,w,h (used to restore exactly the
        // window that was resized, even if another window became main meanwhile).
        let v = raw.split(separator: ",").compactMap { Double($0) }
        guard v.count == 4 else { fail("--match-frame must look like x,y,w,h") }
        let want = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        let scored = standard.compactMap { w -> (AXUIElement, CGFloat)? in
            guard let f = frame(of: w) else { return nil }
            return (w, abs(f.minX - want.minX) + abs(f.minY - want.minY) + abs(f.width - want.width) + abs(f.height - want.height))
        }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 < 8 else {
            fail("\(bundle) has no standard window at \(raw)", code: 5)
        }
        return Target(bundle: bundle, pid: pid, window: best.0)
    }
    if let index = args.values["--window"].flatMap(Int.init) {
        guard index < standard.count else {
            fail("\(bundle) has \(standard.count) standard window(s); --window \(index) is not available", code: 5)
        }
        return Target(bundle: bundle, pid: pid, window: standard[index])
    }
    if let main = attr(app, kAXMainWindowAttribute), CFGetTypeID(main) == AXUIElementGetTypeID() {
        let el = main as! AXUIElement  // type id checked above
        if standard.contains(where: { CFEqual($0, el) }) { return Target(bundle: bundle, pid: pid, window: el) }
    }
    guard let first = standard.first else { fail("\(bundle) has no standard window", code: 5) }
    return Target(bundle: bundle, pid: pid, window: first)
}

/// The CGWindowID of the on-screen window with this pid and bounds. Owner pid and bounds
/// are readable without Screen Recording permission.
func windowNumber(pid: pid_t, frame: CGRect) -> Int? {
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    var best: (id: Int, distance: CGFloat)?
    for info in list {
        guard (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid,
              (info[kCGWindowLayer as String] as? Int) == 0,
              let id = info[kCGWindowNumber as String] as? Int,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"]
        else { continue }
        let d = abs(x - frame.minX) + abs(y - frame.minY) + abs(w - frame.width) + abs(h - frame.height)
        if best == nil || d < best!.distance { best = (id, d) }
    }
    guard let best, best.distance < 4 else { return nil }
    return best.id
}

func windowInfo(_ t: Target) -> [String: Any] {
    guard let f = frame(of: t.window) else { fail("cannot read the window frame of \(t.bundle)", code: 5) }
    var out: [String: Any] = ["bundle": t.bundle, "pid": Int(t.pid), "window": frameJSON(f)]
    if let id = windowNumber(pid: t.pid, frame: f) { out["windowNumber"] = id }
    return out
}

// MARK: - Subcommands

func preflight() {
    printJSON(["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess()])
}

/// The visible frame (menu bar and Dock excluded) of the screen holding `point`, in AX
/// coordinates (top-left origin at the primary screen's top-left).
func visibleFrame(containing point: CGPoint) -> CGRect? {
    guard let primary = NSScreen.screens.first else { return nil }
    func toAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
    }
    let screens = NSScreen.screens
    let screen = screens.first { toAX($0.frame).contains(point) } ?? screens.first
    return screen.map { toAX($0.visibleFrame) }
}

func setFrame(_ args: Args) {
    let t = target(args)
    guard let (w, h) = args.pair("--size") else { fail("--size is required") }
    var origin: CGPoint
    if let (x, y) = args.pair("--origin") {
        origin = CGPoint(x: x, y: y)
    } else {
        // Keep the window where it is, but slide it so the new size fits the visible frame
        // of its screen (otherwise the app or the system clamps the size).
        guard let current = frame(of: t.window) else { fail("cannot read the window frame of \(t.bundle)", code: 5) }
        origin = current.origin
        if let vf = visibleFrame(containing: CGPoint(x: current.minX + 1, y: current.minY + 1)) {
            if w > vf.width || h > vf.height {
                FileHandle.standardError.write("axtool: \(Int(w))×\(Int(h)) pt is larger than the visible screen area \(Int(vf.width))×\(Int(vf.height)); the app may clamp it\n".data(using: .utf8)!)
            }
            origin.x = max(vf.minX, min(origin.x, vf.maxX - w))
            origin.y = max(vf.minY, min(origin.y, vf.maxY - h))
        }
    }
    var p = origin
    if let v = AXValueCreate(.cgPoint, &p) {
        AXUIElementSetAttributeValue(t.window, kAXPositionAttribute as CFString, v)
    }
    var s = CGSize(width: w, height: h)
    if let v = AXValueCreate(.cgSize, &s) {
        let err = AXUIElementSetAttributeValue(t.window, kAXSizeAttribute as CFString, v)
        if err != .success { fail("setting the size of \(t.bundle) failed (AXError \(err.rawValue))", code: 6) }
    }
    if args.flags.contains("--fill-if-clamped") { fillIfClamped(t, origin: origin, size: s) }
    printJSON(windowInfo(t))
}

/// AppKit's accessibility size setter keeps the window's top edge and stops one point short of the
/// visible area's bottom, so AXSize can never make a window exactly as tall as the visible area
/// (a plain NSWindow shows the same 985 → 984). When the requested frame IS the visible frame and
/// the window came out short, press the app's Window ▸ Fill, which sets exactly the visible frame.
/// Only for our own app (visual-diff.sh passes the flag for Open Arc, never for the reference).
func fillIfClamped(_ t: Target, origin: CGPoint, size: CGSize) {
    guard let got = frame(of: t.window), got.size != size,
          abs(got.width - size.width) <= 1, abs(got.height - size.height) <= 1,
          let vf = visibleFrame(containing: CGPoint(x: origin.x + 1, y: origin.y + 1)),
          CGRect(origin: origin, size: size) == vf else { return }
    let app = AXUIElementCreateApplication(t.pid)
    guard let bar = attr(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return }
    func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    let menus = children(bar as! AXUIElement)  // type id checked above
    guard let windowMenu = menus.first(where: { string($0, kAXTitleAttribute) == "Window" }),
          let menu = children(windowMenu).first,
          let fill = children(menu).first(where: { string($0, kAXTitleAttribute) == "Fill" }) else { return }
    AXUIElementPerformAction(t.window, kAXRaiseAction as CFString)
    AXUIElementPerformAction(fill, kAXPressAction as CFString)
    usleep(500_000)
}

struct Privacy {
    var allowText: Set<String> = []
    var identifierRules: [(regex: NSRegularExpression, keepFull: Bool)] = []

    init(path: String?) {
        guard let path else { return }
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let privacy = root["privacy"] as? [String: Any]
        else { fail("cannot read the privacy section of \(path)") }
        allowText = Set((privacy["allowText"] as? [String]) ?? [])
        for rule in (privacy["identifierRules"] as? [[String: String]]) ?? [] {
            guard let pattern = rule["regex"], let regex = try? NSRegularExpression(pattern: pattern)
            else { fail("bad identifier rule \(rule)") }
            identifierRules.append((regex, rule["keep"] != "prefix"))
        }
    }

    func identifier(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        for rule in identifierRules {
            guard let m = rule.regex.firstMatch(in: s, range: range) else { continue }
            if rule.keepFull { return s }
            if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) { return String(s[r]) + "…" }
            return "<redacted>"
        }
        return "<redacted>"
    }

    func text(_ s: String) -> String {
        allowText.contains(s) ? s : "<redacted>"
    }
}

func dump(_ args: Args) {
    let t = target(args)
    let redact = args.flags.contains("--redact")
    let privacy = Privacy(path: args.values["--privacy"])
    if redact && args.values["--privacy"] == nil {
        FileHandle.standardError.write("axtool: --redact without --privacy redacts all text and identifiers\n".data(using: .utf8)!)
    }
    let descendWeb = args.flags.contains("--descend-web")
    let maxDepth = args.int("--max-depth", 40)
    let maxNodes = args.int("--max-nodes", 6000)
    guard let windowFrame = frame(of: t.window) else { fail("cannot read the window frame of \(t.bundle)", code: 5) }

    func text(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let line = raw.replacingOccurrences(of: "\n", with: " ")
        if redact { return privacy.text(line) }
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    var elements: [[String: Any]] = []
    var truncated = false
    // `clip` is the window frame intersected with every enclosing scroll area, so rows
    // scrolled out of view and Space pages paged off to the side count as not visible.
    func walk(_ el: AXUIElement, depth: Int, parent: Int, clip: CGRect) {
        if elements.count >= maxNodes { truncated = true; return }
        let role = string(el, kAXRoleAttribute) ?? ""
        let index = elements.count
        var entry: [String: Any] = ["index": index, "depth": depth, "parent": parent, "role": role]
        if let v = string(el, kAXSubroleAttribute) { entry["subrole"] = v }
        if let v = string(el, kAXIdentifierAttribute), !v.isEmpty { entry["identifier"] = redact ? privacy.identifier(v) : v }
        if let v = text(string(el, kAXTitleAttribute)) { entry["title"] = v }
        if let v = text(string(el, kAXDescriptionAttribute)) { entry["description"] = v }
        if role != "AXScrollBar", role != "AXSlider", let v = text(string(el, kAXValueAttribute)) { entry["value"] = v }
        if let v = attr(el, kAXEnabledAttribute) as? Bool { entry["enabled"] = v }
        var childClip = clip
        if let f = frame(of: el) {
            entry["frame"] = frameJSON(f.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY))
            let shown = f.intersection(clip)
            entry["visible"] = !shown.isNull && shown.width > 0.5 && shown.height > 0.5
            if role == "AXScrollArea" { childClip = shown.isNull ? .zero : shown }
        }
        elements.append(entry)
        if depth >= maxDepth { return }
        if role == "AXWebArea" && !descendWeb { return }
        for child in children(el) { walk(child, depth: depth + 1, parent: index, clip: childClip) }
    }
    walk(t.window, depth: 0, parent: -1, clip: windowFrame)

    var out = windowInfo(t)
    out["redacted"] = redact
    out["truncated"] = truncated
    out["elements"] = elements
    printJSON(out)
}

func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read image \(path)") }
    return img
}

func writePNG(_ img: CGImage, _ path: String) {
    guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                    UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(path)")
    }
    CGImageDestinationAddImage(dst, img, nil)
    guard CGImageDestinationFinalize(dst) else { fail("cannot write \(path)") }
}

func canvas(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot create a canvas") }
    ctx.interpolationQuality = .high
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    draw(ctx)
    guard let img = ctx.makeImage() else { fail("cannot render the canvas") }
    return img
}

func drawLabel(_ text: String, in ctx: CGContext, at point: CGPoint, scale: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 12 * scale),
        .foregroundColor: NSColor.white,
        .backgroundColor: NSColor.black.withAlphaComponent(0.6),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: " \(text) ", attributes: attrs))
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

func compose(_ args: Args) {
    let a = loadImage(args.require("--a"))
    let b = loadImage(args.require("--b"))
    guard let (aw, ah) = args.pair("--size-a"), let (bw, bh) = args.pair("--size-b") else {
        fail("--size-a and --size-b (window sizes in points) are required")
    }
    // Default scale: the larger backing scale of the two captures (pixels per point).
    let auto = max(CGFloat(a.width) / CGFloat(aw), CGFloat(b.width) / CGFloat(bw)).rounded()
    let scale = args.values["--scale"].flatMap(Double.init).map { CGFloat($0) } ?? max(auto, 1)
    // Each capture is drawn at its own point size times `scale`, anchored at the top-left, so
    // captures from displays with different backing scales line up point for point.
    let rectA = CGSize(width: CGFloat(aw) * scale, height: CGFloat(ah) * scale)
    let rectB = CGSize(width: CGFloat(bw) * scale, height: CGFloat(bh) * scale)
    let w = Int(max(rectA.width, rectB.width).rounded()), h = Int(max(rectA.height, rectB.height).rounded())
    let gap = Int(16 * scale)
    func topLeft(_ size: CGSize, dx: CGFloat = 0, canvasHeight: Int) -> CGRect {
        CGRect(x: dx, y: CGFloat(canvasHeight) - size.height, width: size.width, height: size.height)
    }

    let side = canvas(2 * w + gap, h) { ctx in
        ctx.draw(a, in: topLeft(rectA, canvasHeight: h))
        ctx.draw(b, in: topLeft(rectB, dx: CGFloat(w + gap), canvasHeight: h))
        let baseline = CGFloat(h) - 20 * scale
        if let label = args.values["--label-a"] { drawLabel(label, in: ctx, at: CGPoint(x: 8 * scale, y: baseline), scale: scale) }
        if let label = args.values["--label-b"] {
            drawLabel(label, in: ctx, at: CGPoint(x: CGFloat(w + gap) + 8 * scale, y: baseline), scale: scale)
        }
    }
    writePNG(side, args.require("--side"))

    let overlay = canvas(w, h) { ctx in
        ctx.draw(a, in: topLeft(rectA, canvasHeight: h))
        ctx.setAlpha(0.5)
        ctx.draw(b, in: topLeft(rectB, canvasHeight: h))
    }
    writePNG(overlay, args.require("--overlay"))

    if let path = args.values["--diff"] {
        let diff = canvas(w, h) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(a, in: topLeft(rectA, canvasHeight: h))
            ctx.setBlendMode(.difference)
            ctx.draw(b, in: topLeft(rectB, canvasHeight: h))
        }
        writePNG(diff, path)
    }
    printJSON(["scale": Double(scale), "pixels": ["w": w, "h": h]])
}

// MARK: - Main

var argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { fail("usage: axtool preflight|frame|set-frame|dump|compose ...") }
argv.removeFirst()
switch command {
case "preflight": preflight()
case "frame": printJSON(windowInfo(target(Args(argv, flags: []))))
case "set-frame": setFrame(Args(argv, flags: ["--fill-if-clamped"]))
case "dump": dump(Args(argv, flags: ["--redact", "--descend-web"]))
case "compose": compose(Args(argv, flags: []))
default: fail("unknown subcommand \(command)")
}
