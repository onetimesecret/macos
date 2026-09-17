import AppKit
import SwiftUI
import XCTest

@testable import OnetimePad

@MainActor
final class StanceFadeTests: XCTestCase {
    private final class Transactions {
        var updates: [Bool] = []
    }

    private struct NativeContent: NSViewRepresentable {
        let raised: Bool
        let transactions: Transactions

        func makeNSView(context: Context) -> NSView {
            NSView()
        }

        func updateNSView(_ view: NSView, context: Context) {
            transactions.updates.append(context.transaction.animation != nil)
        }
    }

    private struct Harness: View {
        let raised: Bool
        let transactions: Transactions

        var body: some View {
            NativeContent(raised: raised, transactions: transactions)
                .stanceFaded(
                    raised: raised,
                    animation: .easeInOut(duration: 0.16)
                )
        }
    }

    func testStanceFadeDoesNotAnimateEmbeddedNativeContent() {
        let transactions = Transactions()
        let host = NSHostingView(rootView: Harness(
            raised: false, transactions: transactions
        ))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        transactions.updates.removeAll()
        host.rootView = Harness(raised: true, transactions: transactions)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

        XCTAssertFalse(
            transactions.updates.isEmpty,
            "the stance change never reached native content"
        )
        XCTAssertFalse(
            transactions.updates.contains(true),
            "the opacity fade leaked its animation transaction into native page content"
        )
    }
}
