# Fixtures C24 (Web-Banking JSON)

Vom Menschen angelegt (Safari → Entwickler → Netzwerk), anonymisiert und mit `scripts/fixtures-scrub` verfremdet (Beträge, Daten, IDs). Agents lesen sie nur.

| Datei | Inhalt | Status |
| --- | --- | --- |
| `endpoints.md` | Aufrufe, Header-Namen, Cookie-Namen, Request-Body der Umsatzsuche, Lücken | vorhanden |
| `accounts.json` | `GET /api/user/me/accounts/internal/`: Konten + Pockets mit Salden | vorhanden |
| `pockets.json` | `GET /api/v3/pockets/` | vorhanden (`id` durch Anonymisierung gleich – Connector nutzt `pocket_number`) |
| `transactions-page1.json`, `transactions-page2.json` | `POST /api/v3/transactions/search/`, Pocket Plus, Offset 0/30 | vorhanden, **nur gebuchte** |
| `transactions-other-pocket-page1.json` | dito, anderer Pocket mit Kartenzahlungen | vorhanden |
| `upcoming-transactions.json` | `GET /api/v2/upcoming-transactions/`: Daueraufträge, angekündigte Lastschriften | vorhanden |
| `balance.json` | – | entfällt (Salden stehen in `accounts.json`) |
| `transactions-giro-page1.json` | Umsatzsuche für ein Girokonto (`account_numbers` = Kontonummer des Smartkontos) | **fehlt** |
| `transactions-preliminary.json` | Umsatzsuche mit vorgemerkter Kartenzahlung (`preliminary: true`), möglichst Fremdwährung; dieselbe Zahlung später gebucht | **fehlt** |
| `session-expired.json` | Status + Body eines API-Aufrufs nach ~15 min Inaktivität | **fehlt** |
| Login (in `endpoints.md`) | Start-URL, Ablauf bis Push-Freigabe, **wo die Web-App das Bearer-Token ablegt** (Local/Session Storage-Key oder Antwort eines Login-Aufrufs), Format der `x-c24-*`-Header-Werte, Wert von `future_days` | **fehlt** |
