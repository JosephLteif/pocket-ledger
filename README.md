# Pocket Ledger

Pocket Ledger is a local-first personal finance ledger for iPhone and Apple Watch, built with SwiftUI. Keep accounts, transactions, budgets, receipts, and reports together without linking a bank account.

[Public site](https://josephlteif.github.io/pocket-ledger/) · [Privacy](https://josephlteif.github.io/pocket-ledger/privacy/) · [Support](https://josephlteif.github.io/pocket-ledger/support/) · [Email](mailto:joelteif11@gmail.com)

## What it does

- Tracks balances separately by account currency, including USD and LBP.
- Records purchases split across accounts and currencies, transfers, exchange rates, and change returned in another currency.
- Supports editable transaction history, budgets, scheduled entries, templates, and reports.
- Imports CSV, TSV, JSON, Excel, and supported SQLite exports. Full `.pocketledger` backups can include receipt attachments.
- Scans receipts on device and offers optional on-device writing assistance when Apple’s Foundation Models are available.
- Includes widgets, Apple Watch views, and authenticated Siri, Shortcuts, and system control actions.

## Privacy and data

Ledger data and attachments are stored locally on the user’s devices. The app does not connect to financial institutions or send ledger data to a developer-operated server, advertising network, analytics service, or third-party AI service. Watch features can synchronize selected data to a paired Apple Watch. Exports are shared only when the user chooses a destination.

Read the full [privacy policy](https://josephlteif.github.io/pocket-ledger/privacy/). For support or privacy questions, email [joelteif11@gmail.com](mailto:joelteif11@gmail.com). Please do not email account numbers, balances, receipts, backups, or other private financial information.

## Platforms

The current project configuration targets iOS 26 and watchOS 26. The app is native SwiftUI and includes a WidgetKit extension and Apple Watch companion. The app, extensions, and generated Xcode project use the Pocket Ledger name.

## Build an unsigned iOS artifact

The **Build unsigned iOS IPA** workflow uses a macOS runner and XcodeGen to create the Xcode project from `project.yml`. It builds without Apple signing credentials and uploads a short-lived artifact. The workflow can also build the Watch app and optionally run Simulator tests.

1. Open the project’s Actions page.
2. Select **Build unsigned iOS IPA** and choose **Run workflow**.
3. Download the artifact from the completed run.

The unsigned artifact is for development and sideloading; it is not an App Store distribution build. Apple signing, App Store metadata, and on-device behavior require separate Apple-side setup and review.

## Build an isolated sandbox sideload

The **Build Pocket Ledger Sandbox IPA** workflow creates a second installable app with bundle ID `com.josephlteif.pocketledger.sandbox` and app group `group.com.josephlteif.pocketledger.sandbox`. It uses a separate storage container and can sit beside the normal `com.josephlteif.pocketledger` app, so test transactions do not mix with the ledger you use every day. Run it from the Actions page and install its uploaded IPA through your sideloading tool.

## Project layout

- `PocketLedger/App`: SwiftUI screens, ledger state, import/export, and app intents.
- `PocketLedger/Models`: ledger, finance, and reporting models.
- `PocketLedger/Services`: storage, security, receipt processing, Watch connectivity, and local notifications.
- `PocketLedger/Shared`: shared intents and Watch data contracts.
- `PocketLedgerWidget`, `PocketLedgerWatch`, `PocketLedgerWatchWidget`: widgets and Watch targets.
- `PocketLedger/Config` and extension `Config` folders: entitlements and privacy manifests.
- `docs/`: public product, privacy, and support pages deployed with the Pages workflow.
- `.github/workflows/`: unsigned app build and public site deployment workflows.

## Security notes

The optional app lock protects the main app surface. Widgets and other system surfaces are separate from that lock; review their privacy settings on your devices if balances should remain hidden. File imports, exports, and backups are user initiated. See the in-app privacy policy and the public [privacy page](https://josephlteif.github.io/pocket-ledger/privacy/) for storage and deletion details.
