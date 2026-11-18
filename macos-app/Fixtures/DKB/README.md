# Fixtures DKB (FinTS 3.0, decoupled TAN)

Created by a human, anonymized with `scripts/fixtures-anonymize`. FinTS responses raw (`HNHBK…`) or Base64.

| File | Content | Status |
| --- | --- | --- |
| `bpd-anonymous.fints` | BPD with HITANS v6/v7 (procedure 942, decoupled parameters), HICAZS, HIPINS | missing |
| `init.fints` | init response with HIUPD incl. credit card account | missing |
| `decoupled-3956.fints` | response with HITAN (order reference) + 3956 | missing |
| `decoupled-poll-3076.fints` | poll response "not yet approved" | missing |
| `decoupled-poll-0020.fints` | poll response after approval with result | missing |
| `hkcaz-giro.fints`, `camt052-giro.xml` | transactions camt.052 (BOOK and PDNG) | missing |
| `hksal-giro.fints`, `hksal-card.fints` | balances | missing |
| `hkwpd-depot.fints`, `mt535-depot.sta` | securities holdings | missing |

## Web banking (`web/`, scraping until FinTS registration)

From a Firefox HAR of the web banking `banking.dkb.de`, anonymized by a script outside the repo, altered with
`scripts/fixtures-scrub` (amounts, dates, IDs) and checked automatically (no cookie, token, IBAN, name or purpose value from the HAR in the folder). Endpoints, flow
and anonymization: `web/endpoints.md`.
