import Testing
@testable import SamsungTVKit

@Test(arguments: [
    ("10.0.0.1", true), ("172.31.255.1", true), ("172.16.0.1", true), ("172.32.0.1", false),
    ("172.15.0.1", false), ("192.168.0.9", true), ("8.8.8.8", false), ("169.254.3.3", true),
    ("tv.local", false), ("192.168.1.300", false), ("", false), ("+10.0.0.1", false),
    (" 10.0.0.1", false), ("10.0.0.1 ", false), ("10.0.0", false), ("10.0.0.1.1", false),
    ("::1", false), ("fe80::1", false), ("10.0.0.", false), ("127.0.0.1", false),
    ("010.0.0.1", false), ("172.016.0.1", false), ("192.168.01.1", false), ("10.0.0.0", true),
])
func isAllowedTable(host: String, expected: Bool) {
    #expect(LocalAddress.isAllowed(host) == expected)
}

@Test func loopbackOnlyWhenAllowed() {
    #expect(LocalAddress.isAllowed("127.0.0.1", allowLoopback: true))
    #expect(!LocalAddress.isAllowed("127.0.0.1", allowLoopback: false))
    #expect(!LocalAddress.isAllowed("8.8.8.8", allowLoopback: true))
}
