import XCTest
@testable import LagoonServer

/// One-click unsubscribe discovery: header parsing, body heuristics, and the
/// SSRF guard. The guard is the trust boundary — body URLs come from
/// attacker-controlled email, so a regression there is a server-side
/// request-forgery hole, not a UX bug.
final class UnsubscribeScannerTests: XCTestCase {

    // MARK: - Header

    func test_headerLinks_standardAngleBracketForm() {
        let raw = "<https://list.example.com/u?id=9>, <mailto:bye@example.com>"
        XCTAssertEqual(
            UnsubscribeScanner.headerLinks(raw),
            ["https://list.example.com/u?id=9", "mailto:bye@example.com"]
        )
    }

    func test_headerLinks_bareURLWithoutBrackets() {
        let raw = "https://example.org/unsubscribe?u=42"
        XCTAssertEqual(UnsubscribeScanner.headerLinks(raw), ["https://example.org/unsubscribe?u=42"])
    }

    func test_headerLinks_unfoldsHeaderAndDropsJunkSchemes() {
        let raw = "<tel:+1000>,\r\n <https://a.example/x>"
        XCTAssertEqual(UnsubscribeScanner.headerLinks(raw), ["https://a.example/x"])
    }

    // MARK: - Body

    func test_bodyLinks_anchorTextKeywordWins() {
        let html = #"<a href="https://ex.com/prefs">Unsubscribe</a>"#
        XCTAssertEqual(UnsubscribeScanner.bodyLinks(in: html), ["https://ex.com/prefs"])
    }

    func test_bodyLinks_hrefKeywordWithBoringText() {
        let html = #"<a href="https://ex.com/u/unsubscribe?id=7">change settings</a>"#
        XCTAssertEqual(UnsubscribeScanner.bodyLinks(in: html), ["https://ex.com/u/unsubscribe?id=7"])
    }

    func test_bodyLinks_chineseAnchor() {
        let html = #"<a href="https://ex.cn/quit">点此退订</a>"#
        XCTAssertEqual(UnsubscribeScanner.bodyLinks(in: html), ["https://ex.cn/quit"])
    }

    func test_bodyLinks_decodesHTMLEntitiesInHref() {
        let html = #"<a href="https://ex.com/a?x=1&amp;y=2">unsubscribe</a>"#
        XCTAssertEqual(UnsubscribeScanner.bodyLinks(in: html), ["https://ex.com/a?x=1&y=2"])
    }

    func test_bodyLinks_bareURLNearKeywordSentence() {
        let html = "<p>To stop these emails, unsubscribe at https://ex.com/takemeaway now.</p>"
        XCTAssertEqual(UnsubscribeScanner.bodyLinks(in: html), ["https://ex.com/takemeaway"])
    }

    func test_bodyLinks_ignoresUnrelatedLinksAndRelatives() {
        let html = """
        <a href="/about">About us</a>
        <a href="https://ex.com/article">Read more</a>
        <a href="mailto:x@y.z">Mail us</a>
        """
        XCTAssertEqual(UnsubscribeScanner.bodyLinks(in: html), [])
    }

    func test_bodyLinks_prefersTextMatchedAnchorsOverBareOnes() {
        let html = """
        <p>See https://ex.com/blog for news.</p>
        <a href="https://ex.com/unsub-me">unsubscribe here</a>
        """
        XCTAssertEqual(
            UnsubscribeScanner.bodyLinks(in: html),
            ["https://ex.com/unsub-me", "https://ex.com/blog"]
        )
    }

    // MARK: - SSRF guard

    func test_isSafe_rejectsNonHTTPSchemes() async {
        for raw in ["ftp://ex.com/u", "file:///etc/passwd", "mailto:a@b.c", "javascript:alert(1)"] {
            guard let url = URL(string: raw) else { continue }
            let safe = await UnsubscribeScanner.isSafe(url: url)
            XCTAssertFalse(safe, "\(raw) must never be fetched")
        }
    }

    func test_isSafe_rejectsLoopbackPrivateLinkLocalAndMetadata() async {
        let hosts = [
            "127.0.0.1", "10.1.2.3", "172.16.5.5", "192.168.0.1",
            "169.254.169.254", // cloud metadata
            "100.64.0.1", // CGNAT
            "[::1]", "[fe80::1]", "[fc00::1]", "[::ffff:127.0.0.1]",
        ]
        for host in hosts {
            guard let url = URL(string: "http://\(host)/u") else {
                XCTFail("bad test url for \(host)")
                continue
            }
            let safe = await UnsubscribeScanner.isSafe(url: url)
            XCTAssertFalse(safe, "\(host) must be rejected")
        }
    }

    func test_isSafe_rejectsLocalhostNames() async {
        for raw in ["http://localhost/u", "http://printer.local/u", "http://foo.localhost/u"] {
            guard let url = URL(string: raw) else { continue }
            let safe = await UnsubscribeScanner.isSafe(url: url)
            XCTAssertFalse(safe, "\(raw) must be rejected")
        }
    }

    func test_isSafe_acceptsPublicLiteralIPs() async {
        for raw in ["http://8.8.8.8/u", "https://1.1.1.1/u"] {
            guard let url = URL(string: raw) else {
                XCTFail("bad test url \(raw)")
                continue
            }
            let safe = await UnsubscribeScanner.isSafe(url: url)
            XCTAssertTrue(safe, "\(raw) should pass")
        }
    }

    // MARK: - Classification units

    func test_publicAddress_boundaries() {
        XCTAssertTrue(UnsubscribeScanner.isPublicAddress([1, 1, 1, 1]))
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress([0, 0, 0, 0]))
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress([255, 255, 255, 255]))
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress([224, 0, 0, 1])) // multicast
        var v6 = [UInt8](repeating: 0, count: 16)
        v6[15] = 1
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress(v6)) // ::1
    }

    func test_publicAddress_rejectsSpecialPurposeRanges() {
        // IPv4: RFC 6890 special-purpose blocks
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress([192, 0, 0, 1]))
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress([192, 0, 2, 1])) // TEST-NET-1
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress([198, 18, 0, 1])) // benchmarking
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress([198, 51, 100, 7])) // TEST-NET-2
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress([203, 0, 113, 9])) // TEST-NET-3

        // IPv6: embedding prefixes can smuggle an inner v4 target.
        var nat64 = [UInt8](repeating: 0, count: 16)
        nat64[1] = 0x64; nat64[2] = 0xff; nat64[3] = 0x9b
        nat64[12] = 0x7f; nat64[15] = 1 // 64:ff9b::7f00:1 embeds 127.0.0.1
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress(nat64))
        var doc = [UInt8](repeating: 0, count: 16)
        doc[0] = 0x20; doc[1] = 0x01; doc[2] = 0x0d; doc[3] = 0xb8 // 2001:db8::
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress(doc))
        var sixtofour = [UInt8](repeating: 0, count: 16)
        sixtofour[0] = 0x20; sixtofour[1] = 0x02 // 2002:: embeds v4
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress(sixtofour))
        var site = [UInt8](repeating: 0, count: 16)
        site[0] = 0xfe; site[1] = 0xc0 // fec0::/10 site-local
        XCTAssertFalse(UnsubscribeScanner.isPublicAddress(site))

        // Sanity: real public addresses still pass.
        XCTAssertTrue(UnsubscribeScanner.isPublicAddress([8, 8, 8, 8]))
        var cloudflare = [UInt8](repeating: 0, count: 16)
        cloudflare[0] = 0x26; cloudflare[1] = 0x06; cloudflare[3] = 0x11 // 2606:4700::
        XCTAssertTrue(UnsubscribeScanner.isPublicAddress(cloudflare))
    }
}
