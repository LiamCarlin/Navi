import Foundation

/// What a task refers to in the user's own world, settled once before a run.
///
/// People are names, and `UserKnowledge` matches them. Things are harder:
/// "open the last assignment I did", "pull up the doc I was working on",
/// "go back to the video from this morning", "continue my lab report",
/// "send mikey the onshape model" name no title. The user speaks about their
/// work the way they do it, so Navi reads the answer from how they did it:
///   1. code collects candidates from screen memory — digested sessions whose
///      title, page title, URL, app or tags carry the task's words or the kind
///      of thing it asks for (`UserHabits.kinds`: "doc" → Google Docs, Pages,
///      Word…), within the time the task names ("yesterday", "this morning"),
///      grouped per page (web) or per app and item (native), plus the
///      projects and documents `UserKnowledge` matches by name;
///   2. Jev picks the one the task means (`refers_to`: a choice over the
///      candidates + none) from a structured list — when each was last open,
///      for how long, what the user did there, what is on screen now;
///   3. the pick rides wherever the run looks: the planner, every Jev step
///      (`user_context`), the browser runner, start URLs, the voice path's app.
///
/// Only tasks that point at something run this (a time or "last/that/I was…"
/// reference, a kind of thing, a possessive, or a known name), so "open chrome"
/// or "click submit" cost nothing. One Jev call (~0.3–0.5 s), cached per task and
/// started while the user is still typing (`prepare`).
enum TaskGrounding {
    struct Candidate: Sendable, Equatable {
        var id = ""
        var name: String
        /// page | app | document | project
        var kind: String
        /// Where it lives: the site ("canvas.olin.edu") or the app ("MATLAB").
        var place: String
        /// Native items: the app to open.
        var bundleID: String?
        var url: String?
        var lastSeen: Date
        var sessions: Int
        var seconds: Double
        /// What the user did there (session titles), newest first.
        var did: [String]
        var score: Double
    }

    struct Grounded: Sendable {
        var task: String
        var thing: Candidate
        /// Jev's probability for the pick (a local pick without Jev: 0.6).
        var confidence: Double
        var source: String
        var alternatives: [Candidate]
    }

    struct Scope: Sendable, Equatable {
        /// The time the task names ("yesterday"); nil ⇒ the whole memory window.
        var interval: DateInterval?
        /// The task points back at something the user did ("last", "that", "I was working on", a time).
        var recent: Bool
    }

    static let maxCandidates = 6
    static let minConfidence = 0.4

    // MARK: Reading the task (pure)

    private static let recentPatterns: [String] = [
        #"\b(last|latest|most recent|recent|recently|previous|earlier|again|resume|continue|where i left off|left off)\b"#,
        #"\bback to\b"#,
        #"\b(that|those)\s+(?!is|was|are|were|i\b|it\b|he\b|she\b|they\b|we\b|you\b)\w+"#,
        #"\bi(?:'d|'ve| had| have| was| were)?\s+(?:just\s+)?(?:been\s+)?(working|reading|looking|watching|listening|doing|writing|editing|using|on|in|at|did|done|made|wrote|written|opened|edited|worked|saw|seen|read|watched|listened|used|visited|started|submitted|sent|got|had open|left)\b"#,
    ]

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// When the task's thing was seen, and whether the task points back at past work.
    static func scope(of task: String, now: Date, calendar: Calendar = .current) -> Scope {
        // What the user dictates ("text mikey saying I did it") is not a reference.
        let t = " " + withoutDictation(task).lowercased().replacingOccurrences(of: "’", with: "'") + " "
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        var interval: DateInterval?
        if has(#"\blast night\b"#) {
            interval = DateInterval(start: day(-1).addingTimeInterval(17 * 3600), end: min(now, today.addingTimeInterval(5 * 3600)))
        } else if has(#"\byesterday"#) {
            interval = DateInterval(start: day(-1), end: today)
        } else if has(#"\b(today|this morning|this afternoon|this evening|tonight|earlier today)\b"#) {
            interval = DateInterval(start: today, end: now)
        } else if has(#"\blast week\b"#) {
            interval = DateInterval(start: day(-14), end: day(-7))
        } else if has(#"\bthis week\b"#) {
            interval = DateInterval(start: day(-7), end: now)
        } else if let wd = weekdays.firstIndex(where: { has(#"\b(on |last )?"# + $0 + #"('s)?\b"#) }) {
            // The most recent such day before today.
            let todayWD = calendar.component(.weekday, from: now) - 1
            var back = (todayWD - wd + 7) % 7
            if back == 0 { back = 7 }
            interval = DateInterval(start: day(-back), end: day(-back + 1))
        }
        let recent = interval != nil || recentPatterns.contains(where: has)
        return Scope(interval: interval, recent: recent)
    }

    /// Words that say when or how recently, not what.
    static let timeWords: Set<String> = Set([
        "last", "latest", "most", "recent", "recently", "previous", "earlier", "again", "resume", "continue", "back", "left", "off",
        "yesterday", "yesterdays", "today", "todays", "tonight", "night", "morning", "afternoon", "evening", "week", "weeks", "ago",
        "this", "that", "those", "was", "were", "working", "worked", "did", "done", "had", "have", "been", "just", "doing", "looking",
        "reading", "watching", "listening", "writing", "editing", "using", "made", "wrote", "written", "opened", "edited", "saw",
        "seen", "read", "watched", "listened", "used", "visited", "started", "submitted", "sent", "got", "one", "thing", "stuff",
        "where", "which", "what", "when", "s", "ll", "ve", "d", "re", "m",
    ]).union(weekdays)

    /// Kinds of things (not kinds of contact): what a "doc", "assignment", "song" is made in.
    static func thingKinds(in task: String) -> [(kind: String, skills: [AppSkill])] {
        UserHabits.candidates(for: task).filter { !UserContacts.channelKinds.contains($0.kind) && !["calendar", "to-dos", "directions"].contains($0.kind) }
    }

    /// Short names for kinds of things, as pages and titles spell them.
    static let synonyms: [String: String] = [
        "doc": "document", "gdoc": "document", "sheet": "spreadsheet", "gsheet": "spreadsheet", "slide": "presentation",
        "deck": "presentation", "vid": "video", "pic": "photo", "picture": "photo", "repo": "repository", "hw": "homework",
        "pset": "homework", "mail": "email", "e-mail": "email", "convo": "conversation", "chat": "conversation", "pdf": "pdf",
    ]

    /// "assignments" ~ "assignment", "docs" ~ "document", "02" ~ "2" — "canvas" stays "canvas".
    static func norm(_ w: String) -> String {
        if !w.isEmpty, w.count <= 2, w.allSatisfy(\.isNumber) { let z = String(w.drop { $0 == "0" }); return z.isEmpty ? "0" : z }
        var x = w
        if x.count > 3, x.hasSuffix("s"), !["ss", "us", "is", "as", "os"].contains(where: { x.hasSuffix($0) }) { x.removeLast() }
        return synonyms[x] ?? x
    }

    /// A text's words for matching: tokens, their letter/digit parts ("assignment02"), normalized.
    static func bag(_ s: String) -> Set<String> {
        let t = UserKnowledge.tokens(s)
        return Set((t + t.flatMap(UserKnowledge.parts)).map(norm))
    }

    /// The task's words that say *what*: specific ones ("mth3199", "strandbeest",
    /// "onshape") and generic ones ("assignment", "doc", "report"). Filler, time
    /// words and `exclude` (people the task names, the app it names) are dropped.
    static func words(of task: String, exclude: Set<String> = []) -> (specific: Set<String>, generic: Set<String>) {
        let kindWords = Set(UserHabits.kinds.flatMap(\.words))
        var specific = Set<String>(), generic = Set<String>()
        for raw in UserKnowledge.tokens(withoutDictation(task)) where !exclude.contains(raw) {
            guard !timeWords.contains(raw), !UserKnowledge.isFiller(raw) else { continue }
            let w = norm(raw)
            guard w.count >= 2 || w.allSatisfy(\.isNumber) else { continue }
            if UserKnowledge.genericWords.contains(raw) || UserKnowledge.genericWords.contains(w) || kindWords.contains(raw) || kindWords.contains(w) {
                generic.insert(w)
            } else if w.count >= 3 || w.allSatisfy(\.isNumber) || w.contains(where: \.isNumber) {
                specific.insert(w)
            }
        }
        return (specific, generic)
    }

    /// The task without the text it dictates ("text mom saying I'm on my way" → "text mom"):
    /// what the user will say is not a thing to look for.
    static func withoutDictation(_ task: String) -> String {
        let p = #"(?i)(\s*[:"“]|\b(saying|that says|which says|to say|telling (him|her|them|me)|tell (him|her|them)|asking (him|her|them)?|ask (him|her|them)|with the (text|message|subject|body))\b).*$"#
        return task.replacingOccurrences(of: p, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// "Open / pull up / go back to / continue … <something of the user's from before>": a
    /// command to reopen their own work, which only screen memory can resolve.
    /// `possessive`: "open my lab report" counts too (voice, where no app was recognised);
    /// ⌘Space keeps "open my notes" for the Notes app and counts only explicit references.
    static func reopensOwnWork(_ task: String, now: Date = Date(), possessive: Bool = true) -> Bool {
        let t = task.lowercased().trimmingCharacters(in: .whitespaces)
        let opener = #"^(?:(?:can you|could you|please|navi)\s+)*(open|reopen|pull up|bring up|bring back|go back to|get back to|go to|take me to|show me|show|continue|resume|pick up|play|watch|find)\b"#
        guard t.range(of: opener, options: .regularExpression) != nil else { return false }
        let sc = scope(of: task, now: now)
        if isSearch(task), !sc.recent { return false }
        // Something to reopen must be named ("the doc", "the onshape model"): "play it again" is not.
        let w = words(of: task)
        let leftOff = t.range(of: #"\b(where i left off|what i was (doing|working on))\b"#, options: .regularExpression) != nil
        guard leftOff || !w.specific.isEmpty || !w.generic.isEmpty else { return false }
        if sc.recent { return true }
        return possessive && t.range(of: #"\b(my|our)\b"#, options: .regularExpression) != nil && !thingKinds(in: task).isEmpty
    }

    /// "today 10:09 AM": when, for a status line.
    static func shortWhen(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = calendar.isDate(d, inSameDayAs: now) ? "'today' h:mm a"
            : calendar.isDate(d, inSameDayAs: now.addingTimeInterval(-86_400)) ? "'yesterday' h:mm a" : "EEE MMM d"
        return f.string(from: d)
    }

    /// Asks for a search or a lookup on the web, not for something of the user's.
    static func isSearch(_ task: String) -> Bool {
        task.lowercased().range(of: #"\b(search|google|look up|lookup|find out|what is|what's|who is|how (do|to|much|many))\b"#, options: .regularExpression) != nil
    }

    /// The task is about a message the user got or sent ("the email from gabi", "that text
    /// from mom", "reply to the last message"): its people describe it, they are not recipients.
    static func refersToMessage(_ task: String) -> Bool {
        task.lowercased().range(of: #"\b(the|that|this|last|latest|recent|her|his|their)\s+(\w+\s+){0,2}(email|e-mail|mail|message|text|thread|conversation|chat|dm|invite|invitation|reply|voicemail)s?\b"#,
                                options: .regularExpression) != nil
    }

    /// People words to leave out of what the task is about: in "send dhvan the notes" Dhvan
    /// is who it goes to; in "open the doc dhvan shared" or "the email from gabi" they say which.
    static func recipientWords(task: String, people: Set<String>) -> Set<String> {
        guard isCommunication(task), !refersToMessage(task) else { return [] }
        // "mom", "dad": family words name a contact even when it is saved as "Mama".
        return people.union(UserKnowledge.tokens(task).filter { RecipientPicker.nicknames[$0] != nil })
    }

    /// Worth grounding at all: the task points back in time, asks for a kind of
    /// thing, says "my/our …", refers to a message, or names something memory knows.
    static func shouldGround(task: String, scope: Scope, words: (specific: Set<String>, generic: Set<String>), named: Bool) -> Bool {
        if scope.recent || refersToMessage(task) { return true }
        if isSearch(task) { return false }
        guard !words.specific.isEmpty || !words.generic.isEmpty else { return false }
        if named || !thingKinds(in: task).isEmpty { return true }
        return task.lowercased().range(of: #"\b(my|our|mine)\b"#, options: .regularExpression) != nil
    }

    // MARK: Candidates (pure)

    /// Search pages, sign-in pages and Navi itself are never the thing.
    static func isNoise(_ s: SessionRecord) -> Bool {
        if s.bundleID == Bundle.main.bundleIdentifier || s.bundleID == "com.liamcarlin.navi" { return true }
        if UserHabits.ignoredBundles.contains(s.bundleID) || UserKnowledge.ignoredBundles.contains(s.bundleID) { return true }
        if let u = s.url {
            if UserHabits.isAuthPage(u) { return true }
            let lower = u.lowercased()
            if lower.range(of: #"^https?://(www\.)?(google|bing|duckduckgo|search\.yahoo)\.[a-z.]+/(search|webhp|\?|$)"#, options: .regularExpression) != nil { return true }
            // A results page is a search, not a thing (x.com/search, youtube.com/results).
            let path = (URLComponents(string: u)?.path ?? "").lowercased()
            if ["/search", "/results", "/explore"].contains(path) || path.hasPrefix("/search/") { return true }
        }
        return false
    }

    /// The page a session was on, as a key: no fragment, no query — except where the
    /// query *is* the page (a YouTube video).
    static func pageKey(_ url: String) -> String? {
        guard var c = URLComponents(string: url), c.host != nil else { return nil }
        c.fragment = nil
        let keep: [String: String] = ["youtube.com/watch": "v", "www.youtube.com/watch": "v", "m.youtube.com/watch": "v"]
        let hostPath = (c.host ?? "") + c.path
        if let name = keep[hostPath], let v = c.queryItems?.first(where: { $0.name == name }) { c.queryItems = [v] } else { c.query = nil }
        var s = c.string ?? url
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// "Assignment 02 - Google Chrome - Liam" → "Assignment 02"; "Doc - Google Docs" keeps its title.
    static func cleanTitle(_ raw: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        // Chrome's tab decorations: "- Part of group Claude", "- Audio playing", "- High memory usage - 958 MB".
        t = t.replacingOccurrences(of: #"\s+-\s+(Part of group [^-]+|Audio playing|Camera (or microphone )?recording|Microphone recording|(High )?[Mm]emory usage - [\d.,]+ ?[KMG]B|Pinned|Network error)(?=\s+-\s+|$)"#,
                                   with: "", options: .regularExpression)
        for browser in [" - Google Chrome", " — Google Chrome", " - Safari", " — Safari", " - Arc", " — Mozilla Firefox", " - Microsoft Edge", " - Brave"] {
            if let r = t.range(of: browser) { t = String(t[..<r.lowerBound]) }
        }
        for suffix in [" - Google Docs", " - Google Sheets", " - Google Slides", " - Google Drive", " - YouTube", " - Gmail"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        t = t.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)   // "(398) video title"
        t = t.trimmingCharacters(in: .whitespaces)
        return t.count >= 2 ? t : nil
    }

    /// Path words of a URL that mean something ("assignments", "document"), not ids.
    static func pathWords(_ url: String) -> String {
        guard let c = URLComponents(string: url) else { return "" }
        return c.path.split(separator: "/").map(String.init)
            .filter { seg in seg.count >= 3 && seg.count <= 30 && seg.contains(where: \.isLetter) && seg.filter(\.isNumber).count * 3 < seg.count }
            .joined(separator: " ")
    }

    /// Candidates for what `task` refers to, best first, ids assigned.
    /// `people`: name words of the people the task names — left out when they are recipients.
    static func candidates(task: String, scope: Scope, sessions: [SessionRecord], pageTitles: [String: String],
                           things: [UserKnowledge.Thing], people: Set<String> = [], now: Date) -> [Candidate] {
        let named = AppSkills.mentioned(in: task)
        let exclude = recipientWords(task: task, people: people).union(named.map { Set(UserKnowledge.tokens($0.name + " " + $0.aliases.joined(separator: " "))) } ?? [])
        let w = words(of: task, exclude: exclude)
        let kinds = thingKinds(in: task)
        let kindSkills = Set(kinds.flatMap { $0.skills.map(\.name) })
        let assistantNamed = TaskPlanner.assistantApps.contains { task.lowercased().contains($0) }
        let bare = w.specific.isEmpty && w.generic.isEmpty && kinds.isEmpty && named == nil
        let aboutMessages = refersToMessage(task)
        let interval = scope.interval ?? DateInterval(start: now.addingTimeInterval(-UserKnowledge.window), end: now)

        struct Group { var c: Candidate; var bestScore: Double; var nameScore: Double }
        var matchScore: [String: Double] = [:]
        var groups: [String: Group] = [:]
        var channelMemo: [String: Bool] = [:]
        func isChannel(_ key: String) -> Bool {
            if let c = channelMemo[key] { return c }
            let c = UserKnowledge.isChannel(key)
            channelMemo[key] = c
            return c
        }
        for s in sessions where s.end >= interval.start && s.start <= interval.end && !isNoise(s) {
            let skill = AppSkills.skill(bundleID: s.bundleID, url: s.url)
            if let named, skill?.name != named.name, !(named.bundleIDs.contains(s.bundleID)) { continue }
            if !assistantNamed, UserHabits.isAssistant(bundleID: s.bundleID, appName: s.appName) || UserHabits.isAssistant(url: s.url) { continue }
            // Settings and sign-up pages are where one set something up, not the thing.
            if let u = s.url, UserKnowledge.isSetupPage(u), task.lowercased().range(of: #"\b(settings?|access|account|billing|preferences)\b"#, options: .regularExpression) == nil { continue }
            let page = s.url.flatMap(pageKey)
            let pageTitle = s.url.flatMap { UserHabits.cleanURL($0) }.flatMap { pageTitles[$0] }.flatMap(cleanTitle)
            let strong = bag(s.title + " " + (pageTitle ?? "") + " " + (s.url.map(pathWords) ?? ""))
            let placeWords = bag(s.appName + " " + (skill?.name ?? "") + " " + (s.url.flatMap { UserHabits.host(of: $0) } ?? ""))
            let tagNames = s.entities.filter { $0.type.lowercased() != "person" }.map(\.name)
            let weak = bag(tagNames.joined(separator: " "))
            var score = 0.0
            var solid = false   // a hit in the session's own title, page or app — tags alone are often a tab bar's OCR
            for x in w.specific {
                if strong.contains(x) { score += 2; solid = true } else if placeWords.contains(x) { score += 1.5; solid = true } else if weak.contains(x) { score += 1 }
            }
            for x in w.generic {
                if strong.contains(x) { score += 1; solid = true } else if weak.contains(x) { score += 0.5 }
            }
            if let skill, kindSkills.contains(skill.name) { score += 1; solid = true }
            if named != nil { score += 1; solid = true }
            // A chat or an email *about* the assignment is not the assignment: conversations are
            // candidates only when the task is about a message or names the chat app.
            if !aboutMessages, let p = UserKnowledge.place(of: s), isChannel(p.key),
               named.map({ !$0.bundleIDs.contains(s.bundleID) && skill?.name != $0.name }) ?? true { continue }
            if bare { score = 0.5; solid = true }   // "where I left off": any real work counts
            guard solid, score >= 2 || (scope.recent && score >= 1) || (bare && scope.recent) else { continue }

            // One candidate per page (web) or per app and item (native).
            // A native item is the tag the task's words name ("MTH3199-Assignment-2" in MATLAB);
            // otherwise the app itself, named by what the user did there.
            let item: String? = {
                let wanted = w.specific.union(w.generic)
                return tagNames.first { t in !bag(t).isDisjoint(with: wanted) && strong.union(placeWords).isDisjoint(with: bag(t)) == false }
                    ?? tagNames.first { !bag($0).isDisjoint(with: wanted) && s.title.lowercased().contains($0.lowercased()) }
            }()
            let key = page ?? (s.bundleID + "|" + (item ?? ""))
            let isWeb = page != nil
            let name = isWeb ? (pageTitle ?? s.title) : (item ?? s.title)
            var g = groups[key] ?? Group(c: Candidate(name: name, kind: isWeb ? "page" : "app",
                                                     place: isWeb ? (UserHabits.siteKey(of: s.url ?? "") ?? UserHabits.host(of: s.url ?? "") ?? s.appName) : s.appName.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E} ")),
                                                     bundleID: isWeb ? nil : s.bundleID, url: page, lastSeen: s.end, sessions: 0,
                                                     seconds: 0, did: [], score: 0),
                                         bestScore: 0, nameScore: -1)
            g.c.sessions += 1
            g.c.seconds += max(0, s.end.timeIntervalSince(s.start))
            if s.end > g.c.lastSeen { g.c.lastSeen = s.end }
            if !s.title.isEmpty, !g.c.did.contains(s.title) { g.c.did.append(s.title) }
            g.bestScore = max(g.bestScore, score)
            // The name from the session that matched best (a page's own title when it has one).
            if score > g.nameScore { g.nameScore = score; g.c.name = name }
            groups[key] = g
        }
        var out = groups.values.map { g -> Candidate in
            var c = g.c
            c.score = g.bestScore + min(2, log2(1 + c.seconds / 300))   // time spent: worked on, not glanced at
            c.did = Array(c.did.prefix(3))
            matchScore[c.name + (c.url ?? c.bundleID ?? "")] = g.bestScore
            return c
        }
        // Projects and documents memory knows by name ("the hci notes").
        for m in UserKnowledge.matches(task: task, in: things.filter { $0.type != "person" }) {
            let url = m.thing.url(for: task)
            if let i = out.firstIndex(where: { $0.url != nil && $0.url == url.flatMap(pageKey) }) {
                out[i].score += 2
                continue
            }
            if let s = scope.interval, !s.contains(m.thing.lastSeen) { continue }
            let place = m.thing.places.first
            out.append(Candidate(name: m.thing.name, kind: m.thing.type, place: m.thing.places.prefix(2).map(\.label).joined(separator: ", "),
                                 bundleID: place.flatMap { $0.isWeb ? nil : $0.key }, url: url, lastSeen: m.thing.lastSeen,
                                 sessions: m.thing.sessions, seconds: 0, did: [], score: 3 + 2 * m.coverage))
            matchScore[m.thing.name + (url ?? place?.key ?? "")] = 3 + 2 * m.coverage
        }
        // Pointing back in time: the most recent first; otherwise the best match.
        out.sort { a, b in
            if scope.recent, abs(a.lastSeen.timeIntervalSince(b.lastSeen)) > 60 { return a.lastSeen > b.lastSeen }
            return a.score != b.score ? a.score > b.score : a.lastSeen > b.lastSeen
        }
        if scope.recent, !bare {
            // Recency orders, but when something matches the task's own words strongly
            // ("the onshape model"), a kind-only match is not a contender.
            func m(_ c: Candidate) -> Double { matchScore[c.name + (c.url ?? c.bundleID ?? "")] ?? c.score }
            if let top = out.map(m).max(), top >= 4 { out.removeAll { m($0) < top / 2 } }
        }
        return out.prefix(maxCandidates).enumerated().map { i, c in var c = c; c.id = "c\(i + 1)"; return c }
    }

    /// Without Jev: the most recent strong candidate when the task points back in
    /// time, a single clear one otherwise.
    static func localPick(_ cs: [Candidate], scope: Scope) -> Candidate? {
        guard let first = cs.first else { return nil }
        if scope.recent { return first }
        return cs.count == 1 && first.score >= 3 ? first : nil
    }

    // MARK: Jev (pure request building)

    static func when(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = calendar.isDate(d, inSameDayAs: now) ? "'today' h:mm a"
            : calendar.isDate(d, inSameDayAs: now.addingTimeInterval(-86_400)) ? "'yesterday' h:mm a" : "EEEE MMM d, h:mm a"
        let m = Int(max(0, now.timeIntervalSince(d)) / 60)
        let ago = m < 60 ? "\(m) min ago" : m < 48 * 60 ? "\(m / 60) h ago" : "\(m / 1440) days ago"
        return f.string(from: d) + " (" + ago + ")"
    }

    static func spent(_ c: Candidate) -> String {
        let m = Int(c.seconds / 60)
        let t = m >= 60 ? "\(m / 60) h \(m % 60) min" : m > 0 ? "\(m) min" : "a moment"
        return "\(t) over \(c.sessions) session\(c.sessions == 1 ? "" : "s")"
    }

    static func describe(_ c: Candidate, now: Date) -> [String: Any] {
        var d: [String: Any] = ["id": c.id, "name": c.name, "kind": c.kind, "where": c.place, "last_open": when(c.lastSeen, now: now)]
        if c.seconds > 0 || c.kind == "page" || c.kind == "app" { d["time_spent"] = spent(c) }
        if !c.did.isEmpty { d["what_the_user_did"] = c.did }
        if let u = c.url { d["url"] = u }
        return d
    }

    static let note = "Things from this user's own screen history that the task may refer to (newest first when the task points back in time). "
        + "Each was really open on their screen: when, for how long, and what they did there."

    static let instructions = "Which candidate is the thing the task refers to — the document, page, assignment, project, video, file or "
        + "item it means to open, continue, use, send or ask about? Read the task the way this user speaks about their own work: "
        + "\"the last X I did\" is the X they most recently worked on (time spent and what they did there count, a glance does not), "
        + "\"that X\" / \"the X from yesterday\" is the one from then. Pick none when the task means what is on screen now, something "
        + "new, something on the web at large, or none of these fits."

    static func request(task: String, candidates: [Candidate], screen: FrontmostProbe.Info?, now: Date) -> (state: [String: Any], questions: [String: JevClient.Question]) {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, h:mm a"
        var state: [String: Any] = ["task": task, "now": f.string(from: now), "note": note,
                                    "candidates": candidates.map { describe($0, now: now) }]
        if let s = screen {
            var o: [String: Any] = [:]
            if let a = s.appName { o["app"] = a }
            if let w = s.windowTitle, !w.isEmpty { o["window"] = w }
            if let u = s.url { o["url"] = u }
            if !o.isEmpty { state["on_screen_now"] = o }
        }
        var criteria: [String: String] = [:]
        for c in candidates { criteria[c.id] = "\(c.name) (\(c.place)) — last open \(when(c.lastSeen, now: now)), \(spent(c))" }
        criteria["none"] = "None of the candidates: the task means what is on screen now, something new, a web search, or nothing here fits."
        return (state, ["refers_to": .choice(instructions: instructions, criteria: criteria)])
    }

    /// Jev's answer → the pick (nil for none or below `minConfidence`).
    static func pick(_ answer: JevClient.Answer?, among cs: [Candidate]) -> (Candidate, Double)? {
        guard let choice = answer?.choice, choice != "none", let c = cs.first(where: { $0.id == choice }) else { return nil }
        let p = answer?.probabilities?[choice] ?? answer?.confidence ?? 0
        return p >= minConfidence ? (c, p) : nil
    }

    // MARK: Output

    /// The task reaches someone (text, email, call, invite): the thing it names is what to
    /// send or talk about — context, not where to go.
    static func isCommunication(_ task: String) -> Bool {
        UserHabits.candidates(for: task).contains { UserContacts.channelKinds.contains($0.kind) || $0.kind == "calendar" }
            || task.lowercased().range(of: #"\b(send|share|forward|invite|reply|respond|ping|dm|call|tell|ask|remind|introduce)\b"#, options: .regularExpression) != nil
    }

    /// The grounded thing as `user_context` reads it (planner, Jev, runner).
    static func context(_ g: Grounded, now: Date = Date()) -> [String: Any] {
        var d = describe(g.thing, now: now)
        d["id"] = nil
        d["type"] = g.thing.kind
        d["kind"] = nil
        d["the_task_refers_to_this"] = String(format: "%.0f%% sure", g.confidence * 100)
        return d
    }

    // MARK: Live

    nonisolated(unsafe) private static var jevClient: JevClient?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (g: Grounded?, at: Date)] = [:]
    nonisolated(unsafe) private static var inflight: [String: Task<Grounded?, Never>] = [:]
    static let cacheTTL: TimeInterval = 180

    /// Integration hook (`ComputerAgent.init`): the Jev client grounding asks.
    static func install(jev: JevClient) { lock.lock(); jevClient = jev; lock.unlock() }

    static func cacheKey(_ task: String) -> String { task.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }

    /// The grounding already settled for `task` (or for the run's original task).
    static func cached(for task: String) -> Grounded? {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache[cacheKey(task)], Date().timeIntervalSince(c.at) < cacheTTL else { return nil }
        return c.g
    }

    /// Starts grounding `task` in the background (the router calls this while the user types).
    static func prepare(task: String) {
        Task.detached(priority: .userInitiated) { _ = await ground(task: task) }
    }

    /// What `task` refers to, settled once (Jev when there is a choice), ≤ `timeout` s.
    static func ground(task: String, timeout: Double = 2.0) async -> Grounded? {
        guard let k = UserKnowledge.current else { return nil }
        switch lookupOrStart(task: task, knowledge: k) {
        case .done(let g): return g
        case .running(let t): return await value(of: t, within: timeout)
        }
    }

    private enum Lookup { case done(Grounded?), running(Task<Grounded?, Never>) }

    private static func lookupOrStart(task: String, knowledge k: UserKnowledge) -> Lookup {
        let key = cacheKey(task)
        guard !key.isEmpty else { return .done(nil) }
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key], Date().timeIntervalSince(c.at) < cacheTTL { return .done(c.g) }
        if let running = inflight[key] { return .running(running) }
        let jev = jevClient
        // Not detached: the Jev call is metered with the run (or query) that asked (`CloudRun`).
        let t = Task(priority: .userInitiated) { await resolve(task: task, knowledge: k, jev: jev) }
        inflight[key] = t
        return .running(t)
    }

    /// `t`'s value, or nil once `seconds` pass (the task keeps running and fills the cache).
    static func value<T: Sendable>(of t: Task<T?, Never>, within seconds: Double) async -> T? {
        let once = GroundingOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            Task { let v = await t.value; if once.claim() { cont.resume(returning: v) } }
            Task { try? await Task.sleep(for: .seconds(seconds)); if once.claim() { cont.resume(returning: nil) } }
        }
    }

    private static func store(_ g: Grounded?, for task: String, at now: Date) {
        lock.lock(); defer { lock.unlock() }
        inflight[cacheKey(task)] = nil
        cache[cacheKey(task)] = (g, now)
        if cache.count > 200 { cache = cache.filter { now.timeIntervalSince($0.value.at) < cacheTTL } }
    }

    private static func resolve(task: String, knowledge k: UserKnowledge, jev: JevClient?) async -> Grounded? {
        let now = Date()
        let snap = k.snapshot(now: now)
        let sc = scope(of: task, now: now)
        let people = UserKnowledge.matches(task: task, in: snap.things.filter { $0.type == "person" })
        let peopleWords = Set(people.flatMap(\.matched))
        let recipients = recipientWords(task: task, people: peopleWords)
        let named = UserKnowledge.matches(task: task, in: snap.things.filter { $0.type != "person" }).contains { !$0.matched.isSubset(of: recipients) }
        var result: Grounded?
        if shouldGround(task: task, scope: sc, words: words(of: task, exclude: recipients), named: named) {
            let cs = candidates(task: task, scope: sc, sessions: snap.sessions, pageTitles: snap.pageTitles,
                                things: snap.things, people: peopleWords, now: now)
            if !cs.isEmpty {
                if let jev, jev.isConfigured {
                    let screen = await MainActor.run { FrontmostProbe.current(includeURL: false) }
                    let (state, questions) = request(task: task, candidates: cs, screen: screen, now: now)
                    do {
                        let r = try await jev.ask(state: JevClient.JSONValue(any: state), questions: questions)
                        if let picked = pick(r["refers_to"], among: cs) {
                            let (c, p) = picked
                            result = Grounded(task: task, thing: c, confidence: p, source: "jev", alternatives: cs.filter { $0.id != c.id })
                        }
                        Log.agent.info("TaskGrounding: \(cs.count) candidates, Jev → \(r["refers_to"]?.choice ?? "?", privacy: .public) in \(r.latencyMs) ms")
                    } catch {
                        Log.agent.warning("TaskGrounding: Jev failed (\(error.localizedDescription, privacy: .public)); local pick")
                        if let c = localPick(cs, scope: sc) { result = Grounded(task: task, thing: c, confidence: 0.6, source: "local", alternatives: cs.filter { $0.id != c.id }) }
                    }
                } else if let c = localPick(cs, scope: sc) {
                    result = Grounded(task: task, thing: c, confidence: 0.6, source: "local", alternatives: cs.filter { $0.id != c.id })
                }
            }
        }
        store(result, for: task, at: now)
        return result
    }

    /// Forgets cached groundings (after a digest added sessions).
    static func invalidate() { lock.lock(); cache.removeAll(); lock.unlock() }
}

/// Resumes a continuation once, whichever side gets there first.
private final class GroundingOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
