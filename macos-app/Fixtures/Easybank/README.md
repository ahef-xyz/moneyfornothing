# Fixtures easybank (ex Barclays, Web-Banking JSON + CSV)

Vom Menschen angelegt (Safari → Entwickler → Netzwerk), anonymisiert und mit `scripts/fixtures-scrub` verfremdet (Beträge, Daten, IDs).

| Datei | Inhalt | Status |
| --- | --- | --- |
| `endpoints.md` | Methode, Pfad, Ablauf, Cookie-/Header-Namen, Lücken | da |
| `cards.json` | Landing-`Item`: `AccountListResponse` + `DashboardTransactionItemList` (eine Karte, keine Partnerkarte) | da |
| `account-transaction-history(-request).json` | Kartenkonto öffnen: Abrechnungsdaten + aktuelle/vorgemerkte Umsätze, ohne OTP | da |
| `get-transactions-request.json`, `get-transactions-otp-required.json`, `transactions-page1.json` | Umsatzhistorie (OTP, 50 je Seite) | da |
| `send-otp.json` | Antwort von `SendOTP` | da (Request-Body fehlt) |
| `transaction-detail(-request).json` | Umsatzdetail | da (vom Connector nicht genutzt) |
| `cash-depot-account-list.json` | Tagesgeld/Depot-Liste | da (leer) |
| `retail-landing.json` | Komplette `RetailLanding`-Antwort + Request-Body | fehlt (Test baut die Hülle um `cards.json`) |
| `send-otp-request.json`, `transactions-page2(-request).json` | OTP-Anforderung, Folgeseite (Paging) | fehlt |
| `statements.json` | Abrechnungsliste (Periode, Fälligkeit, Betrag, PDF) | fehlt |
| `export.csv` | CSV-Export der Umsätze aus App/Web-Banking | fehlt |
| Tagesgeld-Konto | nicht-leere `GetCashDepotAccountList` + Umsätze | fehlt |
