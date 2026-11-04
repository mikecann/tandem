import Foundation

/// What in a line of text read off a frame looks private, for `tandem check
/// --privacy`. Pure rules over the words, so they're tested without Vision.
///
/// They come from what a human sweep of the Threadbear launch video kept
/// missing, round after round: Mike's account emails in a dashboard table,
/// a street address and people's names on a phone card, booking references,
/// a pairing QR code, a thread's answer listing his projects (personal
/// errands, money, travel, an internal plan), and another person's
/// interview quotes with a note
/// that he must OK them before they go public. They lean towards flagging:
/// a false alarm costs a look at a frame, a miss puts it on YouTube.
public enum PrivateText {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case email, phone, address, reference, identity, money, crypto, travel, secret, marked, personal, names, code

        /// How a finding reads in the check's words.
        public var label: String {
            switch self {
            case .email: return "an email address"
            case .phone: return "a phone number"
            case .address: return "a street address or postcode"
            case .reference: return "a booking or order reference"
            case .identity: return "identity documents"
            case .money: return "money or banking"
            case .crypto: return "crypto"
            case .travel: return "travel plans"
            case .secret: return "a key, token or password"
            case .marked: return "something marked private or not yet approved"
            case .personal: return "family or health"
            case .names: return "a list of people's names"
            case .code: return "a QR code or barcode"
            }
        }
    }

    public struct Hit: Equatable, Sendable {
        public var category: Category
        /// What matched, as read.
        public var text: String

        public init(_ category: Category, _ text: String) {
            self.category = category
            self.text = text
        }
    }

    /// The private things in one line of text.
    public static func hits(in line: String) -> [Hit] {
        var found: [Hit] = []
        for rule in rules {
            for match in rule.regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range, in: line) else { continue }
                let text = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard rule.accept(text) else { continue }
                if !found.contains(where: { $0.category == rule.category && $0.text == text }) {
                    found.append(Hit(rule.category, text))
                }
            }
        }
        // A phone number inside a reference or a token is that, not a phone.
        return found.filter { hit in
            hit.category != .phone || !found.contains { $0.category != .phone && $0.category != .money && $0.text.contains(hit.text) && $0.text != hit.text }
        }
    }

    // Words a developer's screen is full of are left out on purpose
    // ("swift", "terminal", "gate", "pin", "order" without a code): they'd
    // flag every frame of a coding video and bury the real finds.

    // MARK: - Rules

    struct Rule {
        var category: Category
        var regex: NSRegularExpression
        var accept: (String) -> Bool = { _ in true }
    }

    static func words(_ list: [String]) -> String {
        "\\b(?:" + list.joined(separator: "|") + ")\\b"
    }

    static func digits(_ text: String) -> Int { text.filter(\.isNumber).count }

    static let rules: [Rule] = {
        func rule(_ category: Category, _ pattern: String, caseSensitive: Bool = false, accept: @escaping (String) -> Bool = { _ in true }) -> Rule {
            // The patterns are fixed, so a bad one is a programming error.
            let regex = try! NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
            return Rule(category: category, regex: regex, accept: accept)
        }
        let streets = [
            "street", "st", "road", "rd", "avenue", "ave", "lane", "ln", "drive", "dr", "court", "ct", "place", "pl", "crescent", "cres",
            "way", "parade", "pde", "terrace", "tce", "close", "boulevard", "blvd", "highway", "hwy", "square", "sq", "grove", "gardens",
            "mews", "circuit", "cct", "esplanade", "esp", "retreat", "rise", "ridge", "heights", "chase", "glade", "quay",
            "wharf", "alley", "promenade"
        ].joined(separator: "|")
        return [
            rule(.email, "[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\\.[A-Z0-9-]+)*\\.[A-Z]{2,}"),
            // Cut short by a table column ("jane.doe@gmail.c..."): the
            // Convex dashboard's accounts table showed them that way.
            rule(.email, "[A-Z0-9._%+-]+\\s?@[A-Z][A-Z0-9-]*(?:\\.[A-Z0-9-]+)*(?:\\.\\.\\.|…|\\.\\.\\.)"),
            // An international number, or a national one with a leading 0 or
            // area code in brackets, or the US 555-123-4567 shape: 8 to 15
            // digits. Dates, times and version numbers don't take these shapes.
            rule(.phone, "(?<![\\w.:/])(?:\\+\\d{1,3}[\\s.-]?(?:\\(\\d{1,4}\\)[\\s.-]?)?\\d[\\d\\s.-]{6,}\\d|\\(?0\\d{1,4}\\)?[\\s.-]?\\d{3,4}[\\s.-]?\\d{3,4}|\\(\\d{3}\\)\\s?\\d{3}[\\s.-]\\d{4}|\\d{3}-\\d{3}-\\d{4})(?![\\w.:/])",
                 accept: { (8...15).contains(digits($0)) }),
            // A number and one to three capitalised words then a street type.
            rule(.address, "\\b\\d{1,5}[A-Z]?(?:/\\d{1,5})?\\s+(?:[A-Z][a-z']+\\s+){1,3}(?i:\(streets))\\b\\.?", caseSensitive: true),
            // UK postcodes, Australian states with a postcode, US states with a ZIP.
            rule(.address, "\\b[A-Z]{1,2}\\d[A-Z\\d]?\\s\\d[A-Z]{2}\\b", caseSensitive: true),
            rule(.address, "\\b(?:NSW|VIC|QLD|WA|SA|TAS|ACT|NT)\\s+\\d{4}\\b", caseSensitive: true),
            rule(.address, "\\b[A-Z]{2}\\s+\\d{5}(?:-\\d{4})?\\b", caseSensitive: true, accept: { !$0.hasPrefix("OK") && !$0.hasPrefix("ID") }),
            // A reference word, then within a few words a code with a digit
            // in it, or six capitals (an airline's booking code).
            rule(.reference, words([
                "booking", "reservation", "confirmation", "order", "reference", "ref", "pnr", "itinerary", "ticket", "invoice", "receipt",
                "tracking", "case", "claim", "policy", "membership", "frequent flyer", "member"
            ]) + "[\\s.:#-]*(?:(?:no|number|code|id)\\.?[\\s:#-]*)?(?:[A-Za-z]+\\s+){0,2}#?\\s?(?=[A-Z0-9-]*\\d)[A-Z0-9][A-Z0-9-]{4,}\\b|" + words(["booking", "reservation", "pnr", "reference", "ref"]) + "[\\s.:#-]+(?-i:[A-Z]{6})\\b"),
            rule(.reference, "(?<![\\w#])#\\d{6,}\\b"),
            rule(.identity, words([
                "passport", "visa", "driver'?s licen[cs]e", "licen[cs]e number", "date of birth", "dob", "tax file number", "tfn",
                "national insurance", "ni number", "social security", "ssn", "medicare", "birth certificate", "citizenship", "residency",
                "immigration", "gov\\.uk", "id card"
            ])),
            rule(.money, words([
                "bank", "banking", "bsb", "iban", "sort code", "account number", "acct", "credit card", "debit card", "card number",
                "cvv", "pin number", "mortgage", "salary", "payslip", "pay slip", "tax return", "invoice", "loan", "superannuation", "super fund",
                "pension", "net worth", "brokerage", "paypal", "revolut", "monzo", "stripe payout"
            ])),
            // An amount of 100 or more, or in thousands or millions: a
            // coding agent's screen is full of cents (what each thread
            // cost), which aren't anyone's business either way.
            rule(.money, "(?<![\\w])(?:[$£€¥]|A\\$|US\\$|AU\\$)\\s?\\d[\\d,]*(?:\\.\\d+)?(?:\\s?[kKmM]\\b)?|\\b\\d[\\d,]*(?:\\.\\d+)?\\s?(?:USD|AUD|GBP|EUR|dollars|pounds|quid)\\b",
                 accept: { amount in
                     let number = Double(amount.filter { $0.isNumber || $0 == "." }) ?? 0
                     return number >= 100 || amount.last.map { "kKmM".contains($0) } == true
                 }),
            rule(.crypto, words([
                "crypto", "cryptocurrency", "bitcoin", "btc", "ethereum", "eth", "solana", "usdc", "usdt", "wallet", "seed phrase",
                "recovery phrase", "private key", "trezor", "ledger nano", "ledger live", "coinbase", "binance", "kraken", "metamask",
                "exchange account", "staking", "nft"
            ])),
            rule(.crypto, "\\b(?:bc1|[13])[a-km-zA-HJ-NP-Z1-9]{25,39}\\b|\\b0x[a-fA-F0-9]{40}\\b", caseSensitive: true),
            rule(.travel, words([
                "flight", "flights", "boarding pass", "check-in", "departure", "departs", "arrival", "seat \\d+[A-K]",
                "qantas", "jetstar", "virgin australia", "british airways", "emirates", "singapore airlines", "airbnb", "hotel", "itinerary",
                "frequent flyer"
            ])),
            // Flight numbers: QF 12, BA0016, VA 821.
            rule(.travel, "\\b(?:QF|JQ|VA|BA|EK|SQ|NZ|CX|UA|AA|DL|QR|VS|EY|LH|AF|KL)\\s?\\d{1,4}\\b", caseSensitive: true),
            rule(.secret, "\\b(?:sk|pk|rk)[-_](?:live|test|proj|ant)?[-_]?[A-Za-z0-9_-]{16,}|\\bgh[pousr]_[A-Za-z0-9]{20,}|\\bgithub_pat_[A-Za-z0-9_]{20,}|\\bxox[abposr]-[A-Za-z0-9-]{10,}|\\bAKIA[0-9A-Z]{16}\\b|\\bAIza[0-9A-Za-z_-]{30,}|\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY|\\b(?:prod|dev|preview|project):[a-z0-9-]+\\|[A-Za-z0-9+/=]{20,}|\\bBearer\\s+[A-Za-z0-9._~+/-]{20,}", caseSensitive: true),
            rule(.secret, words(["password", "passcode", "api key", "api_key", "apikey", "secret", "access token", "auth token", "deploy key", "client secret", "2fa code", "verification code", "one-time code"]) + "\\s*[:=]\\s*\\S+"),
            // A long run of letters and digits mixed: a key or a token, not a word.
            // No slashes: a path (/var/folders/rh/6mwtgc150...) isn't a key.
            rule(.secret, "(?<![\\w/.-])[A-Za-z0-9_+=-]{32,}(?![\\w/.-])", caseSensitive: true, accept: { token in
                let letters = token.filter(\.isLetter).count, numbers = digits(token)
                return letters >= 8 && numbers >= 4 && token.contains(where: \.isUppercase) && token.contains(where: \.isLowercase)
            }),
            rule(.marked, words([
                "confidential", "internal only", "convex internal", "company internal", "do not share", "don'?t share", "not for public",
                "not public yet", "under nda", "nda", "embargo(?:ed)?", "before (?:it|they|this|these) go(?:es)? public", "go public",
                "needs? (?:his|her|their|my) (?:ok|okay|approval|sign[- ]off)", "has to ok", "must ok", "ok (?:them|these|it) before",
                "sign[- ]off", "not yet approved", "unreleased", "private beta", "stealth", "secret project", "off the record"
            ])),
            // Family and health: a family member's phone came up in the
            // launch video's projects answer.
            rule(.personal, "\\b(?:my|your|his|her|our|their)\\s+(?:dad|mum|mom|father|mother|wife|husband|partner|son|daughter|kids?|children|brother|sister|grandma|grandpa|parents)\\b|\\b(?:Dad|Mum|Mom)'s\\b|" + words([
                "doctor'?s appointment", "gp appointment", "dentist", "hospital", "diagnosis", "prescription", "therapy", "therapist",
                "blood test", "medical", "pregnan(?:t|cy)", "surgery", "school pickup", "school run"
            ]))
        ]
    }()
}
