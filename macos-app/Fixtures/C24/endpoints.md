# C24 Endpunkte (aus Safari-HAR, anonymisiert)

Aufgezeichnet nach dem Login (Push-TAN nicht enthalten). Header-Werte und Cookie-Werte entfernt, Request-Bodies anonymisiert.

## Authentifizierung
- Jeder API-Aufruf trägt `Authorization: Bearer <token>` (Wert entfernt). Zusätzliche Header: `x-c24-guid`, `x-c24-timestamp`, `x-c24-tracingsession`, `x-c24-unicorn-guid`.
- Cookie-Namen (nur Namen): `c24Cookies_v1`, `c24GDPR_v1`, `cid_v1`, `devicetype_v1`, `keyword_v1`, `matchtype_v1`, `source_v1`. Ein Session-Cookie ist nicht darunter – die Sitzung hängt am Bearer-Token.

## Aufrufe (eindeutig, in Reihenfolge des ersten Auftretens)

| Methode | URL | Query-Parameter | Status | Typ |
| --- | --- | --- | --- | --- |
| POST | `api.c24.de/api/webconfig.json` | – | 200 | application/json |
| POST | `banking.c24.de/cdn-cgi/rum` | – | 204 | text/plain |
| GET | `api.c24.de/api/user/userprofile/` | – | 200 | application/json |
| GET | `api.c24.de/api/v2/user/me/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/me/accounts/internal/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/me/accounts/external/` | – | 200 | application/json |
| GET | `api.c24.de/api/geldanlage/v2/fixed-deposit/account/list` | – | 200 | application/json |
| GET | `api.c24.de/api/transaction-categories/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/me/current-account-plan/cashback/` | – | 200 | application/json |
| GET | `api.c24.de/api/interest-center/` | – | 200 | application/json |
| GET | `api.c24.de/api/v2/upcoming-transactions/` | future_days | 200 | application/json |
| GET | `api.c24.de/api/v3/pockets/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/me/current-account-plan/` | – | 200 | application/json |
| GET | `api.c24.de/api/web/km-mw/api/c24bank/bank-interface-service/v1/financialData/bankConnections/` | app_name | 200 | application/json |
| GET | `api.c24.de/api/user/sca/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/sso/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/profile-picture/view/{id}.png` | – | 200 | image/png |
| GET | `api.c24.de/api/account/{account_number}/overdraft/settings/` | – | 200 | application/json |
| GET | `api.c24.de/api/etl/product-api/{id}/tax-exemption` | – | 204 | application/octet-stream |
| POST | `api.c24.de/api/v3/transactions/search/` | – | 200 | application/json |

## Ablauf beim Klicken
- Übersicht (nach Login): `webconfig.json`, `user/me`, `accounts/internal`, `accounts/external`, `v3/pockets`, `v2/upcoming-transactions?future_days`, …
- Umsätze eines Kontos/Pockets: `POST /api/v3/transactions/search/`, Paging über `pagination.offset` (+30), Ende bei `pagination.more == false`.

## Request-Body `POST /api/v3/transactions/search/` (Beispiel, anonymisiert)
```json
{
  "criteria": {
    "account_numbers": [
      "3238114929"
    ]
  },
  "pagination": {
    "limit": 30,
    "offset": 30
  }
}
```

## Lücken
- Keine Giro-Umsätze aufgezeichnet (alle drei Suchen betreffen Pockets).
- Keine vorgemerkten Umsätze (`preliminary: true` kam nicht vor).
- Keine Antwort auf abgelaufene Sitzung (`session-expired.json` fehlt).
- Kein eigener Saldo-Endpunkt: Salden stehen in `accounts/internal` (`total_balance`, `available_balance`, `hold_balance`).
