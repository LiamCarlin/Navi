import Testing
import Foundation
@testable import Navi

struct URLDetectionTests {
    @Test func bareDomain() { #expect(URLAndWeb.detect("github.com")?.absoluteString == "https://github.com") }
    @Test func fullURL() { #expect(URLAndWeb.detect("https://example.org/a?b=1")?.absoluteString == "https://example.org/a?b=1") }
    @Test func localhostWithPort() { #expect(URLAndWeb.detect("localhost:3000")?.absoluteString == "http://localhost:3000") }
    @Test func ipAddress() { #expect(URLAndWeb.detect("192.168.1.1/admin")?.absoluteString == "http://192.168.1.1/admin") }
    @Test func stripsNavigationPrefix() {
        #expect(URLAndWeb.detect("go to github.com")?.host == "github.com")
        #expect(URLAndWeb.detect("open news.ycombinator.com")?.host == "news.ycombinator.com")
    }
    @Test func filenamesAreNotURLs() { #expect(URLAndWeb.detect("budget.xlsx") == nil); #expect(URLAndWeb.detect("notes.md") == nil) }
    @Test func sentencesAreNotURLs() { #expect(URLAndWeb.detect("what is github.com") == nil); #expect(URLAndWeb.detect("maps") == nil) }
    @Test func emailIsNotURL() { #expect(URLAndWeb.detect("bob@example.com") == nil) }
    @Test func unknownTLDNeedsScheme() {
        #expect(URLAndWeb.detect("foo.internal") == nil)
        #expect(URLAndWeb.detect("http://foo.internal")?.host == "foo.internal")
    }
    @Test func webSearchRow() {
        let r = URLAndWeb.webSearchResult(for: "best ramen")
        #expect(r.kind == .webSearch)
        #expect(r.id == "web:best ramen")
        #expect(URLAndWeb.googleURL(for: "best ramen").absoluteString == "https://www.google.com/search?q=best%20ramen")
    }
}
