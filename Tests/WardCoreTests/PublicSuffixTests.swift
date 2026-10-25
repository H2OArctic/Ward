import XCTest
@testable import WardCore

final class PublicSuffixTests: XCTestCase {
    /// Официальные векторы https://github.com/publicsuffix/list/blob/main/tests/test_psl.txt
    /// (как у них: вход приводится к нижнему регистру и punycode, ответ сравнивается в той же форме).
    static let vectors: [(String, String?)] = [
        ("COM", nil),
        ("example.COM", "example.com"),
        ("WwW.example.COM", "example.com"),
        (".com", nil),
        (".example", nil),
        (".example.com", nil),
        (".example.example", nil),
        ("example", nil),
        ("example.example", "example.example"),
        ("b.example.example", "example.example"),
        ("a.b.example.example", "example.example"),
        ("biz", nil),
        ("domain.biz", "domain.biz"),
        ("b.domain.biz", "domain.biz"),
        ("a.b.domain.biz", "domain.biz"),
        ("com", nil),
        ("example.com", "example.com"),
        ("b.example.com", "example.com"),
        ("a.b.example.com", "example.com"),
        ("uk.com", nil),
        ("example.uk.com", "example.uk.com"),
        ("b.example.uk.com", "example.uk.com"),
        ("a.b.example.uk.com", "example.uk.com"),
        ("test.ac", "test.ac"),
        ("mm", nil),
        ("c.mm", nil),
        ("b.c.mm", "b.c.mm"),
        ("a.b.c.mm", "b.c.mm"),
        ("jp", nil),
        ("test.jp", "test.jp"),
        ("www.test.jp", "test.jp"),
        ("ac.jp", nil),
        ("test.ac.jp", "test.ac.jp"),
        ("www.test.ac.jp", "test.ac.jp"),
        ("kyoto.jp", nil),
        ("test.kyoto.jp", "test.kyoto.jp"),
        ("ide.kyoto.jp", nil),
        ("b.ide.kyoto.jp", "b.ide.kyoto.jp"),
        ("a.b.ide.kyoto.jp", "b.ide.kyoto.jp"),
        ("c.kobe.jp", nil),
        ("b.c.kobe.jp", "b.c.kobe.jp"),
        ("a.b.c.kobe.jp", "b.c.kobe.jp"),
        ("city.kobe.jp", "city.kobe.jp"),
        ("www.city.kobe.jp", "city.kobe.jp"),
        ("ck", nil),
        ("test.ck", nil),
        ("b.test.ck", "b.test.ck"),
        ("a.b.test.ck", "b.test.ck"),
        ("www.ck", "www.ck"),
        ("www.www.ck", "www.ck"),
        ("us", nil),
        ("test.us", "test.us"),
        ("www.test.us", "test.us"),
        ("ak.us", nil),
        ("test.ak.us", "test.ak.us"),
        ("www.test.ak.us", "test.ak.us"),
        ("k12.ak.us", nil),
        ("test.k12.ak.us", "test.k12.ak.us"),
        ("www.test.k12.ak.us", "test.k12.ak.us"),
        ("食狮.com.cn", "食狮.com.cn"),
        ("食狮.公司.cn", "食狮.公司.cn"),
        ("www.食狮.公司.cn", "食狮.公司.cn"),
        ("shishi.公司.cn", "shishi.公司.cn"),
        ("公司.cn", nil),
        ("食狮.中国", "食狮.中国"),
        ("www.食狮.中国", "食狮.中国"),
        ("shishi.中国", "shishi.中国"),
        ("中国", nil),
        ("xn--85x722f.com.cn", "xn--85x722f.com.cn"),
        ("xn--85x722f.xn--55qx5d.cn", "xn--85x722f.xn--55qx5d.cn"),
        ("www.xn--85x722f.xn--55qx5d.cn", "xn--85x722f.xn--55qx5d.cn"),
        ("shishi.xn--55qx5d.cn", "shishi.xn--55qx5d.cn"),
        ("xn--55qx5d.cn", nil),
        ("xn--85x722f.xn--fiqs8s", "xn--85x722f.xn--fiqs8s"),
        ("www.xn--85x722f.xn--fiqs8s", "xn--85x722f.xn--fiqs8s"),
        ("shishi.xn--fiqs8s", "shishi.xn--fiqs8s"),
        ("xn--fiqs8s", nil),
    ]

    private func ascii(_ host: String) -> String {
        var comps = URLComponents()
        comps.host = host.lowercased()
        return comps.encodedHost ?? host.lowercased()
    }

    func testOfficialVectors() {
        for (input, expected) in Self.vectors {
            XCTAssertEqual(PublicSuffix.registrableDomain(ascii(input)), expected.map(ascii), input)
        }
    }

    func testListIsEmbedded() {
        XCTAssertFalse(PublicSuffix.version.isEmpty)
        XCTAssertNil(PublicSuffix.registrableDomain("github.io"))
        XCTAssertEqual(PublicSuffix.registrableDomain("a.b.victim.github.io"), "victim.github.io")
    }

    /// Хостинги, которых не было в прежнем самодельном списке: соседние поддомены — разные владельцы.
    func testSharedHostingIsNotOneSite() {
        XCTAssertFalse(SiteMatch.matches(pageHost: "evil.s3.amazonaws.com", entryHost: "bank.s3.amazonaws.com"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "evil.azurestaticapps.net", entryHost: "good.azurestaticapps.net"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "evil.kiev.ua", entryHost: "good.kiev.ua"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "evil.com.au", entryHost: "good.com.au"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "login.good.com.au", entryHost: "good.com.au"))
        XCTAssertFalse(SiteMatch.matches(pageHost: "WWW.Example.COM.", entryHost: "example.com"))
    }
}
