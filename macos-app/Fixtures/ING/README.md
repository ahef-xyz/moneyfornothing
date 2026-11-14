# Fixtures ING (FinTS 3.0, PIN ohne TAN)

Vom Menschen angelegt, anonymisiert mit `scripts/fixtures-anonymize`. FinTS-Antworten roh (`HNHBK…`) oder Base64.

| Datei | Inhalt | Status |
| --- | --- | --- |
| `bpd-anonymous.fints` | Antwort auf anonymen Dialog (HIBPA, HIKAZS, HISALS, HIWPDS, HIPINS, HITANS) | fehlt |
| `init.fints` | Antwort auf Dialog-Init mit Kennung (HIUPA, HIUPD Giro + Extra-Konto + Depot, HISYN) | fehlt |
| `hksal-giro.fints` | Saldo Girokonto (HISAL) | fehlt |
| `hkkaz-giro-page1.fints`, `hkkaz-giro-page2.fints` | MT940 mehrseitig (erste Seite mit 3040 + Aufsetzpunkt) | fehlt |
| `hkkaz-9010.fints` | Konto ohne Zahlungseingang (Rückmeldung 9010) | fehlt |
| `mt940-giro.sta` | Reines MT940 (aus HIKAZ extrahiert), Umlaute, `?20`–`?29`, SEPA-Tags | fehlt |
| `hkwpd-depot.fints`, `mt535-depot.sta` | Depotbestand | fehlt |
