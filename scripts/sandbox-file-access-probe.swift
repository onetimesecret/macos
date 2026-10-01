// sandbox-file-access-probe.swift
//
// The evidence for ADR-0035: what a sandboxed process may do to a file
// a person handed it, and what it may not. It is a tiny app with no
// window. It is handed files through LaunchServices, which is how a
// sandboxed app receives a grant without a panel, tries each POSIX call
// the core's file IO makes, and appends one line per attempt to a log
// file it was handed the same way.
//
// It is not part of OnetimePad and links none of it. The calls below
// are the ones `crates/ffi/src/files.rs` makes (stat, realpath, open
// for read, create-new of a temp file, rename onto the target) and the
// ones `shell/Sources/CompanionKit/FileCoordinator.swift` makes (make a
// bookmark, resolve it, start and stop the scope, ask for the item
// replacement directory), so a line here answers a question about a
// line there.
//
// Run it through scripts/sandbox-file-access-probe.sh, which builds the
// bundle, signs it ad hoc with the entitlements under test, launches it
// three times and prints the log. The app cannot be run usefully by
// hand from a shell: a file named on the command line carries no grant.
//
// Launches, told apart by what the app is handed:
//
//   A document and log.txt   Phase 1. The document arrives with a grant.
//                            Every call is tried on it, then a security
//                            scoped bookmark and a plain bookmark are
//                            made and stored in a directory of the
//                            app's own under Application Support,
//                            with the path beside them.
//   log.txt alone            Phase 2. A relaunch with no grant on the
//                            document. The bare path is tried, then
//                            each stored bookmark is resolved with and
//                            without `.withSecurityScope`. Inside the
//                            scoped resolution every call is tried
//                            again and the scoped bookmark is made
//                            again and stored.
//
// The runner launches phase 2 twice, moving the document in between, so
// the second pass shows which bookmark still finds the file after a
// staged write replaced its inode and a move changed its path.
//
// Reading the log. Each line is `[tag] what: ok ...` or
// `[tag] what: FAIL errno=N text`. The tags are `granted` in phase 1,
// `bare old path` for the unscoped path in phase 2, and one per
// bookmark and resolution option: `plain/[]`, `plain/scope`,
// `scoped/[]`, `scoped/scope`.
//
// Three cautions when reading it. The four resolutions in phase 2 share
// one process and run in the order above, so in the first relaunch a
// read that `plain/[]` was allowed is still allowed when the later tags
// try theirs: only the second relaunch, after the move, shows a scope
// opening and closing access by itself. In that second relaunch the
// control lines say the neighbour is not found, which is the move and
// not the sandbox, because other.txt stayed behind. And
// `startAccessing=true` is only what the call answered; the read lines
// around it say whether anything was granted.
//
// Two things differ from the source that produced the first
// measurements for ADR-0035: `stat` lines also print the group id, and
// an append to the document in place is tried before the temp files
// are. The second means the document's size in the log will not match
// those older logs. This form was built and run in all four variants on
// 2026-09-30, on macOS 27.0.
//
// What it cannot measure: a URL from NSOpenPanel or NSSavePanel, a
// rename onto a save panel destination that does not exist yet, a
// drop, a reboot, and a Developer ID or App Store signature. Those are
// in docs/qa/verification-procedures/sandbox-file-access.md.

import AppKit
import Foundation

var lines: [String] = []
func log(_ s: String) { lines.append(s) }
func errnoName() -> String { "errno=\(errno) \(String(cString: strerror(errno)))" }

// MARK: The POSIX calls the core makes

func posixStat(_ p: String) -> String {
    var st = stat()
    return stat(p, &st) == 0
        ? "ok ino=\(st.st_ino) size=\(st.st_size) gid=\(st.st_gid)" : "FAIL \(errnoName())"
}

func posixRealpath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return "FAIL \(errnoName())" }
    defer { free(r) }
    return "ok \(String(cString: r))"
}

func posixRead(_ p: String) -> String {
    let fd = open(p, O_RDONLY | O_NONBLOCK)
    guard fd >= 0 else { return "FAIL \(errnoName())" }
    defer { close(fd) }
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(fd, &buf, 64)
    return n >= 0 ? "ok \(n) bytes" : "FAIL read \(errnoName())"
}

func posixAppend(_ p: String, _ text: String) -> String {
    let fd = open(p, O_WRONLY | O_APPEND)
    guard fd >= 0 else { return "FAIL \(errnoName())" }
    defer { close(fd) }
    let n = text.withCString { write(fd, $0, strlen($0)) }
    return n >= 0 ? "ok" : "FAIL write \(errnoName())"
}

func posixCreateExcl(_ p: String, _ text: String) -> String {
    let fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    guard fd >= 0 else { return "FAIL \(errnoName())" }
    defer { close(fd) }
    let n = text.withCString { write(fd, $0, strlen($0)) }
    fsync(fd)
    return n >= 0 ? "ok" : "FAIL write \(errnoName())"
}

func posixRename(_ a: String, _ b: String) -> String {
    rename(a, b) == 0 ? "ok" : "FAIL \(errnoName())"
}

func posixOpenDir(_ p: String) -> String {
    let fd = open(p, O_RDONLY)
    guard fd >= 0 else { return "FAIL \(errnoName())" }
    close(fd)
    return "ok"
}

// MARK: Every call, on one file

/// Try each call on `url` and on its neighbours. `other.txt` beside it
/// is the control: a file in the same directory that nobody granted.
func exercise(_ url: URL, tag: String) {
    let p = url.path
    let dir = url.deletingLastPathComponent().path
    log("[\(tag)] stat: \(posixStat(p))")
    log("[\(tag)] realpath: \(posixRealpath(p))")
    log("[\(tag)] read: \(posixRead(p))")
    log("[\(tag)] append in place: \(posixAppend(p, "appended \(tag)\n"))")
    log("[\(tag)] control read sibling other.txt: \(posixRead(dir + "/other.txt"))")
    log("[\(tag)] control stat sibling other.txt: \(posixStat(dir + "/other.txt"))")
    log("[\(tag)] stat missing sibling: \(posixStat(dir + "/nope.txt"))")
    log("[\(tag)] stat parent dir: \(posixStat(dir))")
    log("[\(tag)] open parent dir: \(posixOpenDir(dir))")

    // The temp file beside the target, in the name shape the core uses.
    let sib = p + ".0123456789abcdef.tmp"
    let sibResult = posixCreateExcl(sib, "sibling \(tag)\n")
    log("[\(tag)] sibling temp create: \(sibResult)")
    if sibResult == "ok" {
        log("[\(tag)] sibling rename onto target: \(posixRename(sib, p))")
    }

    // The temp file in the item replacement directory, renamed onto the
    // target. The stat afterwards shows the new inode and its group.
    do {
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        log("[\(tag)] itemReplacementDirectory: \(staging.path)")
        let tmp = staging.path + "/staged.tmp"
        log("[\(tag)] staged create: \(posixCreateExcl(tmp, "staged \(tag) \(Date())\n"))")
        log("[\(tag)] staged rename onto target: \(posixRename(tmp, p))")
        try? FileManager.default.removeItem(at: staging)
    } catch {
        log("[\(tag)] itemReplacementDirectory FAIL \(error)")
    }
    log("[\(tag)] stat after: \(posixStat(p))")
    log("[\(tag)] read after: \(posixRead(p))")

    // A new file beside the target that nobody granted. The tag can
    // hold a slash, which would make this a path into a directory that
    // is not there and report the wrong error.
    let safeTag = tag.replacingOccurrences(of: "/", with: "-")
    log("[\(tag)] create ungranted new sibling: \(posixCreateExcl(dir + "/new-\(safeTag).txt", "x"))")
}

// MARK: The two phases

final class Delegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // A directory of the probe's own. Under the sandbox Application
        // Support is already inside the container, but the unsandboxed
        // variant gets the person's real one, and three loose files in
        // its root would be litter nobody could trace back to here.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.onetimesecret.sandboxprobe")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let scopedFile = support.appendingPathComponent("scoped.bookmark")
        let plainFile = support.appendingPathComponent("plain.bookmark")
        let pathFile = support.appendingPathComponent("path.txt")
        log("home: \(NSHomeDirectory())")
        log("sandbox container env: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "nil")")
        guard let logURL = urls.first(where: { $0.lastPathComponent == "log.txt" }) else { exit(2) }
        let target = urls.first(where: { $0.lastPathComponent != "log.txt" })
        if let target {
            log("== phase 1: opened \(target.path)")
            exercise(target, tag: "granted")
            do {
                let d = try target.bookmarkData(
                    options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                try d.write(to: scopedFile)
                log("scoped bookmark create: ok \(d.count) bytes")
            } catch { log("scoped bookmark create: FAIL \(error)") }
            do {
                let d = try target.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                try d.write(to: plainFile)
                log("plain bookmark create: ok \(d.count) bytes")
            } catch { log("plain bookmark create: FAIL \(error)") }
            try? target.path.write(to: pathFile, atomically: true, encoding: .utf8)
        } else {
            log("== phase 2: relaunch, no target url")
            let old = (try? String(contentsOf: pathFile, encoding: .utf8)) ?? ""
            log("[bare old path] stat: \(posixStat(old))")
            log("[bare old path] read: \(posixRead(old))")
            for (name, file, opts) in [
                ("plain/[]", plainFile, URL.BookmarkResolutionOptions([])),
                ("plain/scope", plainFile, [.withSecurityScope]),
                ("scoped/[]", scopedFile, []),
                ("scoped/scope", scopedFile, [.withSecurityScope]),
            ] {
                guard let data = try? Data(contentsOf: file) else { log("[\(name)] no bookmark data"); continue }
                var stale = false
                do {
                    let url = try URL(
                        resolvingBookmarkData: data, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale)
                    log("[\(name)] resolved \(url.path) stale=\(stale)")
                    log("[\(name)] before start: read \(posixRead(url.path))")
                    let started = url.startAccessingSecurityScopedResource()
                    log("[\(name)] startAccessing=\(started)")
                    if name == "scoped/scope" {
                        exercise(url, tag: name)
                        // Made again after the staged write above
                        // replaced the file, and stored, so the next
                        // pass resolves a bookmark that was taken from
                        // the new inode.
                        do {
                            let d = try url.bookmarkData(
                                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                            try d.write(to: scopedFile)
                            try url.path.write(to: pathFile, atomically: true, encoding: .utf8)
                            log("[\(name)] re-bookmark inside scope: ok \(d.count), stored")
                        } catch { log("[\(name)] re-bookmark inside scope: FAIL \(error)") }
                    } else {
                        log("[\(name)] read \(posixRead(url.path))")
                    }
                    if started { url.stopAccessingSecurityScopedResource() }
                    log("[\(name)] after stop: read \(posixRead(url.path))")
                } catch { log("[\(name)] resolve FAIL \(error)") }
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(text.data(using: .utf8)!)
            try? h.close()
        }
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
