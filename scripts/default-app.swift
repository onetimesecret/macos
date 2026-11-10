// default-app.swift
//
// Shows or sets the default application for the file kinds OnetimePad
// declares in shell/OnetimePad-Info.plist: plain text, Markdown, logs and
// dotenv files. macOS keeps the choice per user; the app never makes it.
//
//   swift scripts/default-app.swift
//       Print the current default application for each kind.
//   swift scripts/default-app.swift --set [APP]
//       Make APP the default for each kind. APP defaults to
//       /Applications/OnetimePad Local.app, the bundle scripts/install.sh
//       installs. Plain text is the type of .txt and the fallback for
//       every text file whose own type has no default.
//   swift scripts/default-app.swift --type-of FILE...
//       Print the content type macOS gives each file, which decides
//       whether any of the above applies to it.

import AppKit
import UniformTypeIdentifiers

let kinds: [(name: String, identifier: String)] = [
    ("plain text (.txt)", "public.plain-text"),
    ("Markdown (.md)", "net.daringfireball.markdown"),
    ("log (.log)", "com.apple.log"),
    ("dotenv (.env, .envrc)", "com.onetimesecret.pad.dotenv"),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func show() {
    for kind in kinds {
        guard let type = UTType(kind.identifier) else {
            print("\(kind.name): \(kind.identifier) is not registered; launch OnetimePad once")
            continue
        }
        let app = NSWorkspace.shared.urlForApplication(toOpen: type)?.path ?? "none"
        print("\(kind.name): \(app)")
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.isEmpty ? "--show" : arguments.removeFirst()

switch mode {
case "--show":
    show()
case "--type-of":
    guard !arguments.isEmpty else { fail("--type-of takes one or more file paths") }
    for path in arguments {
        let url = URL(fileURLWithPath: path)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)?.path ?? "none"
        print("\(path): \(type?.identifier ?? "unreadable"), opens in \(app)")
    }
case "--set":
    let app = URL(fileURLWithPath: arguments.first ?? "/Applications/OnetimePad Local.app")
    guard Bundle(url: app)?.bundleIdentifier != nil else { fail("\(app.path) is not an application bundle") }
    var refused = false
    for kind in kinds {
        guard let type = UTType(kind.identifier) else {
            print("\(kind.name): \(kind.identifier) is not registered; launch OnetimePad once and run this again")
            refused = true
            continue
        }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
        } catch {
            print("\(kind.name): refused, \(error.localizedDescription)")
            refused = true
        }
    }
    show()
    exit(refused ? 1 : 0)
default:
    fail("usage: swift scripts/default-app.swift [--show | --set [APP] | --type-of FILE...]")
}
