import XCTest
@testable import Core

// Evals for the MicroAI features, run against real models. Skipped unless
// MICROAI_EVAL=1. Pick backends with MICROAI_BACKENDS (comma-separated
// MicroAIBackend raw values; default "onDevice"). OpenRouter needs
// OPENROUTER_KEY (and optionally OPENROUTER_MODEL, default gpt-5.4-nano).
// Results go to stdout and, if MICROAI_EVAL_OUT is set, a JSON file there.
//
//   MICROAI_EVAL=1 MICROAI_BACKENDS=onDevice,openRouter OPENROUTER_KEY=... \
//     swift test --filter MicroAIEvals
//
// Link-space cases are scored automatically. Sections, titles and icons are
// subjective: they're printed for a human (or model) to judge, with only
// mechanical checks (every tab assigned, valid emoji/color) asserted.

final class MicroAIEvals: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private var backends: [MicroAIBackend] {
        (env["MICROAI_BACKENDS"] ?? "onDevice").split(separator: ",").compactMap { MicroAIBackend(rawValue: String($0)) }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(env["MICROAI_EVAL"] == "1", "set MICROAI_EVAL=1 to run model evals")
        if let key = env["OPENROUTER_KEY"] {
            DefaultsKeys.openrouterKey.setString(key)
            if let model = env["OPENROUTER_MODEL"] {
                DefaultsKeys.llmChoice.setString(LLMChoice.openrouter_custom.rawValue)
                DefaultsKeys.openrouterCustomModel.setString(model)
            } else {
                DefaultsKeys.llmChoice.setString(LLMChoice.openrouter_gpt_5_4_nano.rawValue)
            }
        }
    }

    // MARK: Output

    private struct Record: Codable {
        var eval: String
        var backend: String
        var caseName: String
        var output: String
        var expected: String?
        var pass: Bool?
        var seconds: Double
    }

    private static var records = [Record]()

    private func record(_ eval: String, _ backend: MicroAIBackend, _ caseName: String, output: String, expected: String? = nil, pass: Bool? = nil, seconds: Double) {
        let r = Record(eval: eval, backend: backend.rawValue, caseName: caseName, output: output, expected: expected, pass: pass, seconds: seconds)
        Self.records.append(r)
        let mark = pass.map { $0 ? "✅" : "❌" } ?? "•"
        print("[EVAL] \(eval) | \(backend.rawValue) | \(caseName) | \(mark) \(output.replacingOccurrences(of: "\n", with: " ⏎ "))" + (expected.map { " | expected: \($0)" } ?? "") + String(format: " | %.1fs", seconds))
        if let path = env["MICROAI_EVAL_OUT"], let data = try? JSONEncoder().encode(Self.records) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func timed<T>(_ block: () async throws -> T) async -> (Result<T, Error>, Double) {
        let start = Date()
        do { return (.success(try await block()), Date().timeIntervalSince(start)) }
        catch { return (.failure(error), Date().timeIntervalSince(start)) }
    }

    // MARK: - Link → space

    private static let lifeSpaces: [LinkSpaceTask.Space] = [
        .init(name: "Work", recentDomains: ["github.com", "linear.app", "notion.so", "figma.com", "app.slack.com", "vercel.com"],
              openTabs: ["Fix sidebar flicker on space swipe by nparrott · Pull Request #4821 — github.com",
                         "WOW-212 Space background doesn't update — linear.app",
                         "Q3 roadmap — notion.so",
                         "Onboarding flow v3 – Figma — figma.com"]),
        .init(name: "Apartment hunt", recentDomains: ["streeteasy.com", "zillow.com", "newyork.craigslist.org", "lemonade.com"],
              openTabs: ["2 Bedroom Apartment for Rent at 412 7th Ave #3R, Park Slope — streeteasy.com",
                         "Renters Insurance Quote | Lemonade — lemonade.com",
                         "Park Slope apartments for rent - Zillow — zillow.com"]),
        .init(name: "Japan trip", recentDomains: ["google.com", "booking.com", "japan-guide.com", "tabelog.com", "jreast.co.jp"],
              openTabs: ["Kyoto Travel Guide — japan-guide.com",
                         "Hotel Gracery Shinjuku, Tokyo – Updated 2026 Prices — booking.com",
                         "JR Pass: is it still worth it after the price increase? — reddit.com"]),
        .init(name: "Personal", recentDomains: ["mail.google.com", "youtube.com", "reddit.com", "nytimes.com", "chase.com"],
              openTabs: ["Inbox (3) - nate@example.com - Gmail — mail.google.com",
                         "The Daily - The New York Times — nytimes.com"]),
    ]

    private static let schoolSpaces: [LinkSpaceTask.Space] = [
        .init(name: "Wedding", recentDomains: ["theknot.com", "zola.com", "etsy.com", "pinterest.com"],
              openTabs: ["Zola: Wedding Registry, Websites & Planning — zola.com",
                         "Rustic wedding centerpieces — pinterest.com"]),
        .init(name: "CS 161", recentDomains: ["canvas.stanford.edu", "piazza.com", "gradescope.com", "cs161.stanford.edu"],
              openTabs: ["CS 161: Design and Analysis of Algorithms — cs161.stanford.edu",
                         "Homework 4 - Gradescope — gradescope.com"]),
        .init(name: "Home", recentDomains: ["amazon.com", "homedepot.com", "nextdoor.com"],
              openTabs: ["Dehumidifier 50 pint - Amazon.com — amazon.com"]),
    ]

    private struct LinkCase {
        var name: String
        var spaces: [LinkSpaceTask.Space]
        var current: Int
        var url: String
        var acceptable: Set<String>
    }

    private static let linkCases: [LinkCase] = [
        .init(name: "github PR from Slack", spaces: lifeSpaces, current: 3, url: "https://github.com/wowser/wowser/pull/4830", acceptable: ["Work"]),
        .init(name: "linear issue", spaces: lifeSpaces, current: 1, url: "https://linear.app/wowser/issue/WOW-230/omnibox-crash-on-paste", acceptable: ["Work"]),
        .init(name: "streeteasy listing from email", spaces: lifeSpaces, current: 0, url: "https://streeteasy.com/building/the-berkley/5c", acceptable: ["Apartment hunt"]),
        .init(name: "zillow from text", spaces: lifeSpaces, current: 3, url: "https://www.zillow.com/homedetails/245-Prospect-Park-W-Brooklyn-NY-11215/30654789_zpid/", acceptable: ["Apartment hunt"]),
        .init(name: "japan-guide page", spaces: lifeSpaces, current: 0, url: "https://www.japan-guide.com/e/e3900.html", acceptable: ["Japan trip"]),
        .init(name: "JAL flight (topic, new domain)", spaces: lifeSpaces, current: 3, url: "https://www.jal.co.jp/jp/en/inter/", acceptable: ["Japan trip"]),
        .init(name: "airbnb while in Japan trip", spaces: lifeSpaces, current: 2, url: "https://www.airbnb.com/rooms/53219876", acceptable: ["Japan trip"]),
        .init(name: "nytimes article while at work", spaces: lifeSpaces, current: 0, url: "https://www.nytimes.com/2026/09/24/nyregion/rent-guidelines-board.html", acceptable: ["Personal", "Apartment hunt"]),
        .init(name: "google doc (ambiguous, stay)", spaces: lifeSpaces, current: 0, url: "https://docs.google.com/document/d/1xY2abcDEF/edit", acceptable: ["Work"]),
        .init(name: "figma from apartment space", spaces: lifeSpaces, current: 1, url: "https://www.figma.com/design/AbC123/Settings-redesign", acceptable: ["Work"]),
        .init(name: "chase statement", spaces: lifeSpaces, current: 0, url: "https://secure.chase.com/web/auth/dashboard#/dashboard/overview", acceptable: ["Personal"]),
        .init(name: "tabelog restaurant", spaces: lifeSpaces, current: 3, url: "https://tabelog.com/en/kyoto/A2601/A260201/26002222/", acceptable: ["Japan trip"]),
        .init(name: "vercel deploy link", spaces: lifeSpaces, current: 2, url: "https://vercel.com/wowser/site/deployments/8fJk2", acceptable: ["Work"]),
        .init(name: "gradescope from email", spaces: schoolSpaces, current: 0, url: "https://www.gradescope.com/courses/712345/assignments/4012345", acceptable: ["CS 161"]),
        .init(name: "etsy invitations", spaces: schoolSpaces, current: 2, url: "https://www.etsy.com/listing/1234567/wedding-invitation-template-minimalist", acceptable: ["Wedding"]),
        .init(name: "algorithms youtube lecture", spaces: schoolSpaces, current: 2, url: "https://www.youtube.com/watch?v=0K_eZGS5NsU&t=dynamic-programming-lecture", acceptable: ["CS 161", "Home"]),
        .init(name: "home depot from wedding", spaces: schoolSpaces, current: 0, url: "https://www.homedepot.com/p/Frigidaire-50-Pint-Dehumidifier/318043523", acceptable: ["Home"]),
        .init(name: "random blog (stay)", spaces: schoolSpaces, current: 2, url: "https://www.paulgraham.com/greatwork.html", acceptable: ["Home"]),
        // Topic-only: no space has visited the site.
        .init(name: "kayak Tokyo flights", spaces: lifeSpaces, current: 3, url: "https://www.kayak.com/flights/NYC-TYO/2026-11-02/2026-11-16", acceptable: ["Japan trip"]),
        .init(name: "redfin Brooklyn rental", spaces: lifeSpaces, current: 0, url: "https://www.redfin.com/NY/Brooklyn/123-5th-Ave-11215/apartment/rent", acceptable: ["Apartment hunt"]),
        .init(name: "apple dev docs from personal", spaces: lifeSpaces, current: 3, url: "https://developer.apple.com/documentation/swiftui/navigationsplitview", acceptable: ["Work"]),
        .init(name: "ticketmaster (stay)", spaces: lifeSpaces, current: 0, url: "https://www.ticketmaster.com/phoebe-bridgers-tickets/artist/2360145", acceptable: ["Work", "Personal"]),
        .init(name: "coursera algorithms", spaces: schoolSpaces, current: 0, url: "https://www.coursera.org/learn/algorithms-part1", acceptable: ["CS 161"]),
        .init(name: "brides.com article", spaces: schoolSpaces, current: 1, url: "https://www.brides.com/wedding-timeline-checklist-4799123", acceptable: ["Wedding"]),
        .init(name: "wikipedia (stay)", spaces: schoolSpaces, current: 1, url: "https://en.wikipedia.org/wiki/Byzantine_Empire", acceptable: ["CS 161"]),
    ]

    func testLinkSpace() async throws {
        for backend in backends {
            var passed = 0
            for c in Self.linkCases {
                let (result, secs) = await timed {
                    try await LinkSpaceTask.run(url: URL(string: c.url)!, spaces: c.spaces, currentIndex: c.current, backend: backend)
                }
                switch result {
                case .success(let (index, reason)):
                    let name = index.map { c.spaces[$0].name } ?? "<invalid>"
                    let ok = c.acceptable.contains(name)
                    if ok { passed += 1 }
                    record("linkSpace", backend, c.name, output: "\(name) — \(reason)", expected: c.acceptable.sorted().joined(separator: " / "), pass: ok, seconds: secs)
                case .failure(let error):
                    record("linkSpace", backend, c.name, output: "ERROR \(error)", pass: false, seconds: secs)
                }
            }
            print("[EVAL] linkSpace | \(backend.rawValue) | SCORE \(passed)/\(Self.linkCases.count)")
        }
    }

    // MARK: - Tab sets (sections + titles)

    private static func tabs(_ list: [(String, String)]) -> [TabGroupsTask.TabInfo] {
        list.map { .init(title: $0.0, url: URL(string: $0.1)!) }
    }

    static let tabSets: [(name: String, tabs: [TabGroupsTask.TabInfo])] = [
        ("apartment + moving", tabs([
            ("2 Bedroom Apartment for Rent at 412 7th Ave #3R, Park Slope | StreetEasy", "https://streeteasy.com/building/412-7-avenue-brooklyn/3r"),
            ("The Berkley #5C - Rental | StreetEasy", "https://streeteasy.com/building/the-berkley/5c"),
            ("245 Prospect Park W, Brooklyn, NY 11215 | Zillow", "https://www.zillow.com/homedetails/245-Prospect-Park-W-Brooklyn-NY-11215/30654789_zpid/"),
            ("Renters Insurance Quote | Lemonade", "https://www.lemonade.com/renters"),
            ("State Farm Renters Insurance", "https://www.statefarm.com/insurance/home-and-property/renters"),
            ("Two Men and a Truck - Brooklyn Movers", "https://twomenandatruck.com/movers/ny/brooklyn"),
            ("Moving quote - Dumbo Moving & Storage", "https://dumbomoving.com/quote"),
            ("U-Haul Truck Rental: 15' Truck", "https://www.uhaul.com/Trucks/15ft-Moving-Truck-Rental/RT/"),
            ("KIVIK Sofa, Tibbleby beige/gray - IKEA", "https://www.ikea.com/us/en/p/kivik-sofa-tibbleby-beige-gray-s79440532/"),
            ("MALM Bed frame, high - IKEA", "https://www.ikea.com/us/en/p/malm-bed-frame-high-white-s49932209/"),
            ("Article Sven Sofa - Charme Tan", "https://www.article.com/product/1600/sven-charme-tan-sofa"),
            ("Con Edison - Start, Stop or Move Service", "https://www.coned.com/en/start-stop-or-move-service"),
            ("Spectrum Internet Plans", "https://www.spectrum.com/internet"),
            ("Verizon Fios Availability", "https://www.verizon.com/home/fios/"),
            ("How to break a lease in New York - r/AskNYC", "https://www.reddit.com/r/AskNYC/comments/1abcd/how_to_break_a_lease/"),
        ])),
        ("engineer's work day", tabs([
            ("Fix sidebar flicker on space swipe by nparrott · Pull Request #4821 · wowser/wowser", "https://github.com/wowser/wowser/pull/4821"),
            ("Add on-device AI backends by nparrott · Pull Request #4830 · wowser/wowser", "https://github.com/wowser/wowser/pull/4830"),
            ("Issues · wowser/wowser", "https://github.com/wowser/wowser/issues"),
            ("WOW-212 Space background doesn't update on swipe", "https://linear.app/wowser/issue/WOW-212"),
            ("WOW-230 Omnibox crash on paste", "https://linear.app/wowser/issue/WOW-230"),
            ("My issues · Linear", "https://linear.app/wowser/my-issues"),
            ("Generating content | Apple Developer Documentation", "https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models"),
            ("LanguageModelSession | Apple Developer Documentation", "https://developer.apple.com/documentation/foundationmodels/languagemodelsession"),
            ("swift - How to decode JSON with dynamic keys - Stack Overflow", "https://stackoverflow.com/questions/44603248/how-to-decode-a-json-with-dynamic-keys"),
            ("Q3 roadmap", "https://www.notion.so/wowser/Q3-roadmap-8a7b6c"),
            ("1:1 notes — Nate / Priya", "https://www.notion.so/wowser/1-1-notes-2f3e4d"),
            ("Onboarding flow v3 – Figma", "https://www.figma.com/design/AbC123/Onboarding-flow-v3"),
            ("Slack | #eng-browser | Wowser", "https://app.slack.com/client/T0123/C0456"),
            ("Lunch near Flatiron - Google Maps", "https://www.google.com/maps/search/lunch+near+flatiron"),
            ("Dig - Order online", "https://www.diginn.com/order"),
            ("Sweetgreen | Order", "https://order.sweetgreen.com/"),
            ("Hacker News", "https://news.ycombinator.com/"),
        ])),
        ("japan trip + random", tabs([
            ("Kyoto Travel Guide - japan-guide.com", "https://www.japan-guide.com/e/e2158.html"),
            ("Fushimi Inari Shrine - japan-guide.com", "https://www.japan-guide.com/e/e3915.html"),
            ("Arashiyama Bamboo Grove - japan-guide.com", "https://www.japan-guide.com/e/e3912.html"),
            ("Hotel Gracery Shinjuku, Tokyo – Updated 2026 Prices", "https://www.booking.com/hotel/jp/gracery-shinjuku.html"),
            ("Ryokan Yachiyo, Kyoto – Updated 2026 Prices", "https://www.booking.com/hotel/jp/ryokan-yachiyo.html"),
            ("JFK to HND flights - Google Flights", "https://www.google.com/travel/flights/search?tfs=abc"),
            ("JR Pass: is it still worth it after the price increase? : r/JapanTravel", "https://www.reddit.com/r/JapanTravel/comments/xyz/jr_pass_worth_it/"),
            ("Tokyo Ramen Top 10 - Tabelog", "https://tabelog.com/en/tokyo/rstLst/ramen/"),
            ("Ichiran Shibuya - Tabelog", "https://tabelog.com/en/tokyo/A1303/A130301/13041029/"),
            ("Sushi Saito - Tabelog", "https://tabelog.com/en/tokyo/A1308/A130802/13014255/"),
            ("Pocket WiFi rental Japan - Ninja WiFi", "https://ninjawifi.com/en"),
            ("Chase Sapphire Reserve foreign transaction fees", "https://www.chase.com/personal/credit-cards/sapphire/reserve"),
            ("The Bear Season 4 | Hulu", "https://www.hulu.com/series/the-bear"),
            ("Inbox (12) - nate@example.com - Gmail", "https://mail.google.com/mail/u/0/#inbox"),
            ("How to Train Your Sourdough Starter - King Arthur Baking", "https://www.kingarthurbaking.com/recipes/sourdough-starter-recipe"),
            ("Easy Sourdough Bread Recipe - The Perfect Loaf", "https://www.theperfectloaf.com/beginners-sourdough-bread/"),
        ])),
        ("wedding planning", tabs([
            ("Zola: Wedding Registry, Websites & Planning", "https://www.zola.com/wedding-planning"),
            ("The Knot: Wedding venues in Hudson Valley", "https://www.theknot.com/marketplace/wedding-reception-venues-hudson-valley-ny"),
            ("Wing's Castle - Wedding Venue - Millbrook, NY", "https://www.theknot.com/marketplace/wings-castle-millbrook-ny-123"),
            ("Rustic wedding centerpieces - Pinterest", "https://www.pinterest.com/search/pins/?q=rustic%20wedding%20centerpieces"),
            ("Minimalist wedding invitation template - Etsy", "https://www.etsy.com/listing/1234567/wedding-invitation-template-minimalist"),
            ("Paperless Post - Wedding Save the Dates", "https://www.paperlesspost.com/cards/category/wedding-save-the-dates"),
            ("Brooklyn wedding photographers - The Knot", "https://www.theknot.com/marketplace/wedding-photographers-brooklyn-ny"),
            ("Jane Doe Photography | Portfolio", "https://janedoephoto.com/portfolio"),
            ("Men's Suits | SuitSupply", "https://suitsupply.com/en-us/men/suits"),
            ("BHLDN Wedding Dresses", "https://www.bhldn.com/collections/wedding-dresses"),
            ("Wedding budget spreadsheet - Google Sheets", "https://docs.google.com/spreadsheets/d/1AbC/edit"),
            ("Guest list - Google Sheets", "https://docs.google.com/spreadsheets/d/2DeF/edit"),
        ])),
    ]

    func testTabGroups() async throws {
        for backend in backends {
            for set in Self.tabSets {
                let (result, secs) = await timed {
                    try await TabGroupsTask.run(tabs: set.tabs, existingGroups: [], backend: backend)
                }
                switch result {
                case .success(let groups):
                    var byGroup = [String: [Int]]()
                    var order = [String]()
                    for (i, g) in groups.enumerated() {
                        let key = g ?? "<unassigned>"
                        if byGroup[key] == nil { order.append(key) }
                        byGroup[key, default: []].append(i)
                    }
                    let text = order.map { g in
                        "\(g): " + byGroup[g]!.map { i in set.tabs[i].title?.truncateTailWithEllipsis(chars: 40) ?? "?" }.joined(separator: "; ")
                    }.joined(separator: "\n")
                    let unassigned = groups.filter { $0 == nil }.count
                    let singletons = byGroup.filter { $0.key != "<unassigned>" && $0.value.count == 1 }.count
                    record("tabGroups", backend, set.name, output: text + "\n(\(byGroup.count) sections, \(singletons) singletons, \(unassigned) unassigned)", pass: unassigned == 0, seconds: secs)
                case .failure(let error):
                    record("tabGroups", backend, set.name, output: "ERROR \(error)", pass: false, seconds: secs)
                }
            }
        }
    }

    func testSpaceTitle() async throws {
        for backend in backends {
            for set in Self.tabSets {
                let (result, secs) = await timed { try await SpaceTitleTask.run(tabs: set.tabs, backend: backend) }
                switch result {
                case .success(let name): record("spaceTitle", backend, set.name, output: name, seconds: secs)
                case .failure(let error): record("spaceTitle", backend, set.name, output: "ERROR \(error)", pass: false, seconds: secs)
                }
            }
        }
    }

    // MARK: - Icons

    static let spaceNames = [
        "Work", "Japan trip", "Apartment hunt", "Wedding", "Taxes 2026", "Learning Rust", "Garden",
        "Fantasy football", "Baby", "Side project", "Recipes", "Music production", "CS 161", "Personal",
        "Job search", "Marathon training",
    ]

    func testSpaceIcon() async throws {
        for backend in backends {
            for name in Self.spaceNames {
                let (result, secs) = await timed { try await SpaceIconTask.run(title: name, backend: backend) }
                switch result {
                case .success(let out):
                    let ok = out.emoji != nil && out.palette != nil
                    record("spaceIcon", backend, name, output: "\(out.emoji ?? "<no emoji>") \(out.palette?.rawValue ?? "<bad color>")", pass: ok, seconds: secs)
                case .failure(let error):
                    record("spaceIcon", backend, name, output: "ERROR \(error)", pass: false, seconds: secs)
                }
            }
        }
    }

    // MARK: - Archive

    static let archiveCases: [(title: String, url: String, expected: String)] = [
        ("The New York Times - Breaking News, US News, World News and Videos", "https://www.nytimes.com/", "New York Times"),
        ("PERKINS Space Heater for Indoor Use, 1500W Ceramic Heater with Thermostat, Portable Electric Heater – Amazon.com", "https://www.amazon.com/dp/B0ABC", "PERKINS Space Heater"),
        ("(3) 🏡 House Hunting - Notion", "https://www.notion.so/House-Hunting-abc", "🏡 House Hunting"),
        ("Inbox (1,204) - nate@example.com - Gmail", "https://mail.google.com/mail/u/0/#inbox", "Gmail"),
        ("How to Train Your Sourdough Starter | King Arthur Baking", "https://www.kingarthurbaking.com/recipes/sourdough-starter", "Training a Sourdough Starter"),
        ("Fix sidebar flicker on space swipe by nparrott · Pull Request #4821 · wowser/wowser · GitHub", "https://github.com/wowser/wowser/pull/4821", "Fix sidebar flicker PR"),
        ("Hotel Gracery Shinjuku, Tokyo – Updated 2026 Prices", "https://www.booking.com/hotel/jp/gracery-shinjuku.html", "Hotel Gracery Shinjuku"),
        ("Kyoto Travel Guide - japan-guide.com", "https://www.japan-guide.com/e/e2158.html", "Kyoto Travel Guide"),
    ]

    func testArchiveTidy() async throws {
        for backend in backends {
            for c in Self.archiveCases {
                let (result, secs) = await timed { try await ArchiveTidyTask.run(title: c.title, url: URL(string: c.url)!, backend: backend) }
                switch result {
                case .success(let out):
                    record("archiveTidy", backend, c.title.truncateTailWithEllipsis(chars: 50), output: "\(out.tidyTitle) [\(out.category?.rawValue ?? "<bad category>")]", expected: c.expected, seconds: secs)
                case .failure(let error):
                    record("archiveTidy", backend, c.title.truncateTailWithEllipsis(chars: 50), output: "ERROR \(error)", pass: false, seconds: secs)
                }
            }
        }
    }
}
