// window-order-probe.swift
//
// The evidence standard for issue 184 and ADR-0034: where the OnetimePad
// card sits in the window server's front to back order, compared with
// the window of the app the person is looking at. It reads the on screen
// window list and prints one VERDICT line per sample, so a hardware run
// is judged by what the window server reports and not by eye.
//
// It only reads. It launches, activates and closes nothing, and it needs
// no screen recording grant, because it never reads a window's name or
// its owner's name. On macOS 26 `kCGWindowOwnerName` is nil without that
// grant, so the card is found by the PID of the running app whose bundle
// id is com.onetimesecret.pad or dev.onetimesecret.pad, and app names
// come from NSRunningApplication.
//
// Compile and run (xcrun hangs here without the two exports):
//
//   export SDKROOT=/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
//   export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
//   swiftc -O scripts/window-order-probe.swift -o /tmp/window-order-probe
//   /tmp/window-order-probe --expect behind
//
// Options:
//
//   --expect behind|above   What the sample is judged against. `behind`
//                           (the default) passes when the card is absent
//                           from the list or listed after the target.
//                           `above` passes when the card is present and
//                           listed before the target.
//   --card-window N         Pin the card to one window number, taken from
//                           the app's log line (`stance=... window=N`).
//                           Without it the card is the frontmost window of
//                           real size owned by the app. N is checked
//                           against the window server's full list: it has
//                           to exist and belong to the pad, or the sample
//                           is a SKIP and not a verdict about a stale
//                           number.
//   --pad-pid PID           Name the pad's process directly. A dev build
//                           started with a bare `swift run` has no bundle
//                           id to be found by.
//   --watch                 Stay running and sample 1.5 s after each app
//                           activation and each Space change, which is
//                           long enough for the transition to settle.
//   --after SECONDS         Wait, take one sample, and exit. For the routes
//                           that activate nothing: a hotkey raise and an
//                           outside click inside a full screen Space post
//                           no activation and no Space change, so `--watch`
//                           stays silent, and switching to Terminal to run
//                           the probe leaves the Space. Start it with
//                           `--after 8`, go back to the app, perform the
//                           route, and read the verdict afterwards.
//
// The verdict line:
//
//   VERDICT PASS|FAIL|SKIP expect=behind|above card=<index or absent> target=<index or none> pad=<pids or not-running> [reason=<why skipped>] front=<app>
//
// `front` is last because app names carry spaces. SKIP means there was
// nothing to judge, and `reason` says why: the pad was not found
// (`pad=not-running`, where `card=absent` would otherwise read as a pass
// it has not earned), the `--card-window` number is unknown to the window
// server or belongs to another process, the frontmost app has no ordinary
// window of real size on screen, or the frontmost app is OnetimePad
// itself while the card is expected behind. With OnetimePad frontmost and
// the card expected above, the card being on screen is the pass. The exit
// status of a single sample is 0 for PASS and SKIP, and 1 for FAIL.

import AppKit
import CoreGraphics

// MARK: Arguments

enum Expectation: String {
    case behind
    case above
}

struct Options {
    var expect: Expectation = .behind
    var cardWindow: Int?
    var padPID: pid_t?
    var watch = false
    var after: TimeInterval?
}

func usage() -> Never {
    FileHandle.standardError.write(Data(
        "usage: window-order-probe [--expect behind|above] [--card-window N] [--pad-pid PID] [--watch | --after SECONDS]\n"
            .utf8
    ))
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--expect":
            guard !arguments.isEmpty, let expect = Expectation(rawValue: arguments.removeFirst())
            else { usage() }
            options.expect = expect
        case "--card-window":
            guard !arguments.isEmpty, let number = Int(arguments.removeFirst()) else { usage() }
            options.cardWindow = number
        case "--pad-pid":
            guard !arguments.isEmpty, let pid = pid_t(arguments.removeFirst()), pid > 0
            else { usage() }
            options.padPID = pid
        case "--watch":
            options.watch = true
        case "--after":
            guard !arguments.isEmpty, let seconds = TimeInterval(arguments.removeFirst()),
                seconds >= 0
            else { usage() }
            options.after = seconds
        default:
            usage()
        }
    }
    // One or the other: a watch never exits, and a delayed sample does.
    if options.watch, options.after != nil { usage() }
    return options
}

// MARK: The window list

struct WindowRecord {
    let index: Int
    let number: Int
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
    let app: String
}

let padBundleIDs: Set<String> = ["com.onetimesecret.pad", "dev.onetimesecret.pad"]

/// A window smaller than this is a status item, a tooltip or a helper
/// speck, never the thing a person is looking at.
let realSize: CGFloat = 100

func appName(for pid: pid_t) -> String {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return "pid \(pid)" }
    return app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
}

/// The pad's processes: every running app with one of the two bundle
/// ids, and the PID given by hand when it names a live process. A PID
/// that is no longer running is left out, so a stale `--pad-pid` reads
/// as a pad that is not running and not as a card that is absent.
func padPIDs(_ options: Options) -> Set<pid_t> {
    var pids = Set(
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return padBundleIDs.contains(id)
            }
            .map(\.processIdentifier)
    )
    if let given = options.padPID, kill(given, 0) == 0 || errno == EPERM {
        pids.insert(given)
    }
    return pids
}

/// Front to back, as the window server lists them. Every key is read
/// optionally; a window missing one of them is skipped, not trusted.
/// On screen only is the list the verdict is judged from; the full list
/// is only for checking that a `--card-window` number is real.
func windowList(_ option: CGWindowListOption) -> [WindowRecord] {
    guard
        let list = CGWindowListCopyWindowInfo(option, kCGNullWindowID)
            as? [[String: Any]]
    else { return [] }
    var records: [WindowRecord] = []
    for entry in list {
        guard
            let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue
        else { continue }
        var bounds = CGRect.zero
        if let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        {
            bounds = rect
        }
        records.append(
            WindowRecord(
                index: records.count,
                number: number,
                pid: pid,
                layer: layer,
                bounds: bounds,
                app: appName(for: pid)
            )
        )
    }
    return records
}

func isRealSize(_ window: WindowRecord) -> Bool {
    window.bounds.width >= realSize && window.bounds.height >= realSize
}

// MARK: One sample

enum Verdict: String {
    case pass = "PASS"
    case fail = "FAIL"
    case skip = "SKIP"
}

@discardableResult
func sample(_ options: Options, reason: String) -> Verdict {
    let windows = windowList(.optionOnScreenOnly)
    let pads = padPIDs(options)
    let front = NSWorkspace.shared.frontmostApplication
    let frontPID = front?.processIdentifier
    let frontName = front?.localizedName ?? front?.bundleIdentifier ?? "none"

    // The card: the pinned window number when one was given, otherwise
    // the frontmost window of real size that the app owns. The resting
    // pane spans the screen at desktop level and the raised card hugs
    // its own rect, and either is the card for this purpose.
    let card = windows.first { window in
        if let pinned = options.cardWindow { return window.number == pinned }
        return pads.contains(window.pid) && isRealSize(window)
    }
    // The target: the frontmost app's first ordinary window of real
    // size. Layer 0 is the normal window level, which is where a full
    // screen window sits.
    let target = windows.first { window in
        window.pid == frontPID && window.layer == 0 && isRealSize(window)
            && !pads.contains(window.pid)
    }

    print("SAMPLE reason=\(reason) windows=\(windows.count) front=\(frontName)")
    for window in windows {
        var marks: [String] = []
        if window.index == card?.index { marks.append("CARD") }
        if window.index == target?.index { marks.append("TARGET") }
        let bounds = window.bounds
        let rect =
            "\(Int(bounds.origin.x)),\(Int(bounds.origin.y)) \(Int(bounds.width))x\(Int(bounds.height))"
        let line =
            "  [\(window.index)] app=\(window.app) pid=\(window.pid) layer=\(window.layer) bounds=\(rect) window=\(window.number)"
        print(marks.isEmpty ? line : line + " <== " + marks.joined(separator: " "))
    }

    // Whether the sample can be judged at all. A card that is absent is
    // a pass for `behind`, so every way of failing to identify the pad
    // has to be ruled out first, or the probe passes a route it never
    // saw.
    var skipReason: String?
    if pads.isEmpty {
        skipReason = "pad-not-running"
    } else if let pinned = options.cardWindow {
        let known = windowList(.optionAll).first { $0.number == pinned }
        if let known {
            if !pads.contains(known.pid) { skipReason = "card-window-not-the-pads" }
        } else {
            skipReason = "card-window-not-found"
        }
    }

    let verdict: Verdict
    if skipReason != nil {
        verdict = .skip
    } else if let frontPID, pads.contains(frontPID) {
        // The pad itself is frontmost, so there is no other app's
        // window to compare against. Expecting the card above, its
        // being on screen where the person is looking is the pass;
        // expecting it behind, there is nothing to judge.
        switch options.expect {
        case .behind:
            verdict = .skip
            skipReason = "pad-is-frontmost"
        case .above: verdict = card == nil ? .fail : .pass
        }
    } else if let target {
        switch options.expect {
        case .behind:
            if let card { verdict = card.index > target.index ? .pass : .fail } else { verdict = .pass }
        case .above:
            if let card { verdict = card.index < target.index ? .pass : .fail } else { verdict = .fail }
        }
    } else {
        verdict = .skip
        skipReason = "no-target-window"
    }
    let cardText = card.map { String($0.index) } ?? "absent"
    let targetText = target.map { String($0.index) } ?? "none"
    let padText =
        pads.isEmpty ? "not-running" : pads.sorted().map(String.init).joined(separator: ",")
    let reasonText = skipReason.map { " reason=\($0)" } ?? ""
    print(
        "VERDICT \(verdict.rawValue) expect=\(options.expect.rawValue) card=\(cardText) target=\(targetText) pad=\(padText)\(reasonText) front=\(frontName)"
    )
    return verdict
}

// MARK: Main

let options = parseOptions()
setvbuf(stdout, nil, _IOLBF, 0)

if options.watch {
    sample(options, reason: "start")
    let settle: TimeInterval = 1.5
    let centre = NSWorkspace.shared.notificationCenter
    let watched: [(Notification.Name, String)] = [
        (NSWorkspace.didActivateApplicationNotification, "activate"),
        (NSWorkspace.activeSpaceDidChangeNotification, "space"),
    ]
    var tokens: [NSObjectProtocol] = []
    for (name, reason) in watched {
        tokens.append(
            centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    sample(options, reason: reason)
                }
            }
        )
    }
    // Held for the life of the process; the run loop below never returns.
    withExtendedLifetime(tokens) {
        RunLoop.main.run()
    }
} else if let after = options.after {
    // The run loop is turned for the wait, not slept through: the
    // workspace's frontmost app and running apps are refreshed from it,
    // and a sample taken after a plain sleep would describe the moment
    // the probe started.
    print("WAITING \(after) s, then one sample")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: after))
    exit(sample(options, reason: "after") == .fail ? 1 : 0)
} else {
    exit(sample(options, reason: "once") == .fail ? 1 : 0)
}
