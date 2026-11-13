# Pocket Ledger

Pocket Ledger is a local-first personal finance ledger for iPhone, built with SwiftUI. Keep accounts, transactions, budgets, receipts, and reports together without linking a bank account.

[Public site](https://josephlteif.github.io/pocket-ledger/) · [Privacy](https://josephlteif.github.io/pocket-ledger/privacy/) · [Support](https://josephlteif.github.io/pocket-ledger/support/) · [Email](mailto:josephmllteif@icloud.com,josephmllteif@gmail.com)

## What it does

- Tracks balances separately by account currency, including USD and LBP.
- Records purchases split across accounts and currencies, transfers, exchange rates, and change returned in another currency.
- Supports editable transaction history, budgets, scheduled entries, templates, and reports.
- Imports CSV, TSV, JSON, Excel, and supported SQLite exports. Full `.pocketledger` backups can include receipt attachments.
- Scans receipts on device and offers optional on-device writing assistance when Apple’s Foundation Models are available.
- Includes authenticated Siri and Shortcuts actions.

## Privacy and data

Ledger data and attachments are stored locally on the user’s device. The app does not connect to financial institutions or send ledger data to a developer-operated server, advertising network, analytics service, or third-party AI service. Exports are shared only when the user chooses a destination.

Read the full [privacy policy](https://josephlteif.github.io/pocket-ledger/privacy/). For support or privacy questions, email [josephmllteif@icloud.com](mailto:josephmllteif@icloud.com) or [josephmllteif@gmail.com](mailto:josephmllteif@gmail.com). Please do not email account numbers, balances, receipts, backups, or other private financial information.

## Platforms

The current project configuration targets iOS 26. The app is native SwiftUI and the generated Xcode project uses the Pocket Ledger name.

## Build an unsigned iOS artifact

The **Build unsigned iOS IPA** workflow uses the hosted `xcode-27` macOS runner and selects Xcode 27.2. XcodeGen creates the Xcode project from `project.yml`; the workflow builds the iPhone app without Apple signing credentials, uploads a short-lived IPA artifact, and can optionally build a separate sandbox app or run Simulator tests.

1. Open the project’s Actions page.
2. Select **Build unsigned iOS IPA** and choose **Run workflow**.
3. Download the artifact from the completed run.

The unsigned artifact is for development and sideloading; it is not an App Store distribution build. Apple signing, App Store metadata, and on-device behavior require separate Apple-side setup and review.

## Build an isolated sandbox sideload

The **Build Pocket Ledger Sandbox IPA** workflow creates a second installable app with bundle ID `com.josephlteif.pocketledger.sandbox` and app group `group.com.josephlteif.pocketledger.sandbox`. It uses a separate storage container and can sit beside the normal `com.josephlteif.pocketledger` app, so test transactions do not mix with the ledger you use every day. Run it from the Actions page and install its uploaded IPA through your sideloading tool.

## Project layout

- `PocketLedger/App`: SwiftUI screens, ledger state, import/export, and app intents.
- `PocketLedger/Models`: ledger, finance, and reporting models.
- `PocketLedger/Services`: storage, security, receipt processing, and local notifications.
- `PocketLedger/Shared`: App Intents and shared finance actions.
- `PocketLedger/Config`: app entitlements and privacy manifest.
- `docs/`: public product, privacy, and support pages deployed with the Pages workflow.
- `.github/workflows/`: unsigned app build and public site deployment workflows.

## Security notes

The optional app lock protects the main app surface. App Intent actions that change ledger data require authentication. File imports, exports, and backups are user initiated. See the in-app privacy policy and the public [privacy page](https://josephlteif.github.io/pocket-ledger/privacy/) for storage and deletion details.
