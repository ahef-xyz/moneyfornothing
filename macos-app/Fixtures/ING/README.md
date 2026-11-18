# Fixtures ING (FinTS 3.0, PIN without TAN)

Created by a human, anonymized with `scripts/fixtures-anonymize`. FinTS responses raw (`HNHBK…`) or Base64.

| File | Content | Status |
| --- | --- | --- |
| `bpd-anonymous.fints` | response to anonymous dialog (HIBPA, HIKAZS, HISALS, HIWPDS, HIPINS, HITANS) | missing |
| `init.fints` | response to dialog init with ID (HIUPA, HIUPD current account + extra account + securities account, HISYN) | missing |
| `hksal-giro.fints` | balance of current account (HISAL) | missing |
| `hkkaz-giro-page1.fints`, `hkkaz-giro-page2.fints` | MT940 multi-page (first page with 3040 + continuation point) | missing |
| `hkkaz-9010.fints` | account without incoming payments (response 9010) | missing |
| `mt940-giro.sta` | plain MT940 (extracted from HIKAZ), umlauts, `?20`–`?29`, SEPA tags | missing |
| `hkwpd-depot.fints`, `mt535-depot.sta` | securities holdings | missing |
