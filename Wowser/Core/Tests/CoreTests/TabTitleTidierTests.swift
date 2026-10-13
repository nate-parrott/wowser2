import XCTest
@testable import Core

/// Real titles collected from live sites (Oct 2026).
final class TabTitleTidierTests: XCTestCase {
    private let cases: [(url: String, title: String, expected: String)] = [
        ("https://www.figma.com/design/SuEj8C/PROJECTS", "PROJECTS – Figma", "PROJECTS"),
        ("https://en.wikipedia.org/wiki/Web_browser", "Web browser - Wikipedia", "Web browser"),
        ("https://www.youtube.com/watch?v=Yw6u6YkTgQ4", "hello world - YouTube", "hello world"),
        ("https://www.youtube.com/watch?v=x", "(3) Tim and Eric - Celery Man - YouTube", "Tim and Eric - Celery Man"),
        ("https://docs.google.com/document/d/1v24/edit", "two ideas - Google Docs", "two ideas"),
        ("https://docs.google.com/spreadsheets/d/1v24/edit", "RSVPS - Google Sheets", "RSVPS"),
        ("https://www.google.com/maps/place/497+Union+St", "497 Union St - Google Maps", "497 Union St"),
        ("https://mail.google.com/mail/u/0/#inbox/abc", "Fwd: Pacific Party Rentals Invoice - me@gmail.com - Gmail", "Fwd: Pacific Party Rentals Invoice"),
        ("https://mail.google.com/mail/u/0/#inbox", "Inbox (1,016) - me@gmail.com - Gmail", "Inbox (1,016)"),
        ("https://calendar.google.com/calendar/u/0/r/eventedit/x", "Google Calendar - Event details", "Event details"),
        ("https://github.com/nate-parrott/Flashlight/issues/43", "Support Alfred workflows · Issue #43 · nate-parrott/Flashlight", "Support Alfred workflows"),
        ("https://github.com/swiftlang/swift/pull/1", "Redundant Load Elimination Patches by trentxintong · Pull Request #1 · swiftlang/swift", "Redundant Load Elimination Patches"),
        ("https://github.com/swiftlang/swift", "swiftlang/swift: The Swift Programming Language", "swiftlang/swift"),
        ("https://github.com/swiftlang/swift/blob/main/README.md", "swift/README.md at main · swiftlang/swift", "swift/README.md"),
        ("https://github.com/nate-parrott/wowser2/commit/775f637", "Remove Claude PR GitHub workflow · nate-parrott/wowser2@775f637", "Remove Claude PR GitHub workflow"),
        ("https://github.com/login", "Sign in to GitHub · GitHub", "Sign in to GitHub"),
        ("https://github.com/nope", "Page not found · GitHub · GitHub", "Page not found"),
        ("https://stackoverflow.com/questions/11227809/x", "java - Why is conditional processing of a sorted array faster than of an unsorted array? - Stack Overflow", "Why is conditional processing of a sorted array faster than of an unsorted array?"),
        ("https://math.stackexchange.com/questions/1/x", "calculus - What is a limit? - Mathematics Stack Exchange", "What is a limit?"),
        ("https://www.reddit.com/r/mac/comments/abc/x/", "OS X Tiger wallpaper looks perfect on Big Sur! : r/mac", "OS X Tiger wallpaper looks perfect on Big Sur!"),
        ("https://x.com/BBCWorld/status/1", "(1) BBC News (World) on X: \"US road rage killer's sentence quashed\" / X", "BBC News (World): \"US road rage killer's sentence quashed\""),
        ("https://x.com/home", "(1) Home / X", "Home"),
        ("https://x.com/nateparrott", "nate parrott (@nateparrott) / X", "nate parrott (@nateparrott)"),
        ("https://www.amazon.com/dp/B0D1XD1ZV3", "Amazon.com: Apple AirPods Pro 2 Wireless Earbuds, USB-C Charging : Electronics", "Apple AirPods Pro 2 Wireless Earbuds, USB-C Charging"),
        ("https://www.amazon.com/s?k=delicious+candy", "Amazon.com : delicious candy", "delicious candy"),
        ("https://karpathy.medium.com/software-2-0-a64152b37c35", "Software 2.0. I sometimes see people refer to neural… | by Andrej Karpathy | Medium", "Software 2.0. I sometimes see people refer to neural…"),
        ("https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array/map", "Array.prototype.map() - JavaScript | MDN", "Array.prototype.map()"),
        ("https://news.ycombinator.com/item?id=1", "Y Combinator | Hacker News", "Y Combinator"),
        ("https://www.imdb.com/title/tt0111161/", "The Shawshank Redemption (1994) - IMDb", "The Shawshank Redemption (1994)"),
        ("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT", "Never Gonna Give You Up - song and lyrics by Rick Astley | Spotify", "Never Gonna Give You Up · Rick Astley"),
        ("https://www.linkedin.com/company/apple", "Apple | LinkedIn", "Apple"),
        ("https://www.yelp.com/biz/tartine-bakery-san-francisco-3", "TARTINE BAKERY - Updated October 2026 - 9208 Reviews - 600 Guerrero St, San Francisco, California - Bakeries - Yelp", "TARTINE BAKERY"),
        ("https://substack.com/@platformer", "Casey Newton | Substack", "Casey Newton"),
        ("https://www.npmjs.com/package/react", "react - npm", "react"),
        ("https://pypi.org/project/requests/", "requests · PyPI", "requests"),
        ("https://docs.python.org/3/library/json.html", "json — JSON encoder and decoder — Python 3.15.0 documentation", "json — JSON encoder and decoder"),
        ("https://www.notion.com/help/what-is-a-block", "What is a block in Notion? | Notion Help – Notion Help Center", "What is a block in Notion?"),
        ("https://arxiv.org/abs/1706.03762", "[1706.03762] Attention Is All You Need", "Attention Is All You Need"),
        ("https://developer.apple.com/documentation/foundationmodels", "Foundation Models updates | Apple Developer Documentation", "Foundation Models updates"),
        ("https://developer.apple.com/account", "Account - Apple Developer", "Account"),
        ("https://machinelearning.apple.com/research/x", "Introducing the Third Generation of Apple’s Foundation Models - Apple Machine Learning Research", "Introducing the Third Generation of Apple’s Foundation Models"),
        ("https://www.nytimes.com/2026/10/01/world/x.html", "After Russian Diesel Deal, Trump Faces New Crisis Over Ukraine - The New York Times", "After Russian Diesel Deal, Trump Faces New Crisis Over Ukraine"),
        ("https://www.theverge.com/2026/1/1/x", "Some headline | The Verge", "Some headline"),
        ("https://www.theguardian.com/world/2026/x", "Some headline | World news | The Guardian", "Some headline"),
        ("https://www.bbc.com/news/articles/x", "Some headline - BBC News", "Some headline"),
        ("https://html.duckduckgo.com/html/?q=x", "macos wallpaper at DuckDuckGo", "macos wallpaper"),
        ("https://claude.ai/chat/x", "Artifact review and changes - Claude", "Artifact review and changes"),
        ("https://platform.claude.com/docs/x", "MCP tunnels - Claude Platform Docs", "MCP tunnels"),
        ("https://www.instagram.com/nasa/", "(2) Instagram", "Instagram"),
        // Homepages keep their title: the site name is the useful part there.
        ("https://www.washingtonpost.com/", "The Washington Post - Breaking news and latest headlines", "The Washington Post - Breaking news and latest headlines"),
        // Unknown sites whose suffix isn't their name are untouched.
        ("http://localhost:8080/login", "Classic login — Autofill Playground", "Classic login — Autofill Playground"),
        // Never tidy down to nothing.
        ("https://www.figma.com/files/recents", "Figma", "Figma"),
    ]

    func testTidy() {
        for c in cases {
            XCTAssertEqual(TabTitleTidier.tidy(c.title, url: URL(string: c.url)), c.expected, c.url)
        }
    }
}
