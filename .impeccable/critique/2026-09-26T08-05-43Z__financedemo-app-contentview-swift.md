---
target: Whole Pocket Ledger app UX and UI review
total_score: 23
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:C:\\Programming\\Finance-App\\FinanceDemo\\App\\ContentView.swift"
target_fingerprint: "sha256:278407b4b443117becd92c5616680ce475fd4b75c07ac8d7c3e2325d2efd22d3"
target_path: "C:\\Programming\\Finance-App\\FinanceDemo\\App\\ContentView.swift"
timestamp: 2026-09-26T08-05-43Z
slug: financedemo-app-contentview-swift
---
# Pocket Ledger UX/UI review — 26 September 2026

Method: dual-agent (A: /root/design_review · B: /root/evidence_review), integrated with a separate parent source review. Current native SwiftUI implementation assessed; no rendered iPhone session available. This is a source-backed workflow critique, not visual acceptance testing.

The app has a coherent local-first identity and a strong native foundation. Its biggest opportunity is more predictable financial actions and easier everyday entry. Preserve native tabs and Search, global Add, amount-first expense entry, progressive disclosure, dashboard customization, import staging, transaction undo, and Watch queue recovery.

## Priority issues

1. **P1 — Honor balance privacy in projected cash flow.** Home protects current balances but the optional cash-flow widget renders projected balances and scheduled changes directly. Current balance is visible or inferable while the hide control is active. Apply the same protected amount rendering to projected balances. Evidence: `FinanceDemo/App/DashboardViews.swift:166,345,695–721`. Suggested workflow: `$impeccable harden`.
2. **P1 — Make historical currency changes explicit.** Account currency lives in Opening balance; an explanatory footnote says changing it preserves numbers while changing the currency of related history. Ordinary Save commits the change. Add an affected-record preview and concrete before/after example, explicit confirmation, and recovery. Evidence: `FinanceDemo/App/AccountManagementViews.swift:568–580,643`. Suggested workflow: `$impeccable harden`.
3. **P1 — Complete imported income correction.** Income-only review rows expose received currency but no receiving-account picker. Add it so a single incorrect income row can be repaired before import. Evidence: `FinanceDemo/App/ImportWizardViews.swift:1797–1831`. Suggested workflow: `$impeccable harden`.
4. **P2 — Make totals and drill-downs describe the same records.** Budget drill-down uses category text search rather than the budget's category identity and calculation scope. Carry exact category/descendants, period, inclusion rules, and reporting-currency semantics into the transaction list. Separately, Available balance includes physical assets and investments when included in totals; rename this total or distinguish spendable money from other holdings. Evidence: `FinanceDemo/App/BudgetsView.swift:118–125`; `FinanceDemo/Models/LedgerAnalytics.swift:189–193`. Suggested workflow: `$impeccable clarify`.
5. **P2 — Make widget quick expenses intentional.** Medium widget adds a fixed USD 5 expense to the first eligible account and first active child category; Control Center exposes an amount but still chooses the account/category. Let users select a named saved preset with account/category/currency/amount, or open a prefilled editor. Evidence: `FinanceDemoWidget/BalanceWidget.swift:129–135`; `FinanceDemo/Shared/DemoIntents.swift:28–43,59–97`. Suggested workflow: `$impeccable shape`.

## Improvements across the app

| Surface | Concrete improvement |
|---|---|
| Home | Show currencies the user actually uses, with an option to show all. Keep one dominant balance area followed by monthly spending and recent activity. Current default already disables accounts, upcoming, cash flow, budget pulse and storage widgets; avoid treating the default as if every widget is shown. `DashboardViews.swift:315,563`; `DashboardPreferences.swift:96–114`. |
| Add transaction | Show validation next to invalid amounts, accounts and rates. Currently the explanation is after the form while Save is disabled in the toolbar. Preserve amount autofocus, recent defaults and More details. `TransactionEditor.swift:382–387,447–448`. |
| Categories | Replace the raw SF Symbol text field with a labeled icon chooser and preview. Make category selection searchable with recent choices while retaining selectable parents and hierarchy. `CategoryManagementViews.swift:268`; `CategoryPicker.swift:12–25`. |
| Accounts | Distinguish Add account from Add expense visually: Accounts has a plus while the shared toolbar adds plus.circle. Add the transaction editor's dirty-form protection to account/category/budget editors. `AccountManagementViews.swift:69–75,557–613`; `ContentView.swift:175–182`. |
| Transactions and Search | Make Undo and success/error feedback consistent in Home, Search, account activity and Metrics. Main Transactions has an Undo banner; other callbacks directly delete after the shared confirmation. Empty Search can offer recent searches or examples. `TransactionViews.swift:395–401,574–579`; `SearchView.swift:129–140,203`; `AccountViews.swift:448`; `DashboardViews.swift:820`. |
| Budgets | Preserve existing remaining amount, projections and drill-down; improve exact drill-down scope and explain disabled Save near its fields. `BudgetsView.swift:97–127,198–212`. |
| Metrics | Give account breakdown rows the same drill-down capability as category rows, or visibly distinguish their behavior. Bound the eagerly rendered category-detail transaction list for large histories; this is a source-level risk, not measured jank. `MetricsView.swift:533–571,1060–1098`. |
| Schedules | Make cards an agenda: next due date, amount, account/status and one main action. Move reminder selectors and administrative actions into details. Keep current posting explanations and record Undo. `SchedulingViews.swift:284–424,481–496`. |
| Templates | Keep Create template available after the first template exists. It currently appears only in the empty state. Favorite or recent templates could make the global Add menu more useful. `TemplatesView.swift:20–59`; `ContentView.swift:323–338`. |
| Import | Initially emphasize required mappings, with sample values beside each mapping; disclose reporting and transfer mappings when needed. The form currently shows 14 mapping controls, with samples below them. Give skipped rows a clear fix/export recovery path. `ImportWizardViews.swift:637–681,1647–1652`. |
| Setup | Offer Start fresh and Import existing history as first-class choices. Setup currently offers account creation and Skip. `SetupWizardView.swift:24–58`. |
| Backup and Settings | Preserve full backup including receipts and last-good recovery. Make full backup the clear default and compatibility formats secondary. Replace technical explanations such as salted verifier with task-focused wording, leaving details in help. `DataTransferViews.swift:149–183`; `SecurityViews.swift:167`. |
| Receipt scanning | Preserve editable item selection and manual correction. Verify interruption, keyboard and error recovery on-device before proposing a redesign; no confirmed scanner blocker found. `BillScannerView.swift:450–750`. |
| Watch and widgets | Preserve queue status, stale-data indication and retry/correction/discard. Replace widget App Group/signing error copy with user recovery guidance. `WatchHomeView.swift:20–69`; `WatchExpenseView.swift:70–160`; `BalanceWidget.swift:100–119`. |

## Visual and accessibility direction

Preserve the established native forms, grouped surfaces, semantic typography and restrained accents. Make amounts the strongest text, labels secondary, and explanations tertiary; avoid using tiny text or scaling down as the primary way to fit important financial values. Validate light/dark themes, largest Dynamic Type, long account/category names, large LBP values, keyboard reachability and VoiceOver on-device.

Specific candidates: balance visibility control has no explicit minimum tap frame (`DesignSystem.swift:259–272`); its hint should differ between Hide and Reveal. The lock screen uses a non-scrolling VStack (`SecurityViews.swift:457–517`), so test large text plus keyboard on a small supported iPhone before claiming clipping. No contrast failure is established: the reviewed text accessors use semantic `.primary`/`.secondary`; palette-based contrast calculations for unused properties were rejected during integration.

Apple references: [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Entering data](https://developer.apple.com/design/human-interface-guidelines/entering-data).

## Provisional heuristic score

Scores describe source-observable workflows, not rendered appearance or measured usability. 0 is poor; 4 is excellent.

| Heuristic | Score | Main opportunity |
|---|---:|---|
| System status | 3 | Local feedback near actions |
| Real-world language | 2 | Balance naming, SF Symbol and technical copy |
| Control and freedom | 3 | Consistent Undo and dirty-form protection |
| Consistency | 2 | Equivalent row actions and editors |
| Error prevention | 2 | Historical currency confirmation |
| Recognition over recall | 2 | Searchable categories and named icon selection |
| Flexibility and efficiency | 3 | Useful bulk actions and templates already present |
| Minimalist design | 2 | Schedule and import form density |
| Error recovery | 2 | Complete per-row income correction |
| Contextual help | 2 | Explain blocked actions where they occur |
| Total | 23/40 | Workflow improvements warranted; visual score unverified |

## Cognitive load and user perspectives

Daily user: amount autofocus is effective; below-form validation and inconsistent Undo interrupt the quick path. Migrating user: 14 mapping fields and incomplete income correction cause backtracking. Multi-currency user: currency reinterpretation and imprecise budget drill-down reduce confidence in totals. Accessibility-dependent user: validate error discoverability, category announcements, dense schedule rows and lock-screen keyboard layout with VoiceOver and large text.

Recommended order: privacy and historical-currency safeguards; income import correction and exact drill-downs; daily entry/categories/templates/feedback; then visual and accessibility polish.

Decision for the next pass: trust and correctness, faster everyday use, or visual polish? This review authorizes no implementation or release changes.
