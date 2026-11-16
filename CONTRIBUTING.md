# Contributing to MFN

MFN is a read-only, local multibanking app for macOS (Swift 6, SwiftUI/AppKit, macOS 26, Apple Silicon).

**Issues only, no pull requests.** Bug reports, bank quirks and feature ideas are welcome as
GitHub issues. Pull requests are not accepted and will be closed unread: the public repository is a
published snapshot of the maintainer's working repository, so code is never merged here. If you
found a fix, describe it in an issue; the maintainer writes and tests the change.

MFN is source available, not open source (see `LICENSE`). You may change and build it for your own
personal use; the notes below help with that. **By posting suggestions or code in an issue** you
confirm that you have the right to share it, and you grant the maintainer, Oliver Janssen, a
perpetual, worldwide, irrevocable, royalty-free license to use, change, distribute and sublicense it
as part of MFN under any terms. You keep the copyright in what you posted.

Never post real data in an issue: no account numbers, IBANs, names, transactions, screenshots with
real balances, logs with tokens or the raw response of a bank. Security problems go to the address
in `SECURITY.md`, not into a public issue.

## Hard rules

- **Read-only.** No transfers, no orders, nothing that moves money. Never.
- **No real data anywhere**: not in code, tests, fixtures, logs, issues or commits. No real credentials,
  IBANs, account numbers, names, transactions or tokens.
- **Fixtures are anonymised.** Bank responses captured locally have every real value replaced by a
  placeholder before they go anywhere near a commit. Raw captures (`Fixtures/**/raw/`, `*.har`) are
  gitignored.
- **The protocol is frozen.** `PROTOCOL.md` carries a version number. Changing `BankConnector`,
  `AuthChallengePresenter`, `ConnectorError` or the models needs a version bump and maintainer approval:
  describe the proposal in an issue and stop there.
- **Never publish the FinTS product ID**, signing identities or Sparkle keys. They live in gitignored local files.

## Architecture

Five layers, all on the Mac: `MFNApp` (SwiftUI) -> `MFNCore` (store, `SyncEngine`, categoriser) ->
`BankConnector` protocol -> connectors -> bank hosts. The UI only knows the store. The `SyncEngine`
actor orchestrates connectors and cannot tell FinTS from scraping. Approvals (decoupled TAN, push,
2FA) go through `AuthChallengePresenter`, which connectors call and the app shows as a sheet.

The app lives in `macos-app/`.

```
macos-app/
  MFNApp/           SwiftUI app: views, view models, menus. No networking, no SQL.
  Packages/
    MFNCore/          models, BankConnector protocol, store (SQLCipher), SyncEngine, keychain, CSV import/export
    MFNIntelligence/  categorisation: rules -> kNN -> Foundation Models
    MFNMock/          MockConnector and data generator; previews and UI tests use only this
    MFNFinTS/         FinTS 3.0 client (wire, segments, dialog, TAN) with MT940/MT535/camt parsers, ING/DKB connectors
    MFNScrape/        web-login session handling, rate-limited scrape client
    MFNTradeRepublic/ MFNC24/ MFNEasybank/ MFNN26/ MFNDKB/   one package per web/API bank
    MFNConformance/   acceptance suite every connector must pass
  Fixtures/<Bank>/  anonymised bank responses
```

## Conventions

- Swift 6 with strict concurrency; `Sendable` across module boundaries; network and store access in actors.
- Money is `Int` cents, never `Double`.
- No force unwraps (`!`), `try!` or `as!` outside tests. Errors are typed (`ConnectorError`), never swallowed.
- Bank API models decode tolerantly: ignore unknown fields, optional where unsure, enums with an `unknown` case.
- Logging with `os.Logger`, subsystem `xyz.ahef.mfn`; PINs, TANs, passwords, cookies, tokens and IBANs are
  always `privacy: .private`.
- Scraping etiquette: one sync per bank at a time, backoff on 429/5xx, stop after 3 failures, never
  auto-retry failed logins, polling interval at least 15 minutes.
- No third-party dependency without discussion (currently SQLCipher.swift and Sparkle).
- Native macOS UI: system fonts, `NavigationSplitView`, menu items with shortcuts, Dark Mode, no custom chrome.
  Colour is never the only carrier of meaning.

## Tests

Every package has tests. Parser tests run against anonymised fixtures; no test talks to a real bank.
New connectors must pass `MFNConformance`.

```sh
cd macos-app
swift test                      # inside a package under Packages/
xcodebuild -workspace MFN.xcworkspace -scheme MFN -destination 'platform=macOS' build test
```

## Good issues

- Bug: MFN version, macOS version, bank, what you did, what happened, what you expected.
- Bank change or new bank: what the bank's interface does differently, described in words or with
  anonymised examples (made-up amounts, names and IDs).
- Feature idea: the problem you want solved first, then your proposal. MFN stays read-only.
