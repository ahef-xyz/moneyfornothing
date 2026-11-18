# Fixtures Trade Republic (web app: web login + REST, WebSocket for the rest)

Created by a human, anonymized (phone number, names, IDs) and altered with `scripts/fixtures-scrub` (amounts, dates, IDs;
ISINs replaced except the public example `US0378331005`). Source and endpoints: `endpoints.md`.

| File | Content | Status |
| --- | --- | --- |
| `endpoints.md` | endpoints, cookies, headers from the HAR of the web app | present |
| `login.json`, `login-process-pending.json`, `login-process-done.json`, `login-qr-challenge.json` | login v2 (`/api/v2/auth/web/login`, process polling, QR) | present. MFN logs in via web view (`.webLogin`), used only as evidence |
| `accounts-switchable.json` | accounts with IBAN | present, used in tests |
| `cards-home.json` | card (`lastFourPan`) | present, used in tests |
| `timeline-page1.json` | `GET /api/v2/timeline/transactions`, first page with `cursors.after` | present, used in tests |
| `timeline-page2.json` | following page (confirm query parameter for `after`) | missing; synthetic in tests |
| `timeline-detail.json` | transaction detail (endpoint unknown; so far WebSocket `timelineDetailV2`) | missing; synthetic in tests |
| `cash.json` | cash balance (endpoint unknown; so far WebSocket `cash`) | missing; synthetic in tests |
| `compact-portfolio.json` | securities positions (probably WebSocket `compactPortfolio`) | missing; synthetic in tests |
| `ws-transcript.txt` | raw messages of a WebSocket session (`connect`, `sub`, `<n> A`, `<n> D`) | missing |
| `timeline-transaction-categories.json` | TR categories | present, not used by the connector |
| `interest-info.json`, `orders.json`, `portfolio-chart.json` | interest, orders, portfolio value history | removed (unused, contained real values) |
