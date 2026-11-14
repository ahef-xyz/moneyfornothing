#!/usr/bin/env python3
"""Generates the synthetic eval set (300 bookings). No real data: merchants are public brand
names / generic businesses, all references, creditor IDs and amounts are random."""
import json, random, sys, datetime

rng = random.Random(20261110)

def ref(n=10):
    return "".join(rng.choice("0123456789") for _ in range(n))

def aref(n=12):
    return "".join(rng.choice("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789") for _ in range(n))

def cred():
    return f"DE{rng.randint(10,99)}ZZZ0000{ref(7)}"

CREDITORS = {}
def cred_for(m):
    if m not in CREDITORS:
        CREDITORS[m] = cred()
    return CREDITORS[m]

MANDATES = {}
def mref_for(m):
    if m not in MANDATES:
        MANDATES[m] = f"M{aref(10)}"
    return MANDATES[m]

def sepa(m, text, with_mandate=True):
    p = f"EREF+{aref(14)} "
    if with_mandate:
        p += f"MREF+{mref_for(m)} CRED+{cred_for(m)} "
    return p + f"SVWZ+{text}"

def card(m, city):
    d = rng.randint(1, 28); mo = rng.randint(1, 12)
    return f"{m}//{city}/DE", f"VISA Debitkartenumsatz {d:02d}.{mo:02d}. {rng.randint(8,21):02d}:{rng.randint(0,59):02d} Karte 1 Folgenr. {rng.randint(1,99):02d}"

def girocard(m, city):
    return m, f"Kartenzahlung girocard {m} {city} {ref(8)} {rng.randint(1,28):02d}.{rng.randint(1,12):02d}"

CITIES = ["Berlin", "Hamburg", "Muenchen", "Koeln", "Leipzig", "Dortmund", "Hannover", "Bremen", "Dresden", "Mainz"]

def euros(lo, hi):
    return rng.randint(int(lo * 100), int(hi * 100))

# Each entry: category -> list of generator functions returning (merchant, purpose, cents, accountType, creditor?, mref?)
G = {}

def add(cat, fn, times):
    G.setdefault(cat, []).append((fn, times))

def m_card(name, lo, hi, acct="giro", style="visa"):
    def f():
        city = rng.choice(CITIES)
        mer, pur = card(name, city) if style == "visa" else girocard(name, city)
        return mer, pur, -euros(lo, hi), acct, None, None
    return f

def m_cc(name, lo, hi):
    # credit card statement line: merchant + city, terse purpose
    def f():
        return f"{name} {rng.choice(CITIES).upper()}", "", -euros(lo, hi), "card", None, None
    return f

def m_sepa(name, text, lo, hi, acct="giro", fixed=None, mandate=True):
    def f():
        cents = -(fixed if fixed is not None else euros(lo, hi))
        t = text.format(ref=ref(8), aref=aref(8), mon=rng.choice(["01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12"]), year=rng.choice(["2025", "2026"]))
        return name, sepa(name, t, mandate), cents, acct, (cred_for(name) if mandate else None), (mref_for(name) if mandate else None)
    return f

def m_in(name, text, lo, hi, acct="giro"):
    def f():
        t = text.format(ref=ref(8), aref=aref(8), mon=rng.choice(["01","02","03","04","05","06","07","08","09","10","11","12"]), year=rng.choice(["2025","2026"]))
        return name, f"EREF+{aref(14)} SVWZ+{t}", euros(lo, hi), acct, None, None
    return f

def m_plain(name, text, cents_fn, acct="giro"):
    def f():
        t = text.format(ref=ref(8), aref=aref(8), mon=rng.choice(["01","02","03","04","05","06","07","08","09","10","11","12"]), year=rng.choice(["2025","2026"]))
        return name, t, cents_fn(), acct, None, None
    return f

neg = lambda lo, hi: (lambda: -euros(lo, hi))
pos = lambda lo, hi: (lambda: euros(lo, hi))

# Einnahmen
add("gehalt", m_in("Muster Software GmbH", "Gehalt {mon}/{year} Personalnr {ref}", 3200, 3600), 4)
add("gehalt", m_in("Stadtklinik Nord gGmbH", "LOHN/GEHALT {mon}.{year}", 2600, 2900), 3)
add("gehalt", m_in("Bundesagentur fuer Arbeit", "Elterngeld Leistung {mon}/{year} Kd-Nr {ref}", 1200, 1800), 1)
add("gehalt", m_in("Beispiel Logistik AG", "Entgeltabrechnung {mon} {year}", 2100, 2300), 1)
add("erstattung", m_in("AMAZON PAYMENTS EUROPE S.C.A.", "Erstattung Bestellung 302-{ref}", 12, 90), 3)
add("erstattung", m_in("Techniker Krankenkasse", "Erstattung Bonusprogramm {year}", 50, 150), 2)
add("erstattung", m_in("Zalando SE", "Rueckerstattung Retoure {ref}", 30, 120), 2)
add("erstattung", m_in("Finanzamt Musterstadt", "Einkommensteuer {year} Erstattung StNr {ref}", 300, 1200), 1)
add("erstattung", m_in("Deutsche Bahn Fernverkehr", "Fahrgastrechte Entschaedigung {aref}", 15, 60), 1)
add("zinsen", m_plain("", "Zinsen {mon}/{year} Tagesgeld", pos(5, 60), "tagesgeld"), 4)
add("zinsen", m_plain("Trade Republic", "Zinszahlung", pos(10, 45), "giro"), 2)
add("zinsen", m_plain("", "Ertragsgutschrift Ausschuettung ISIN IE00B4L5Y983", pos(20, 80), "depot"), 2)
add("zinsen", m_plain("", "Dividende ISIN DE0007164600", pos(30, 90), "depot"), 1)
add("einnahmen_sonstige", m_in("Kleinanzeigen Kaeuferin", "Kleinanzeigen Fahrrad", 80, 250), 2)
add("einnahmen_sonstige", m_in("Max Beispiel", "Anteil Ferienwohnung", 100, 400), 2)
add("einnahmen_sonstige", m_in("PayPal Europe S.a.r.l. et Cie S.C.A", "PayPal Guthaben Auszahlung {ref}", 20, 200), 2)
add("einnahmen_sonstige", m_in("Vinted UAB", "Auszahlung Verkauf {ref}", 10, 60), 2)
add("einnahmen_sonstige", m_in("Muster Hausverwaltung", "Nebenkostenguthaben {year} Whg 3", 90, 300), 1)

# Wohnen
add("miete", m_sepa("Muster Hausverwaltung", "Miete {mon}/{year} Whg 3 OG links", 0, 0, fixed=98000, mandate=False), 4)
add("miete", m_sepa("Wohnbau Beispiel eG", "Nutzungsentgelt {mon} {year}", 0, 0, fixed=74500), 3)
add("miete", m_sepa("Sparkasse Beispielstadt", "Darlehen {ref} Rate Baufinanzierung", 0, 0, fixed=125000), 2)
add("nebenkosten", m_sepa("Stadtwerke Musterstadt", "Abschlag Strom {mon}/{year} Vertragskonto {ref}", 0, 0, fixed=6800), 3)
add("nebenkosten", m_sepa("Vattenfall Europe Sales GmbH", "Abschlag Gas {mon}/{year} VK {ref}", 0, 0, fixed=9500), 2)
add("nebenkosten", m_sepa("E.ON Energie Deutschland", "Abschlagszahlung Strom VK {ref}", 0, 0, fixed=7200), 2)
add("nebenkosten", m_sepa("Berliner Wasserbetriebe", "Wasser Abschlag {mon}/{year}", 0, 0, fixed=3100), 1)
add("nebenkosten", m_sepa("Tibber Deutschland GmbH", "Stromrechnung {mon} {year}", 40, 90), 1)
add("internet_telefon", m_sepa("Telekom Deutschland GmbH", "Rechnung {mon}/{year} Kundenkonto {ref} MagentaZuhause", 0, 0, fixed=4495), 3)
add("internet_telefon", m_sepa("Vodafone GmbH", "Vodafone Mobilfunk Rechnung {ref}", 25, 40), 2)
add("internet_telefon", m_sepa("1&1 Telecom GmbH", "1&1 DSL Rechnung {ref}", 0, 0, fixed=3999), 2)
add("internet_telefon", m_sepa("congstar", "congstar Rechnung {mon}.{year}", 10, 20), 1)
add("internet_telefon", m_sepa("O2 Telefonica Germany", "o2 Mobilfunk {ref}", 15, 30), 1)
add("haushalt", m_card("IKEA Deutschland", 20, 300), 3)
add("haushalt", m_card("OBI Markt", 10, 150), 2)
add("haushalt", m_card("Bauhaus", 15, 120, style="girocard"), 2)
add("haushalt", m_card("Hornbach Baumarkt", 20, 200), 1)
add("haushalt", m_card("Depot Wohnaccessoires", 10, 60), 1)

# Lebenshaltung
add("lebensmittel", m_card("REWE Markt GmbH", 8, 95, style="girocard"), 3)
add("lebensmittel", m_card("ALDI SUED", 10, 70), 2)
add("lebensmittel", m_card("EDEKA Center", 10, 110), 2)
add("lebensmittel", m_card("LIDL DIENSTLEISTUNG", 8, 60, style="girocard"), 2)
add("lebensmittel", m_cc("KAUFLAND", 15, 90), 1)
add("lebensmittel", m_card("Netto Marken-Discount", 5, 45), 1)
add("lebensmittel", m_card("Baeckerei Beispiel", 3, 12), 1)
add("restaurant", m_card("Pizzeria Da Mario", 18, 60), 2)
add("restaurant", m_card("Starbucks Coffee", 4, 12), 2)
add("restaurant", m_cc("MCDONALDS", 7, 20), 2)
add("restaurant", m_plain("Lieferando.de", "Lieferando Bestellung {ref}", neg(15, 45)), 2)
add("restaurant", m_card("Cafe am Markt", 6, 25), 1)
add("drogerie", m_card("dm-drogerie markt", 5, 45, style="girocard"), 3)
add("drogerie", m_card("ROSSMANN", 4, 35), 3)
add("drogerie", m_card("Mueller Drogerie", 8, 40), 2)
add("drogerie", m_cc("DOUGLAS", 20, 80), 1)

# Mobilitaet
add("tanken", m_card("ARAL Station", 40, 95), 3)
add("tanken", m_card("Shell Deutschland", 35, 90), 2)
add("tanken", m_cc("TOTALENERGIES", 30, 85), 2)
add("tanken", m_plain("EnBW mobility+", "Ladevorgang {ref} EnBW mobility+", neg(8, 30)), 1)
add("tanken", m_card("JET Tankstelle", 30, 80), 1)
add("oepnv", m_plain("DB Vertrieb GmbH", "Fahrschein {aref} DB Fernverkehr", neg(20, 140)), 3)
add("oepnv", m_sepa("BVG Berliner Verkehrsbetriebe", "Deutschlandticket Abo {mon}/{year}", 0, 0, fixed=5800), 3)
add("oepnv", m_plain("HVV Hamburger Verkehrsverbund", "HVV Ticket App {ref}", neg(3, 10)), 1)
add("oepnv", m_plain("FlixBus", "FlixBus Buchung {ref}", neg(15, 50)), 1)
add("oepnv", m_card("MVG Automat", 3, 9), 1)
add("auto", m_card("ATU Auto-Teile-Unger", 80, 450), 2)
add("auto", m_sepa("HUK-COBURG Kfz", "Kfz-Versicherung Beitrag {year} Vertr {ref}", 0, 0, fixed=6420), 2)
add("auto", m_card("Autohaus Beispiel Service", 150, 700), 2)
add("auto", m_plain("ADAC e.V.", "ADAC Mitgliedsbeitrag {year}", neg(54, 139)), 1)
add("auto", m_card("Parkhaus City", 3, 18), 1)
add("auto", m_card("Waschstrasse Glanz", 8, 18), 1)
add("taxi_sharing", m_plain("Uber BV", "Uber Trip {aref}", neg(9, 35)), 3)
add("taxi_sharing", m_plain("FREE NOW", "FREENOW Fahrt {ref}", neg(10, 40)), 2)
add("taxi_sharing", m_plain("SHARE NOW GmbH", "SHARE NOW Miete {ref}", neg(5, 30)), 2)
add("taxi_sharing", m_plain("Lime", "Lime Ride {aref}", neg(2, 8)), 1)
add("taxi_sharing", m_card("Taxi Funk Zentrale", 12, 40), 1)

# Freizeit
add("abos", m_sepa("Netflix International B.V.", "Netflix Monatsabo {aref}", 0, 0, fixed=1399), 3)
add("abos", m_plain("Spotify AB", "Spotify P{ref} Premium", lambda: -1099, "card"), 2)
add("abos", m_plain("Disney Plus", "Disney+ Abo", lambda: -999, "card"), 1)
add("abos", m_sepa("Audible GmbH", "Audible Mitgliedschaft {aref}", 0, 0, fixed=995), 1)
add("abos", m_plain("APPLE.COM/BILL", "iCloud+ 200GB", lambda: -299, "card"), 1)
add("abos", m_sepa("Spiegel-Verlag", "SPIEGEL+ Digital Abo {ref}", 0, 0, fixed=1999), 1)
add("freizeit", m_plain("Eventim", "CTS EVENTIM Tickets {ref}", neg(40, 160), "card"), 2)
add("freizeit", m_card("Kino Cinemaxx", 10, 35), 2)
add("freizeit", m_card("Thalia Buchhandlung", 10, 40), 2)
add("freizeit", m_card("Staatliche Museen", 8, 25), 1)
add("freizeit", m_plain("Steam Games", "STEAMGAMES.COM {ref}", neg(5, 60), "card"), 1)
add("sport", m_sepa("McFIT GmbH", "Mitgliedsbeitrag {mon}/{year}", 0, 0, fixed=2990), 3)
add("sport", m_sepa("TSV Beispiel 1880 e.V.", "Vereinsbeitrag {year} Mitgl {ref}", 0, 0, fixed=9600), 2)
add("sport", m_card("Decathlon", 15, 120), 2)
add("sport", m_plain("Urban Sports Club", "Urban Sports Club Membership {mon}/{year}", lambda: -5900), 1)
add("sport", m_card("Kletterhalle Boulderwelt", 12, 18), 1)
add("reisen", m_plain("Lufthansa", "Lufthansa Ticket 220-{ref}", neg(120, 650), "card"), 2)
add("reisen", m_plain("Booking.com", "Booking.com Hotel Reservierung {ref}", neg(90, 480), "card"), 2)
add("reisen", m_plain("Airbnb", "AIRBNB * HM{aref}", neg(150, 900), "card"), 2)
add("reisen", m_plain("Ryanair", "Ryanair Booking {aref}", neg(40, 180), "card"), 1)
add("reisen", m_cc("HOTEL ALPENBLICK", 120, 400), 1)
add("reisen", m_plain("TUI Deutschland", "Anzahlung Pauschalreise {ref}", neg(300, 900)), 1)

# Einkaufen
add("kleidung", m_card("H&M", 20, 90), 2)
add("kleidung", m_plain("Zalando SE", "Zalando Bestellung {ref}", neg(30, 150)), 2)
add("kleidung", m_card("Peek & Cloppenburg", 50, 250), 2)
add("kleidung", m_card("Deichmann Schuhe", 25, 80), 1)
add("kleidung", m_cc("UNIQLO", 20, 90), 1)
add("kleidung", m_card("C&A Mode", 15, 70), 1)
add("elektronik", m_card("MediaMarkt", 30, 600), 2)
add("elektronik", m_card("Saturn Electro", 20, 400), 2)
add("elektronik", m_plain("Apple Store", "Apple Store Online Bestellung W{ref}", neg(100, 1500), "card"), 1)
add("elektronik", m_plain("Notebooksbilliger.de", "notebooksbilliger Rechnung {ref}", neg(50, 900)), 1)
add("elektronik", m_plain("JetBrains s.r.o.", "JetBrains Subscription {aref}", neg(70, 250), "card"), 1)
add("elektronik", m_plain("Cyberport", "Cyberport Bestellung {ref}", neg(40, 500)), 1)
add("online_shopping", m_plain("AMAZON PAYMENTS EUROPE S.C.A.", "302-{ref} AMZN Mktp DE", neg(10, 120)), 4)
add("online_shopping", m_plain("PayPal Europe S.a.r.l. et Cie S.C.A", "PP.{ref}.PP . Ihr Einkauf bei eBay", neg(10, 80)), 2)
add("online_shopping", m_plain("Otto GmbH", "OTTO Bestellung {ref}", neg(20, 200)), 1)
add("online_shopping", m_plain("Temu", "TEMU.COM {aref}", neg(10, 60), "card"), 1)
add("online_shopping", m_plain("Etsy Ireland", "Etsy Bestellung {ref}", neg(15, 70), "card"), 1)

# Gesundheit
add("gesundheit", m_card("Apotheke am Rathaus", 5, 40, style="girocard"), 3)
add("gesundheit", m_plain("Zahnarztpraxis Dr. Beispiel", "Rechnung {ref} Zahnreinigung", neg(80, 150)), 2)
add("gesundheit", m_plain("Shop Apotheke", "Shop Apotheke Bestellung {ref}", neg(10, 60)), 1)
add("gesundheit", m_plain("Physiotherapie Beweglich", "Rechnung Krankengymnastik {ref}", neg(40, 120)), 1)
add("gesundheit", m_card("Fielmann", 30, 300), 1)
add("versicherung", m_sepa("Allianz Versicherungs-AG", "Haftpflicht Beitrag {year} Vers-Nr {ref}", 0, 0, fixed=6800), 2)
add("versicherung", m_sepa("HUK24 AG", "Hausrat Beitrag {mon}/{year}", 0, 0, fixed=1450), 2)
add("versicherung", m_sepa("Techniker Krankenkasse", "Beitrag freiwillige Versicherung {mon}/{year}", 0, 0, fixed=24500), 2)
add("versicherung", m_sepa("ERGO Lebensversicherung", "BU-Versicherung Beitrag {ref}", 0, 0, fixed=6230), 1)
add("versicherung", m_sepa("Debeka", "Zahnzusatz {mon}/{year}", 0, 0, fixed=2190), 1)
add("versicherung", m_sepa("ADAC Versicherung", "Auslandskrankenversicherung {year}", 0, 0, fixed=2490), 1)

# Familie
add("kinder", m_sepa("Kita Sonnenschein e.V.", "Kitabeitrag {mon}/{year} Essensgeld", 0, 0, fixed=21000), 3)
add("kinder", m_in("Familienkasse", "Kindergeld {mon}/{year} KG-Nr {ref}", 250, 255), 2)
add("kinder", m_card("Smyths Toys", 15, 80), 2)
add("kinder", m_sepa("Musikschule Beispielstadt", "Unterrichtsgebuehr {mon}/{year}", 0, 0, fixed=6500), 1)
add("kinder", m_card("Jako-o Kinderbekleidung", 20, 70), 1)
add("geschenke_spenden", m_plain("Deutsches Rotes Kreuz", "Spende {year} Danke", neg(20, 100)), 2)
add("geschenke_spenden", m_plain("Aerzte ohne Grenzen e.V.", "Spende Nothilfe {ref}", neg(25, 100)), 2)
add("geschenke_spenden", m_plain("Lisa Beispiel", "Geburtstagsgeschenk Oma", neg(20, 80)), 1)
add("geschenke_spenden", m_card("Blumen Florentina", 15, 50), 1)
add("geschenke_spenden", m_plain("Wikimedia Foerdergesellschaft", "Spende Wikipedia", neg(5, 30)), 1)
add("geschenke_spenden", m_plain("Jan Beispiel", "Hochzeitsgeschenk", neg(50, 150)), 1)

# Finanzen
add("umbuchung", m_plain("Eigenes Konto", "Umbuchung auf Tagesgeld", neg(100, 1000)), 3)
add("umbuchung", m_plain("Eigenes Konto", "Uebertrag vom Girokonto", pos(100, 1000), "tagesgeld"), 2)
add("umbuchung", m_plain("Max Mustermann", "Uebertrag Gemeinschaftskonto {mon}/{year}", neg(500, 800)), 2)
add("umbuchung", m_plain("C24 Pocket", "Pocket Umbuchung Urlaub", neg(50, 300)), 1)
add("umbuchung", m_plain("Max Mustermann", "Einzahlung Trade Republic", neg(200, 1000)), 1)
add("sparen_anlegen", m_plain("", "Sparplan Ausfuehrung ISIN IE00B4L5Y983 Stk 1,234", neg(100, 500), "depot"), 3)
add("sparen_anlegen", m_plain("Scalable Capital", "Sparplan {mon}/{year}", neg(100, 300)), 2)
add("sparen_anlegen", m_sepa("Bausparkasse Schwaebisch Hall", "Bausparvertrag {ref} Sparrate", 0, 0, fixed=5000), 2)
add("sparen_anlegen", m_plain("", "Kauf ISIN US0378331005 Apple Inc", neg(200, 900), "depot"), 1)
add("sparen_anlegen", m_plain("Max Mustermann", "VL Vermoegenswirksame Leistungen", lambda: -4000), 1)
add("kredit", m_plain("DKB AG", "Kreditkartenabrechnung {mon}/{year} VISA", neg(300, 1500)), 2)
add("kredit", m_plain("easybank AG", "Ausgleich Kreditkarte Abrechnung {ref}", neg(200, 1200)), 2)
add("kredit", m_sepa("Santander Consumer Bank", "Rate Ratenkredit {ref}", 0, 0, fixed=18900), 2)
add("kredit", m_plain("Klarna", "Klarna Ratenkauf Rate {ref}", neg(30, 90)), 1)
add("kredit", m_plain("", "Ausgleich Abrechnung Kartenkonto", pos(300, 1300), "card"), 2)
add("gebuehren", m_plain("", "Kontofuehrungsentgelt {mon}/{year}", lambda: -495), 3)
add("gebuehren", m_plain("", "Auslandseinsatzentgelt 1,75 %", neg(0.2, 4), "card"), 2)
add("gebuehren", m_plain("", "Entgelt Girocard Jahresgebuehr", lambda: -1200), 1)
add("gebuehren", m_plain("", "Fremdautomatengebuehr", lambda: -399), 1)
add("gebuehren", m_plain("", "Depotgebuehr Q{ref}", neg(5, 15), "depot"), 1)
add("steuern", m_plain("Finanzamt Musterstadt", "Einkommensteuer Vorauszahlung StNr {ref}", neg(400, 1200)), 2)
add("steuern", m_sepa("Rundfunk ARD ZDF DRadio", "Rundfunkbeitrag {mon}/{year} Beitragsnr {ref}", 0, 0, fixed=5508), 2)
add("steuern", m_sepa("Bundeskasse Kfz-Steuer", "Kfz-Steuer KENNZ {aref}", 0, 0, fixed=12000), 2)
add("steuern", m_plain("Stadtkasse Musterstadt", "Grundsteuer {year} Kassenzeichen {ref}", neg(80, 250)), 1)
add("steuern", m_plain("", "Abgeltungsteuer Kapitalertraege", neg(2, 30), "depot"), 1)
add("bargeld", m_plain("", "Bargeldauszahlung GAA Sparkasse {ref}", neg(50, 300)), 3)
add("bargeld", m_plain("", "Auszahlung Geldautomat Commerzbank {ref}", neg(50, 200)), 2)
add("bargeld", m_plain("", "Bargeld REWE Cashback", neg(20, 100)), 1)
add("bargeld", m_plain("", "Bargeldeinzahlung Automat", pos(50, 500)), 1)
add("bargeld", m_plain("", "ATM Withdrawal Lisboa", neg(40, 120), "card"), 1)

# Sonstiges
add("sonstiges", m_plain("Deutsche Post AG", "Briefmarken Online {ref}", neg(2, 20)), 2)
add("sonstiges", m_card("Schluesseldienst Schnell", 60, 180), 1)
add("sonstiges", m_plain("Buergeramt Musterstadt", "Gebuehr Personalausweis", lambda: -3700), 1)
add("sonstiges", m_plain("Copyshop Druckpunkt", "Druckauftrag {ref}", neg(3, 25)), 1)
add("sonstiges", m_plain("Waescherei Blitzblank", "Reinigung Anzug", neg(10, 30)), 1)
add("sonstiges", m_plain("Notar Beispiel", "Kostenrechnung {ref}", neg(80, 300)), 1)
add("sonstiges", m_plain("Fundbuero", "Verwahrgebuehr", neg(5, 15)), 1)


# Real ledgers are mostly recurring merchants: one-off merchants about 15 % (a few more in
# categories that are one-off by nature). Rebalance each category to its total, ≥ 2 per
# recurring merchant; the last merchants of a category are its one-offs.
ONE_OFFS = {"sonstiges": 3, "geschenke_spenden": 2, "elektronik": 2, "reisen": 2, "freizeit": 2}
TOTAL = {"lebensmittel": 12}
for cat, gens in G.items():
    n = TOTAL.get(cat, 9)
    singles = ONE_OFFS.get(cat, 1)
    fns = [fn for fn, _ in gens]
    recurring, one_off = fns[:-singles], fns[-singles:]
    remaining = n - singles
    while len(recurring) * 2 > remaining:
        recurring.pop()
    times = [2] * len(recurring)
    i = 0
    while sum(times) < remaining:
        times[i % len(times)] += 1
        i += 1
    G[cat] = list(zip(recurring, times)) + [(fn, 1) for fn in one_off]

out = []
start = datetime.date(2025, 5, 1)
n = 0
for cat, gens in G.items():
    for fn, times in gens:
        for _ in range(times):
            mer, pur, cents, acct, credid, mref = fn()
            n += 1
            day = start + datetime.timedelta(days=rng.randint(0, 540))
            item = {"id": f"e{n:03d}", "merchant": mer, "purpose": pur, "amountCents": cents,
                    "accountType": acct, "bookingDate": day.isoformat(), "category": cat}
            if credid: item["creditorID"] = credid
            if mref: item["mref"] = mref
            out.append(item)

from collections import Counter
c = Counter(i["category"] for i in out)
print(len(out), file=sys.stderr)
print(sorted(c.items(), key=lambda x: x[1]), file=sys.stderr)
rng.shuffle(out)
doc = {"version": 1,
       "note": "Synthetic eval set for MFN categorization (CLAUDE.md §8). No real bookings: merchants are generic or public brands, all references, creditor IDs, mandates and amounts are random.",
       "transactions": out}
json.dump(doc, sys.stdout, ensure_ascii=False, indent=1)
