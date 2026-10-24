import AppKit
import ApplicationServices

struct AXNode: Codable {
    let path: String
    let role: String
    let label: String
    let identifier: String
    let attributes: [String]
    let parameterizedAttributes: [String]
    let actions: [String]
    let childrenError: Int32
    let actionsError: Int32
    let position: String
    let size: String
}
struct PressResult: Codable {
    let identifier: String
    let attempt: Int
    let result: Int32
}
struct AXReport: Codable {
    let trustedWithoutPrompt: Bool
    let targetPID: Int32
    let windowsError: Int32
    let nodes: [AXNode]
    let presses: [PressResult]
    let truncated: Bool
    let deniedPressError: Int32?
    let inspectionOnly: Bool
}
let args = CommandLine.arguments
if args.count < 3 { fputs("usage: AXClient PID OUTPUT.json [--inspect-only]\n", stderr); exit(2) }
let inspectionOnly = args.contains("--inspect-only")
let pid = Int32(args[1])!
let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root, 1)
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}
func string(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name).map { String(describing: $0) } ?? ""
}
var windows: CFTypeRef?
let windowsError = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
var nodes: [AXNode] = []
var targets: [String: AXUIElement] = [:]
var seen: [AXUIElement] = []
var truncated = false
func visit(_ element: AXUIElement, _ path: String, _ depth: Int) {
    if seen.contains(where: { CFEqual($0, element) }) { return }
    if depth > 14 || nodes.count >= 400 { truncated = true; return }
    seen.append(element)
    var attrs: CFArray?, actions: CFArray?, params: CFArray?, children: CFTypeRef?
    AXUIElementCopyAttributeNames(element, &attrs)
    AXUIElementCopyParameterizedAttributeNames(element, &params)
    let actionError = AXUIElementCopyActionNames(element, &actions)
    let childError = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    let identifier = string(element, kAXIdentifierAttribute)
    let label = [string(element, "AXLabel"), string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute)]
        .filter { !$0.isEmpty }.joined(separator: " | ")
    nodes.append(AXNode(path: path, role: string(element, kAXRoleAttribute), label: label, identifier: identifier,
                        attributes: attrs as? [String] ?? [], parameterizedAttributes: params as? [String] ?? [],
                        actions: actions as? [String] ?? [], childrenError: childError.rawValue, actionsError: actionError.rawValue,
                        position: string(element, kAXPositionAttribute), size: string(element, kAXSizeAttribute)))
    if !identifier.isEmpty { targets[identifier] = element }
    for (index, child) in (children as? [AXUIElement] ?? []).enumerated() { visit(child, path + "/\(index)", depth + 1) }
}
visit(root, "app", 0)
let deniedPressError: Int32? = windowsError == .apiDisabled
    ? AXUIElementPerformAction(root, kAXPressAction as CFString).rawValue : nil
var presses: [PressResult] = []
for (identifier, count) in [("action-custom-quiet-plain", 2), ("action-custom-selected-linked", 1),
                             ("action-custom-selected-table-image", 1), ("action-custom-selected-alt-sealed", 1)] {
    guard !inspectionOnly, let element = targets[identifier] else { continue }
    for attempt in 1...count {
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        presses.append(PressResult(identifier: identifier, attempt: attempt, result: error.rawValue))
        Thread.sleep(forTimeInterval: 0.15)
    }
}
if !inspectionOnly, let node = nodes.first(where: { $0.path.hasPrefix("app/") && $0.label == "Cell press probe" && $0.actions.contains("AXPress") }),
   let index = nodes.firstIndex(where: { $0.path == node.path }), seen.indices.contains(index) {
    let error = AXUIElementPerformAction(seen[index], kAXPressAction as CFString)
    presses.append(PressResult(identifier: "native-cell-press-proxy", attempt: 1, result: error.rawValue))
}
let report = AXReport(trustedWithoutPrompt: AXIsProcessTrusted(), targetPID: pid,
                      windowsError: windowsError.rawValue, nodes: nodes, presses: presses, truncated: truncated,
                      deniedPressError: deniedPressError, inspectionOnly: inspectionOnly)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: URL(fileURLWithPath: args[2]))
print("AX trusted=\(report.trustedWithoutPrompt); windows error=\(report.windowsError); nodes=\(nodes.count); performed=\(presses.count)")
exit(windowsError == .success ? 0 : 3)
