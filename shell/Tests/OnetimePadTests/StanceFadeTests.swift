import AppKit
import SwiftUI
import XCTest

@testable import OnetimePad

@MainActor
final class StanceFadeTests: XCTestCase {
    private static let fade = Animation.easeInOut(duration: 0.16)

    private final class Transactions {
        /// Whether each native update below the boundary carried an
        /// animation.
        var updates: [Bool] = []
        #if DEBUG
        /// The animation each pass of the fade's own transaction carried,
        /// as the probe above the boundary saw it.
        var fades: [Animation?] = []
        #endif
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
                .modifier(Self.stanceFade(raised: raised, transactions: transactions))
        }

        private static func stanceFade(
            raised: Bool, transactions: Transactions
        ) -> StanceFadeModifier {
            #if DEBUG
            return StanceFadeModifier(
                raised: raised,
                animation: StanceFadeTests.fade,
                fadeProbe: { transactions.fades.append($0.animation) }
            )
            #else
            return StanceFadeModifier(raised: raised, animation: StanceFadeTests.fade)
            #endif
        }
    }

    /// Hosts the harness at rest, then raises it and lets the update
    /// land, by order and never by the clock (`drainMainQueue`). Only
    /// the transactions of the raise are kept.
    private func raise(_ transactions: Transactions) {
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
        #if DEBUG
        transactions.fades.removeAll()
        #endif
        host.rootView = Harness(raised: true, transactions: transactions)
        host.layoutSubtreeIfNeeded()
        drainMainQueue()
    }

    func testStanceFadeDoesNotAnimateEmbeddedNativeContent() {
        let transactions = Transactions()
        raise(transactions)

        XCTAssertFalse(
            transactions.updates.isEmpty,
            "the stance change never reached native content"
        )
        XCTAssertFalse(
            transactions.updates.contains(true),
            "the opacity fade leaked its animation transaction into native page content"
        )
    }

    #if DEBUG
    /// The other half of the rule: the boundary must clear the fade for
    /// what lies under it, not remove the fade itself. Dropping the
    /// animation modifier, or clearing the transaction above the
    /// opacity, would pass the test above and fail this one.
    func testStanceFadeAnimatesOpacityAboveTheBoundary() {
        let transactions = Transactions()
        raise(transactions)

        XCTAssertFalse(
            transactions.fades.isEmpty,
            "the stance change never reached the fade's transaction"
        )
        XCTAssertTrue(
            transactions.fades.contains(Self.fade),
            "the stance change reached the fade without its 160 ms animation"
        )
    }
    #endif
}
