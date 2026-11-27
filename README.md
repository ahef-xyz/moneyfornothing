<p align="center">
  <img src="https://www.moneyfornothing.app/app-icon.png" width="128" height="128" alt="MoneyForNothing app icon">
</p>

<h1 align="center">MoneyForNothing (MFN)</h1>

<p align="center">
  Read-only multibanking for macOS. Local, encrypted, no cloud.
</p>

<p align="center">
  <a href="https://www.moneyfornothing.app"><img src="https://img.shields.io/badge/website-moneyfornothing.app-1d1d1f?style=flat-square" alt="Website"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-1d1d1f?style=flat-square&logo=apple&logoColor=white" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple_Silicon-only-1d1d1f?style=flat-square" alt="Apple Silicon only">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-PolyForm_Strict_1.0.0-1d1d1f?style=flat-square" alt="License: PolyForm Strict 1.0.0"></a>
  <br>
  <img src="https://img.shields.io/badge/read--only-never_moves_money-2b7a3d?style=flat-square" alt="Read-only: never moves money">
  <img src="https://img.shields.io/badge/telemetry-none-2b7a3d?style=flat-square" alt="No telemetry">
  <img src="https://img.shields.io/badge/database-SQLCipher-2b7a3d?style=flat-square" alt="Database: SQLCipher">
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://www.moneyfornothing.app/screenshots/en/overview-dark.png?v=0.7.0">
    <img src="https://www.moneyfornothing.app/screenshots/en/overview.png?v=0.7.0" width="820" alt="MFN overview with demo data">
  </picture>
</p>

<p align="center">
  <a href="https://www.moneyfornothing.app"><b>www.moneyfornothing.app</b></a>
</p>

MFN is a native macOS app for **read-only multibanking**: it pulls balances, transactions, card
statements and depot positions from your banks into one local, encrypted database. It is an
alternative to commercial multibanking apps, with no fees and no cloud.

The source code is public so that anyone can check what the app does with their data. MFN is
**source available, not open source**: free for personal use, you may change and build it for
yourself, but you may not pass it on (see [License](#license)).

- **Read-only.** MFN never initiates transfers, orders or any other action that moves money.
- **Local.** Everything stays on your Mac. No account, no server, no telemetry. The exceptions are ones you
  choose yourself: an AI assistant you connect (off by default) and banks you add over YAXI (see below).
- **Encrypted.** The ledger is a SQLCipher database. Its key is protected by the Keychain
  (biometrics or device passcode) and, optionally, by your own password.
- **Locked.** The app locks with Touch ID / device password at start, after screen lock and after inactivity.
  Credentials and sessions live only in the Keychain.
- **On-device categorisation.** Rules, then nearest-neighbour matching on your own history, then
  Apple Foundation Models. Nothing leaves the machine. On a slow Mac you can switch the model off
  (Settings, Kategorien): rules and similar transactions still sort, the rest waits in "Zu prüfen".
  Your own choices never wait for the background run.
- **AI assistants (MCP), off by default.** Switch it on in Settings, MCP, and an MCP client
  (Claude Desktop, Claude Code, a client for a local model) can read the accounts you share and answer
  questions about them: balances, sums by category, cash flow, fixed costs, budgets, forecast, portfolio,
  transactions. Read-only (no sync, no changes, no transfers), only while MFN is unlocked, MFN asks before
  a new program gets access and logs every call. IBANs, references and bank IDs never leave; MFN does the
  sums. **With a cloud model this data goes to the model's provider**; with a local model it stays on
  your Mac. MFN cannot tell which one is connected.
- **Any other bank over YAXI (from 0.7.0, beta), opt-in per bank.** With your own access at YAXI, MFN reaches more
  than 1,000 further banks (FinTS and PSD2) through YAXI's service: "Andere Bank über YAXI" in the bank
  assistant. YAXI logs in to the bank from an attested enclave (AMD SEV-SNP) and cannot read your data; the
  client in MFN checks that attestation and encrypts every request. MFN issues the tickets on your Mac with your
  own key and runs no server. Only accounts, balances and transactions; automatic syncs at most every 4 hours,
  so a few accounts stay within YAXI's free calls. **These connections go through YAXI instead of straight from
  your Mac to the bank.**
- **New since the last sync.** New transactions are counted per account and marked in the list until you
  select them; filter or sort by them.
- **Forecast.** Note one-off expenses for a future date and see the projected balance. Monthly payments
  such as salary and rent are estimated from your own history. Planned entries are local notes, not orders.
- **Fixed costs.** Recurring expenses and income are detected from your transactions and shown per month
  and per year; add your own entries or adjust detected ones.
- **Encrypted backup.** One file holds the whole database; its contents can only be read with the database
  password that was set when it was written. Optionally written automatically into a folder you choose. Bank logins are never part of a backup.
- **German and English (from 0.7.0).** The app follows the language set in macOS. Amounts and dates follow
  your region settings.

Swift 6, SwiftUI/AppKit. Requires **macOS 26** on **Apple Silicon**.

## Supported banks

| Bank | Access |
| --- | --- |
| ING | FinTS 3.0 PIN/TAN (no TAN needed for reading) |
| DKB | FinTS 3.0 PIN/TAN with decoupled TAN (DKB app); the DKB web banking is used until FinTS is available for your setup |
| Trade Republic | Unofficial REST/WebSocket API (phone, PIN, 2FA code) |
| C24 | The bank's own web login (QR/push approval), then its web JSON endpoints |
| easybank | The bank's own web login, then its web endpoints |
| N26 | Headless web login with push approval |
| PayPal | PayPal's own web login in a visible window (you sign in yourself), then its web endpoints |
| Any other bank YAXI reaches (beta) | YAXI's service with your own YAXI access (FinTS or PSD2 behind it; accounts, balances, transactions; no depots) |

CSV import works for every account, including accounts without a bank connection; CSV export works for every list. Unofficial and web-banking interfaces can change at any
time and may break MFN without notice.

## Install

- **Download:** signed and notarised DMG from the Releases page; the app updates itself via Sparkle.
- **Build from source:**

  ```sh
  git clone https://github.com/ahef-xyz/moneyfornothing.git && cd moneyfornothing/macos-app
  xcodebuild -workspace MFN.xcworkspace -scheme MFN -destination 'platform=macOS' build
  ```

  Package tests: `swift test` inside a package under `macos-app/Packages/`. All tests use mock data or
  anonymised fixtures; none talks to a bank.

## FinTS product registration

FinTS banks (ING, DKB) only accept clients with a registered **FinTS product ID**, issued free of
charge by the Deutsche Kreditwirtschaft (DK). The terms ask that the ID is not published.

- Official release builds carry the maintainer's registered product ID. If you use the downloaded
  app, you do not need to register anywhere.
- Builds from source (for your own personal use, see [License](#license)) need **your own** registration. Apply with the DK (search for "FinTS
  Produktregistrierung"), then copy `macos-app/MFNApp/Config/FinTS.local.xcconfig.example` to
  `macos-app/MFNApp/Config/FinTS.local.xcconfig` (gitignored) and set `MFN_FINTS_PRODUCT_ID`.
- Without it the app sends the placeholder `MFN-UNREGISTERED`, the banks reject FinTS and the
  FinTS-based connections are unavailable. Web-based connectors are unaffected.

## Disclaimer

MFN is an independent project. **It is not affiliated with, endorsed by or supported by any bank**
(ING, DKB, Trade Republic, C24, easybank, N26 or others). Several connectors use unofficial
interfaces or automate the web banking you could use yourself; this may conflict with a bank's
terms of use and may lead to blocked logins. You use MFN at your own risk. The software is
provided without warranty of any kind (see `LICENSE`). MFN only reads data and never moves money,
but you remain responsible for your accounts and credentials.

## More

- [Website](https://www.moneyfornothing.app): features, screenshots, FAQ, changelog
- [`CONTRIBUTING.md`](CONTRIBUTING.md): issues only (no pull requests), architecture and rules for personal changes
- [`SECURITY.md`](SECURITY.md): reporting vulnerabilities
- [`PROTOCOL.md`](macos-app/PROTOCOL.md): the frozen connector protocol
- [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md): bundled third-party software

## License

MFN is licensed under the [PolyForm Strict License 1.0.0](https://polyformproject.org/licenses/strict/1.0.0/)
with one additional permission, see `LICENSE`. In short:

| | |
| --- | --- |
| Use MFN for your own, noncommercial purposes | allowed |
| Read the source code, build it, change it for yourself | allowed |
| Pass on MFN or a changed version, in source or binary form | not allowed |
| Commercial use, selling, offering it as a service | not allowed |

The only distributed build is the official signed release. Third-party components keep their own
licenses (`THIRD-PARTY-NOTICES.md`). This summary is not legal advice; the `LICENSE` text applies.
