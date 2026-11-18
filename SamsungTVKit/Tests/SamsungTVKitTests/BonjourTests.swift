import Foundation
import Testing
@testable import SamsungTVKit

@Test(arguments: [["manufacturer": "Samsung", "model": "X1"], ["manufacturer": "samsung"], ["manufacturer": "SAMSUNG", "integrator": "Samsung"]])
func samsungTXTAccepted(txt: [String: String]) {
    #expect(BonjourTXT.isSamsung(txt))
}

@Test(arguments: [["manufacturer": "Sonos, Inc."], ["manufacturer": "Apple Inc."], ["model": "Samsung"], [:]])
func nonSamsungTXTRejected(txt: [String: String]) {
    #expect(!BonjourTXT.isSamsung(txt))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TVKIT_LIVE"] == "1"))
func liveBonjourBrowse() async {
    var count = 0
    for await _ in BonjourSamsungBrowser(duration: .seconds(4)).candidates() { count += 1 }
    print("Bonjour live: found \(count) host(s)")
}
