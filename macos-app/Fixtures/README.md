# Fixtures

Anonymisierte und verfremdete Antworten der Banken (Struktur echt, Inhalt erfunden). **Nur der Mensch legt sie an.** Agents lesen sie.

- `ING/`: BPD, UPD, MT940 (mehrseitig mit 3040), MT535
- `DKB/`: BPD mit HITANS v6/v7, UPD mit Kartenkonto, camt.052, HITAN-Sequenz einer Decoupled-Freigabe; `web/` Web-Banking-JSON
- `TradeRepublic/`: Login-Antworten, Timeline-Seiten (mit Cursor), timelineDetailV2, compactPortfolio, cash
- `C24/`: `endpoints.md`, JSON-Beispiele Konten/Umsätze/Pockets
- `Easybank/`: `endpoints.md`, Kartenliste, Umsätze pending/booked, Abrechnungen, CSV-Export
- `N26/`: GraphQL-Queries, Feed-/Timeline-Antworten

## Richtlinie: nichts Echtes bleibt

1. `scripts/fixtures-anonymize` ersetzt IBANs (→ `DE00…`), Namen, Tokens, Cookies, Zwecke.
2. Danach **immer** `scripts/fixtures-scrub` (Python 3, nur Standardbibliothek, deterministisch): Beträge, Salden, Limits und
   Zinssätze werden verfremdet (Faktor pro Bank + Jitter, Vorzeichen und Nachkommastellen bleiben), alle Daten und
   Zeitstempel um dieselbe ganze Zahl Wochen verschoben (Wochentage bleiben), Kunden-/Konto-/Kartennummern, UUIDs und ISINs
   (außer dem öffentlichen Beispiel `US0378331005`) konsistent ersetzt, persönliche Produktnamen neutralisiert.
   `scripts/fixtures-scrub --check` vergleicht mit `git HEAD` und zählt unveränderte Zahlen-Token.
3. Erwartungswerte in den Tests folgen den verfremdeten Fixtures (Beträge in Cent, verschobene Daten).

Niemals echte IBANs, Namen, Beträge, Daten oder Session-Tokens committen. Fixtures nicht von Hand mit echten Werten ergänzen.
