import Testing
@testable import SamsungTVKit

@Test(arguments: [("85&quot; A", "85\" A"), ("A &amp; B", "A & B"), ("&#39;x&#39;", "'x'"), ("&lt;&gt;", "<>"), ("plain", "plain"), ("&bogus;", "&bogus;")])
func entities(input: String, expected: String) {
    #expect(HTMLEntities.decode(input) == expected)
}
