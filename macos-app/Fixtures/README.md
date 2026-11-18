# Fixtures

Anonymized and altered bank responses (real structure, invented content). **Only a human creates them.** Agents read them.

- `ING/`: BPD, UPD, MT940 (multi-page with 3040), MT535
- `DKB/`: BPD with HITANS v6/v7, UPD with credit card account, camt.052, HITAN sequence of a decoupled approval; `web/` web banking JSON
- `TradeRepublic/`: login responses, timeline pages (with cursor), timelineDetailV2, compactPortfolio, cash
- `C24/`: `endpoints.md`, JSON examples for accounts/transactions/pockets
- `Easybank/`: `endpoints.md`, card list, transactions pending/booked, statements, CSV export
- `N26/`: GraphQL queries, feed/timeline responses

## Policy: nothing real stays

1. `scripts/fixtures-anonymize` replaces IBANs (→ `DE00…`), names, tokens, cookies, purposes.
2. Afterwards **always** run `scripts/fixtures-scrub` (Python 3, standard library only, deterministic): amounts, balances, limits and
   interest rates are altered (factor per bank plus jitter; signs and decimal places stay), all dates and
   timestamps are shifted by the same whole number of weeks (weekdays stay), customer, account and card numbers, UUIDs and ISINs
   (except the public example `US0378331005`) are replaced consistently, personal product names are neutralized.
   `scripts/fixtures-scrub --check` compares with `git HEAD` and counts unchanged numeric tokens.
3. Expected values in the tests follow the altered fixtures (amounts in cents, shifted dates).

Never commit real IBANs, names, amounts, dates or session tokens. Do not add real values to fixtures by hand.
