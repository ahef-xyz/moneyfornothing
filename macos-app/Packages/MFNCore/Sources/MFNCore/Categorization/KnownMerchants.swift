import Foundation

/// The list behind `KnownMerchantStage`: German brands and booking-text patterns → catalog IDs.
///
/// Matching works on normalized words (`MerchantText.words`): case, accents and umlaut spellings
/// (ä/ae) ignored, punctuation and legal forms (GmbH, AG …) and card phrases (VISA,
/// Debitkartenumsatz …) dropped, store numbers split off ("REWE1234" → "rewe 1234").
///
/// - **Brands** match whole words in order ("db" matches "DB Vertrieb", never "Dbx"), by default
///   only in the counterpart name. If the name is empty, only card phrases, or a payment service
///   (PayPal, Klarna, SumUp …), the purpose is searched instead ("PayPal … Spotify" → abos).
/// - **Keywords** match inside a word, for German compounds ("Stadtapotheke", "Haftpflichtversicherung").
/// - `anywhere` entries also search the purpose ("Bargeldauszahlung GAA …", "Rundfunkbeitrag").
/// - `direction` limits an entry to inflows or outflows (Gehalt only for money coming in);
///   `inflow` gives a different category for inflows (Krankenkasse: Beitrag → versicherung,
///   Erstattung → erstattung).
///
/// Several hits: direction-specific entries first, then name before purpose, brand before
/// keyword, then the longest pattern ("Amazon Prime" → abos beats "Amazon" → online_shopping).
/// Income categories never go to outflows.
///
/// Names that are also common first or last names (Norma, Müller, Otto, Zara, Conrad, Douglas …)
/// are left out or only listed with a second word.
enum KnownMerchants {
    enum Direction: Sendable { case any, inflow, outflow }

    struct Entry: Sendable {
        var words: [String]
        var category: CategoryID
        var inflowCategory: CategoryID?
        /// Keyword: match inside a word instead of whole words.
        var inWord: Bool
        var anywhere: Bool
        var direction: Direction
        var length: Int { words.reduce(0) { $0 + $1.count } + words.count - 1 }
    }

    static func category(for transaction: Transaction) -> CategoryID? {
        let amount = transaction.amountCents
        let name = MerchantText.words(transaction.counterpartName)
        let viaPaymentService = name.contains { intermediaries.contains($0) }
        let searchPurposeForBrands = name.isEmpty || viaPaymentService
        let purpose = MerchantText.words(transaction.purpose)

        var best: (entry: Entry, inName: Bool)?
        func consider(_ entry: Entry, inName: Bool) {
            switch entry.direction {
            case .any: break
            case .inflow: guard amount > 0 else { return }
            case .outflow: guard amount < 0 else { return }
            }
            guard let current = best else { best = (entry, inName); return }
            func rank(_ e: Entry, _ n: Bool) -> (Int, Int, Int, Int) {
                (e.direction == .any ? 0 : 1, n ? 1 : 0, e.inWord ? 0 : 1, e.length)
            }
            if rank(entry, inName) > rank(current.entry, current.inName) { best = (entry, inName) }
        }
        // A payment service's name is noise ("S.C.A" would be C&A).
        for entry in hits(in: viaPaymentService ? [] : name) { consider(entry, inName: true) }
        for entry in hits(in: purpose) where entry.anywhere || searchPurposeForBrands {
            consider(entry, inName: false)
        }
        guard let entry = best?.entry else { return nil }
        let category = amount > 0 ? (entry.inflowCategory ?? entry.category) : entry.category
        if amount < 0, CategoryCatalog.info(category)?.isIncome == true { return nil }
        return category
    }

    /// Entries whose pattern occurs in the words, in list order.
    private static func hits(in words: [String]) -> [Entry] {
        guard !words.isEmpty else { return [] }
        var found: [Int] = []
        for start in words.indices {
            for index in brandIndex[words[start]] ?? [] {
                let pattern = entries[index].words
                guard start + pattern.count <= words.count else { continue }
                if Array(words[start..<(start + pattern.count)]) == pattern { found.append(index) }
            }
        }
        for index in keywordIndices where words.contains(where: { $0.contains(entries[index].words[0]) }) {
            found.append(index)
        }
        return Set(found).sorted().map { entries[$0] }
    }

    /// Brand entries by first word.
    private static let brandIndex: [String: [Int]] = {
        var index: [String: [Int]] = [:]
        for (i, entry) in entries.enumerated() where !entry.inWord {
            if let first = entry.words.first { index[first, default: []].append(i) }
        }
        return index
    }()

    private static let keywordIndices: [Int] = entries.indices.filter { entries[$0].inWord && !entries[$0].words.isEmpty }

    /// Payment services: the real merchant is in the purpose.
    static let intermediaries: Set<String> = [
        "paypal", "klarna", "sumup", "stripe", "adyen", "zettle", "mollie", "unzer", "payone", "nexi",
        "worldline", "concardis", "giropay", "paydirekt", "wero", "ratepay", "computop", "sofort",
    ]

    // MARK: - The list

    private static func brands(_ category: CategoryID, inflow: CategoryID? = nil, anywhere: Bool = false, direction: Direction = .any, _ patterns: String...) -> [Entry] {
        patterns.map { Entry(words: MerchantText.words($0), category: category, inflowCategory: inflow, inWord: false, anywhere: anywhere, direction: direction) }
    }

    private static func keywords(_ category: CategoryID, inflow: CategoryID? = nil, anywhere: Bool = false, direction: Direction = .any, _ patterns: String...) -> [Entry] {
        // Several words: whole words in order (an in-word "kfz" would hit "Kfzsteuer").
        patterns.map {
            let words = MerchantText.words($0)
            return Entry(words: words, category: category, inflowCategory: inflow, inWord: words.count == 1, anywhere: anywhere, direction: direction)
        }
    }

    static let entries: [Entry] = {
        var e: [Entry] = []
        // Lebensmittel
        e += brands("lebensmittel", "REWE", "EDEKA", "E center", "Marktkauf", "ALDI", "ALDI Nord", "ALDI Süd", "Lidl",
                    "Kaufland", "Netto", "Netto Marken-Discount", "Penny", "Globus", "tegut", "famila", "nahkauf",
                    "denns", "Alnatura", "Basic Bio", "Bio Company", "Wasgau", "Feneberg", "V-Markt", "Mix Markt",
                    "Flink", "Picnic", "Knuspr", "Nah und Gut", "Lidl Plus", "Edeka Center", "Kamps", "Ditsch",
                    "Le Crobag", "BackWerk", "Rewe Lieferservice")
        e += keywords("lebensmittel", "bäckerei", "backhaus", "metzgerei", "fleischerei", "getränkemarkt", "wochenmarkt")
        // Drogerie
        e += brands("drogerie", "dm", "dm-drogerie markt", "Rossmann", "Budni", "Müller Handels", "Drogerie Müller",
                    "Douglas Parfümerie", "Parfümerie Douglas", "Flaconi")
        e += keywords("drogerie", "drogeriemarkt", "parfümerie")
        // Restaurant & Café, Lieferdienste
        e += brands("restaurant", "McDonald's", "Burger King", "KFC", "Subway", "Starbucks", "Vapiano", "Lieferando",
                    "Wolt", "Uber Eats", "Domino's", "Pizza Hut", "Nordsee", "Coffee Fellows", "Joey's", "Block House",
                    "Hans im Glück", "L'Osteria", "dean&david", "Peter Pane", "Five Guys", "Espresso House",
                    "Balzac Coffee", "Yormas", "Too Good To Go")
        e += keywords("restaurant", "restaurant", "pizzeria", "ristorante", "trattoria", "gaststätte", "imbiss",
                      "döner", "kebab", "sushi", "brauhaus", "biergarten")
        e += brands("restaurant", "Cafe", "Café", "Bistro", "Kantine", "Mensa")
        // Tanken & Laden
        e += brands("tanken", "Aral", "Shell", "Esso", "Total", "TotalEnergies", "JET", "Avia", "Agip", "Eni", "Orlen",
                    "Star Tankstelle", "HEM Tankstelle", "OMV", "bft", "Raiffeisen Tankstelle", "Ionity", "EnBW mobility",
                    "Tesla Supercharger", "Allego", "EWE Go", "Maingau Autostrom")
        e += keywords("tanken", "tankstelle", "supercharger", "ladestation")
        // ÖPNV & Bahn
        e += brands("oepnv", "DB", "DB Vertrieb", "DB Fernverkehr", "Deutsche Bahn", "BVG", "MVG", "HVV", "VRS", "KVB",
                    "RMV", "VBB", "VVS", "VRR", "Rheinbahn", "üstra", "DVB", "LVB", "KVV", "VGN", "SSB", "Bogestra",
                    "Hochbahn", "FlixBus", "FlixTrain", "Flix", "Metronom", "Go-Ahead", "National Express", "Abellio",
                    "Transdev", "erixx", "eurobahn", "Westfalenbahn", "ODEG", "S-Bahn", "Verkehrsbetriebe")
        e += keywords("oepnv", "deutschlandticket", "verkehrsverbund", "verkehrsbetrieb")
        // Taxi & Sharing
        e += brands("taxi_sharing", "Uber", "Bolt", "FREENOW", "Free Now", "Share Now", "Sixt Share", "Miles Mobility",
                    "TIER Mobility", "Voi", "Lime", "Cambio", "stadtmobil", "Nextbike", "Call a Bike", "WeShare")
        e += keywords("taxi_sharing", "taxi")
        // Auto & Werkstatt, Parken
        e += brands("auto", "ATU", "A.T.U", "Pitstop", "ADAC", "TÜV", "Dekra", "Euromaster", "Vergölst", "Carglass",
                    "Apcoa", "Contipark", "EasyPark", "PayByPhone", "Park Now", "Q-Park")
        e += keywords("auto", "parkhaus", "autowerkstatt", "kfz werkstatt", "autohaus", "waschstraße")
        // Abos & Streaming
        e += brands("abos", "Netflix", "Spotify", "Disney Plus", "Disney+", "Amazon Prime", "Prime Video", "Apple.com/bill",
                    "iTunes", "Google Play", "Google One", "YouTube", "DAZN", "Sky Deutschland", "WOW TV", "RTL+", "RTL Plus",
                    "Joyn", "Audible", "Deezer", "Tidal", "Paramount", "Crunchyroll", "Storytel", "Kindle Unlimited",
                    "iCloud", "Patreon", "Twitch", "PlayStation Network", "Xbox Game Pass", "OpenAI", "ChatGPT",
                    "Spiegel", "Zeit Verlag", "Süddeutsche Zeitung", "FAZ", "Blinkist", "Readly", "Waipu")
        // Internet & Telefon
        e += brands("internet_telefon", "Telekom", "Telekom Deutschland", "Vodafone", "O2", "Telefonica", "1&1", "1und1",
                    "congstar", "freenet", "mobilcom-debitel", "klarmobil", "ALDI TALK", "Lidl Connect", "Blau Mobilfunk",
                    "Fonic", "simyo", "WinSIM", "Drillisch", "NetCologne", "M-net", "Pyur", "Unitymedia", "EWE TEL",
                    "Deutsche Glasfaser", "htp", "easybell", "sipgate", "Tele Columbus", "Telekom Mobilfunk")
        // Strom, Gas & Wasser
        e += brands("nebenkosten", "E.ON", "EON", "Vattenfall", "EnBW", "RWE", "eprimo", "Yello", "LichtBlick", "Naturstrom",
                    "Tibber", "Ostrom", "Octopus Energy", "Polarstern", "Mainova", "RheinEnergie", "SWM", "N-ERGIE",
                    "Entega", "GASAG", "EWE", "badenova", "DREWAG", "enercity", "Stromio", "ExtraEnergie")
        e += keywords("nebenkosten", "stadtwerke", "wasserwerk", "wasserversorgung", "abwasser", "energieversorg", "fernwärme")
        // Miete & Wohnen
        e += brands("miete", "Vonovia", "LEG Wohnen", "Deutsche Wohnen", "Vivawest", "Gewobag", "Degewo", "Howoge",
                    "Gesobau", "GAG Immobilien", "Wohnungsgenossenschaft")
        e += keywords("miete", "hausverwaltung", "wohnungsbau", "baugenossenschaft", "hausgeld")
        e += keywords("miete", anywhere: true, direction: .outflow, "mietzahlung", "kaltmiete", "warmmiete")
        // Haushalt & Einrichtung
        e += brands("haushalt", "IKEA", "OBI", "Hornbach", "Bauhaus", "toom", "hagebau", "Globus Baumarkt", "Poco",
                    "XXXLutz", "Höffner", "Roller", "JYSK", "TEDi", "Nanu-Nana", "Butlers", "Westwing", "home24", "Dehner",
                    "Fressnapf", "Zooplus", "Depot Gries", "Kodi", "Thomas Philipps", "Hammer Fachmarkt")
        e += keywords("haushalt", "baumarkt", "möbel", "gartencenter")
        // Kleidung
        e += brands("kleidung", "H&M", "Zara Deutschland", "zara.com", "C&A", "Primark", "KiK", "Takko", "Deichmann", "Zalando", "About You",
                    "Snipes", "Foot Locker", "Esprit", "s.Oliver", "TK Maxx", "Peek & Cloppenburg", "Breuninger",
                    "Uniqlo", "Jack & Jones", "New Yorker", "Ernsting's family", "bonprix", "Shein", "Galeria",
                    "Tom Tailor", "Humanic", "Görtz", "Vinted")
        // Elektronik & Software
        e += brands("elektronik", "MediaMarkt", "Media Markt", "Saturn", "Cyberport", "notebooksbilliger", "Alternate",
                    "Conrad Electronic", "Apple Store", "Apple", "Gravis", "Mindfactory", "Caseking", "Steam", "Steampowered",
                    "Microsoft", "Adobe", "JetBrains", "GitHub", "Google Cloud", "Samsung", "Euronics", "Nintendo",
                    "Expert Technomarkt", "Anker")
        // Online-Shopping
        e += brands("online_shopping", "Amazon", "AMZN", "AMZN Mktp", "Amazon Marketplace", "eBay", "Otto Versand", "otto.de",
                    "Temu", "AliExpress", "Etsy", "Galaxus", "momox", "reBuy", "medimops", "Wish", "Tchibo", "QVC")
        // Freizeit & Kultur
        e += brands("freizeit", "CinemaxX", "Cineplex", "UCI", "CineStar", "Eventim", "Ticketmaster", "Reservix",
                    "Thalia Bücher", "thalia.de", "Hugendubel", "Weltbild", "Lotto", "Phantasialand", "Europa-Park", "Kinopolis", "Mayersche")
        e += keywords("freizeit", "kino", "museum", "theater", "konzerthaus", "buchhandlung", "tierpark", "freizeitpark")
        e += brands("freizeit", "Zoo")
        // Sport & Fitness
        e += brands("sport", "McFit", "FitX", "John Reed", "Clever Fit", "Fitness First", "Urban Sports Club", "Eversports",
                    "Decathlon", "SportScheck", "Intersport", "Bergfreunde", "Globetrotter", "Jd Sports", "Bäderbetriebe",
                    "Boulderwelt", "Kieser Training")
        e += keywords("sport", "fitness", "schwimmbad", "hallenbad", "freibad", "sportverein", "kletterhalle", "boulder")
        // Reisen & Urlaub
        e += brands("reisen", "Lufthansa", "Eurowings", "Ryanair", "easyJet", "Condor", "TUIfly", "TUI", "Booking.com",
                    "Airbnb", "Expedia", "HRS", "HolidayCheck", "Motel One", "ibis", "Opodo", "Wizz Air", "KLM",
                    "Air France", "British Airways", "AIDA Cruises", "Europcar", "Hertz Autovermietung", "Avis", "Sixt", "FeWo-direkt",
                    "Hilton", "Marriott", "NH Hotels", "Meininger", "A&O Hostels", "Center Parcs")
        e += keywords("reisen", "hotel", "hostel", "flughafen", "reisebüro", "ferienwohnung")
        // Arzt & Apotheke
        e += brands("gesundheit", "DocMorris", "Shop Apotheke", "medpex", "Sanicare", "Fielmann", "Apollo Optik",
                    "Dr. med.", "Mister Spex")
        e += keywords("gesundheit", "apotheke", "zahnarzt", "arztpraxis", "physiotherap", "krankenhaus", "klinikum",
                      "praxis dr", "kieferorthop", "orthopäd", "optiker", "hörgeräte", "heilpraktiker")
        e += brands("gesundheit", "Praxis")
        // Versicherungen, Krankenkassen
        e += brands("versicherung", inflow: "erstattung", "Allianz", "AXA", "ERGO", "HUK-Coburg", "HUK24", "HUK", "DEVK",
                    "Generali", "Signal Iduna", "Debeka", "R+V", "LVM", "Provinzial", "Württembergische", "Gothaer",
                    "Zurich", "HDI", "ARAG", "Roland Rechtsschutz", "Barmenia", "HanseMerkur", "Hanse Merkur",
                    "Continentale", "Alte Leipziger", "CosmosDirekt", "Verti", "DA Direkt", "WGV", "Getsafe", "Nürnberger",
                    "VHV", "Helvetia", "Techniker Krankenkasse", "AOK", "Barmer", "DAK", "DAK-Gesundheit", "IKK", "BKK",
                    "KKH", "hkk", "Knappschaft", "Continentale Kranken", "Allianz Private Krankenversicherung")
        e += keywords("versicherung", inflow: "erstattung", "versicherung", "krankenkasse", "krankenversicherung")
        e += brands("versicherung", inflow: "einnahmen_sonstige", "Deutsche Rentenversicherung")
        // Kinder & Betreuung
        e += brands("kinder", "Kita", "myToys", "Smyths Toys", "Toys R Us", "JAKO-O", "Kinderkrippe")
        e += keywords("kinder", "kindergarten", "kindertagesstätte", "kinderkrippe", "elternbeitrag", "tagesmutter",
                      "spielwaren", "kinderbetreuung", "musikschule")
        // Geschenke & Spenden
        e += brands("geschenke_spenden", "UNICEF", "Ärzte ohne Grenzen", "Greenpeace", "WWF", "SOS-Kinderdorf",
                    "Deutsches Rotes Kreuz", "DRK", "Caritas", "Diakonie", "Misereor", "Brot für die Welt", "Amnesty",
                    "betterplace", "GoFundMe", "NABU", "Wikimedia", "Welthungerhilfe", "Plan International", "Tafel")
        e += keywords("geschenke_spenden", anywhere: true, direction: .outflow, "spende")
        e += keywords("geschenke_spenden", "blumenhaus", "blumenladen", "floristik")
        // Sparen & Anlegen
        e += brands("sparen_anlegen", "Trade Republic", "Scalable Capital", "flatex", "Smartbroker", "justTRADE", "onvista",
                    "Union Investment", "Deka", "DWS", "fondsdepot", "ebase", "Raisin", "WeltSparen", "Zinspilot",
                    "LBS", "Wüstenrot", "Schwäbisch Hall", "Bausparkasse")
        e += keywords("sparen_anlegen", anywhere: true, direction: .outflow, "sparplan", "bausparvertrag")
        e += keywords("sparen_anlegen", "bausparkasse")
        // Kredit & Kreditkarte
        e += keywords("kredit", anywhere: true, "kreditkartenabrechnung", "kartenabrechnung", "darlehen", "tilgung", "ratenkredit")
        e += brands("kredit", anywhere: true, "Kreditkarte Abrechnung", "Ausgleich Kreditkarte")
        e += brands("kredit", "auxmoney", "Santander Consumer", "Advanzia", "Hanseatic Bank", "Barclaycard", "TF Bank",
                    "creditplus", "Targobank Kredit")
        e += keywords("miete", anywhere: true, direction: .outflow, "baufinanzierung", "immobilienkredit")
        // Bankgebühren
        e += keywords("gebuehren", anywhere: true, "kontoführung", "kontofuhrung", "kontoentgelt", "kartenentgelt",
                      "jahresgebühr", "auslandseinsatz", "fremdwährungsentgelt", "fremdwahrungsentgelt", "sollzinsen",
                      "überziehungszinsen", "dispozinsen", "kontogebühr", "buchungsentgelt", "entgeltabschluss")
        // Steuern & Abgaben
        e += brands("steuern", "Bundeskasse", "Beitragsservice", "Rundfunk ARD", "ARD ZDF Deutschlandradio", "Hauptzollamt",
                    "Stadtkasse", "Gemeindekasse", "Landeshauptkasse", "Kreiskasse")
        e += keywords("steuern", "finanzamt", "steuerverwaltung", "finanzkasse")
        e += keywords("steuern", anywhere: true, "rundfunkbeitrag", "grundsteuer", "hundesteuer", "gewerbesteuer",
                      "einkommensteuer", "kfzsteuer", "umsatzsteuer", "zweitwohnungsteuer")
        e += brands("steuern", anywhere: true, "Kfz-Steuer", "Kfz Steuer")
        // Bargeld
        e += keywords("bargeld", anywhere: true, "geldautomat", "bargeldauszahlung", "bargeldabhebung", "bargeldeinzahlung",
                      "auszahlung gaa", "barauszahlung", "bareinzahlung")
        e += brands("bargeld", anywhere: true, "GAA", "ATM", "Cash Group", "Geldautomat")
        // Zinsen & Dividenden
        e += keywords("zinsen", anywhere: true, direction: .inflow, "habenzinsen", "guthabenzinsen", "zinsgutschrift",
                      "dividende", "ertragsgutschrift", "zinsertrag", "ausschüttung", "zinsen")
        // Einnahmen
        e += keywords("gehalt", anywhere: true, direction: .inflow, "gehalt", "lohnabrechnung", "bezüge", "lohnzahlung",
                      "entgeltabrechnung", "gehaltszahlung")
        e += brands("gehalt", anywhere: true, direction: .inflow, "Lohn")
        e += keywords("erstattung", anywhere: true, direction: .inflow, "erstattung", "rückzahlung", "gutschrift retoure")
        e += brands("einnahmen_sonstige", anywhere: true, direction: .inflow, "Familienkasse", "Kindergeld", "Elterngeld",
                    "Bundesagentur für Arbeit", "Arbeitslosengeld")
        return e
    }()
}

/// Text normalization for merchant matching.
enum MerchantText {
    /// Legal forms, card phrases and similar noise around merchant names.
    static let noise: Set<String> = [
        "gmbh", "mbh", "co", "kg", "ag", "se", "ohg", "ug", "kgaa", "ltd", "inc", "llc", "plc", "bv", "nv", "sarl",
        "visa", "mastercard", "maestro", "girocard", "debitkartenumsatz", "kreditkartenumsatz", "debitkarte",
        "kartenzahlung", "kartenumsatz", "lastschrift", "sepa", "pos", "ec", "nfc", "kontaktlos", "einzug",
        "basislastschrift", "folgelastschrift", "erstlastschrift", "svwz", "eref", "mref", "cred", "abwa", "sagt", "danke",
    ]

    static func words(_ raw: String) -> [String] {
        var text = raw.lowercased()
        for (umlaut, spelled) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] {
            text = text.replacingOccurrences(of: umlaut, with: spelled)
        }
        text = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
        var cleaned = ""
        cleaned.reserveCapacity(text.count)
        for character in text {
            if character == "'" || character == "’" || character == "`" { continue }
            cleaned.append(character.isLetter || character.isNumber ? character : " ")
        }
        var result: [String] = []
        for word in cleaned.split(separator: " ") {
            for part in splitStoreNumber(word) where !noise.contains(part) {
                result.append(part)
            }
        }
        return result
    }

    /// "rewe1234" → "rewe", "1234"; short prefixes stay ("o2", "e5").
    private static func splitStoreNumber(_ word: Substring) -> [String] {
        guard let firstDigit = word.firstIndex(where: \.isNumber) else { return [String(word)] }
        let letters = word[..<firstDigit]
        guard letters.count >= 3, letters.allSatisfy(\.isLetter) else { return [String(word)] }
        return [String(letters), String(word[firstDigit...])]
    }
}
