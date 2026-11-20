import SwiftUI
import Testing
import UIKit
@testable import FreeRemote

@MainActor
@Suite struct StatusLineTests {
    private static let catalog: [StatusLine] = [
        .turningOn, .turningOff, .reconnecting, .connecting(to: nil), .connected(to: nil), .tvOff, .unreachable,
        .notTurnedOn, .wakeAddressUnknown, .notOnWiFi, .approvalTimedOut, .chooseTVFirst, .chooseAllow,
        .blocked, .identityChanged,
    ]

    @Test func titlesAreShortAndExplanationsLiveInDetail() {
        for line in Self.catalog {
            #expect(line.title.count <= 30, "\(line.title)")
            if let detail = line.detail { #expect(detail.count > line.title.count, "\(line.title)") }
        }
        #expect(StatusLine.notTurnedOn.detail?.contains("Power On with Mobile") == true)
        #expect(StatusLine.connecting(to: "Den") == StatusLine("Connecting to Den…", tone: .progress))
    }

    /// The point of the fixed-height line: the remote below must not move, whatever is (or isn't) shown.
    @Test(arguments: [DynamicTypeSize.large, .accessibility3])
    func everyStatusTakesTheSameHeight(size: DynamicTypeSize) {
        func height(_ line: StatusLine?) -> CGFloat {
            let host = UIHostingController(rootView: StatusView(line).environment(\.dynamicTypeSize, size))
            return host.sizeThatFits(in: CGSize(width: 354, height: CGFloat.infinity)).height
        }
        let empty = height(nil)
        #expect(empty > 0)
        for line in Self.catalog + [.connecting(to: "A Very Long Living Room Television Name")] {
            #expect(abs(height(line) - empty) < 0.5, "\(line.title) at \(size)")
        }
    }
}
