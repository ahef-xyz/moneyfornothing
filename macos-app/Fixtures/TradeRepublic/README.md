# Fixtures Trade Republic (Web-App: Web-Login + REST, WebSocket für Rest)

Vom Menschen angelegt, anonymisiert (Telefonnummer, Namen, IDs) und mit `scripts/fixtures-scrub` verfremdet (Beträge, Daten, IDs;
ISINs außer dem öffentlichen Beispiel `US0378331005` ersetzt). Quelle und Endpunkte: `endpoints.md`.

| Datei | Inhalt | Status |
| --- | --- | --- |
| `endpoints.md` | Endpunkte, Cookies, Header aus dem HAR der Web-App | vorhanden |
| `login.json`, `login-process-pending.json`, `login-process-done.json`, `login-qr-challenge.json` | Login v2 (`/api/v2/auth/web/login`, Prozess-Polling, QR) | vorhanden – MFN loggt per Web-View ein (`.webLogin`), nur als Beleg genutzt |
| `accounts-switchable.json` | Konten mit IBAN | vorhanden, im Test genutzt |
| `cards-home.json` | Karte (`lastFourPan`) | vorhanden, im Test genutzt |
| `timeline-page1.json` | `GET /api/v2/timeline/transactions`, erste Seite mit `cursors.after` | vorhanden, im Test genutzt |
| `timeline-page2.json` | Folgeseite (Query-Parameter für `after` bestätigen) | fehlt – im Test synthetisch |
| `timeline-detail.json` | Umsatzdetail (Endpunkt unbekannt; bisher WebSocket `timelineDetailV2`) | fehlt – im Test synthetisch |
| `cash.json` | Cash-Saldo (Endpunkt unbekannt; bisher WebSocket `cash`) | fehlt – im Test synthetisch |
| `compact-portfolio.json` | Depotpositionen (vermutlich WebSocket `compactPortfolio`) | fehlt – im Test synthetisch |
| `ws-transcript.txt` | Rohnachrichten einer WebSocket-Sitzung (`connect`, `sub`, `<n> A`, `<n> D`) | fehlt |
| `timeline-transaction-categories.json` | TR-Kategorien | vorhanden, vom Connector nicht genutzt |
| `interest-info.json`, `orders.json`, `portfolio-chart.json` | Zinsen, Orders, Depotwert-Verlauf | entfernt (ungenutzt, enthielten echte Werte) |
