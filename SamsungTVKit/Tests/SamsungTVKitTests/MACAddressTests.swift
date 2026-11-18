import Testing
@testable import SamsungTVKit

@Test func macParsing() {
    #expect(MACAddress("02:00:00:0a:0b:0c")?.bytes.count == 6)
    #expect(MACAddress("02:00:00:0a:0b:0c")?.description == "02:00:00:0A:0B:0C")
    #expect(MACAddress("nope") == nil)
    #expect(MACAddress("") == nil)
    #expect(MACAddress("02:00:00:0a:0b") == nil)
    #expect(MACAddress("02:00:00:0a:0b:zz") == nil)
}
