# Fixtures DKB (FinTS 3.0, Decoupled-TAN)

Vom Menschen angelegt, anonymisiert mit `scripts/fixtures-anonymize`. FinTS-Antworten roh (`HNHBK…`) oder Base64.

| Datei | Inhalt | Status |
| --- | --- | --- |
| `bpd-anonymous.fints` | BPD mit HITANS v6/v7 (Verfahren 942, Decoupled-Parameter), HICAZS, HIPINS | fehlt |
| `init.fints` | Init-Antwort mit HIUPD inkl. Kreditkartenkonto | fehlt |
| `decoupled-3956.fints` | Antwort mit HITAN (Auftragsreferenz) + 3956 | fehlt |
| `decoupled-poll-3076.fints` | Poll-Antwort „noch nicht freigegeben“ | fehlt |
| `decoupled-poll-0020.fints` | Poll-Antwort nach Freigabe mit Ergebnis | fehlt |
| `hkcaz-giro.fints`, `camt052-giro.xml` | Umsätze camt.052 (BOOK und PDNG) | fehlt |
| `hksal-giro.fints`, `hksal-card.fints` | Salden | fehlt |
| `hkwpd-depot.fints`, `mt535-depot.sta` | Depotbestand | fehlt |

## Web-Banking (`web/`, Scraping bis zur FinTS-Registrierung)

Aus einem Firefox-HAR des Web-Bankings `banking.dkb.de`, anonymisiert per Skript außerhalb des Repos, mit
`scripts/fixtures-scrub` verfremdet (Beträge, Daten, IDs) und automatisch geprüft (kein Cookie-, Token-, IBAN-, Namens- oder Zweck-Wert aus dem HAR im Ordner). Endpunkte, Ablauf
und Anonymisierung: `web/endpoints.md`.
