# Native iOS redesign validation

Implementation is uncommitted. Windows source checks do not establish SwiftUI type correctness or visual acceptance.

## Checks completed here

- Changed Swift sources parsed with tree-sitter; its existing StoreKit purchase parsing limitation is unchanged.
- Scoped whitespace/diff checks passed.
- Source review covered navigation raw values, search lock gating, draft protection, amount formatting, optional-field expansion, and preserved financial save paths.
- Product/design direction and reference board are recorded in `PRODUCT.md`, `DESIGN.md`, and `native-ios-reference.png`.

## Required macOS run

Use this working tree on a Mac with the repository's supported Xcode and XcodeGen. Generate the project, then run focused checks and screenshot captures on both the smallest supported available iPhone simulator and a regular iPhone. Replace `<SIMULATOR_ID>` with an available simulator UUID.

```sh
xcodegen generate --spec project.yml
xcodebuild -project PocketLedger.xcodeproj -scheme PocketLedger \
  -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  -parallel-testing-enabled NO -resultBundlePath NativeRedesign.xcresult \
  CODE_SIGNING_ALLOWED=NO POCKET_LEDGER_DEVELOPER_PRO_OVERRIDE=YES \
  test -only-testing:PocketLedgerTests/AppNavigationTests \
  -only-testing:PocketLedgerTests/DashboardPreferencesTests \
  -only-testing:PocketLedgerUITests/DesignReviewScreenshots
xcrun xcresulttool export attachments --path NativeRedesign.xcresult \
  --output-path native-redesign-screenshots
```

The Pro screenshot scenario uses the existing explicitly enabled developer override in a Debug simulator build. It does not verify a StoreKit purchase or change production entitlement rules. Other scenarios explicitly disable the override. Empty/long-name fixtures are available only under `DEBUG` and `-DesignReviewMode`.

The existing screenshot workflow now includes focused navigation/dashboard tests and these scenarios. It captures its checked-out commit; it cannot validate the uncommitted working tree.

## Acceptance review still pending

- Compare actual Home, Add, Expense, and Insights captures with the reference board.
- Inspect every supplied editor, detail, planning, settings, privacy, and import flow; expand contextual help and existing advanced values.
- Check light/dark, accessibility text size, keyboard presentation, long names, empty/populated data, Free/developer-Pro, and USD/LBP amounts.
- Verify saved searches and result navigation, balance reveal/conceal with authentication and background locking, remembered dashboard ordering, and unsaved-draft cancellation.
- Verify ordinary transaction rows and required entry fields are reachable immediately, with meaningful labels and 44-point controls.
- Exercise splits, multi-currency rates, loan collections, asset funding, imports/previews/exceptions, and destructive confirmations against the unchanged financial behavior.

Do not mark visual acceptance complete until these captures and simulator interactions have been reviewed. No Watch/widget validation, publishing, or deployment is included.
