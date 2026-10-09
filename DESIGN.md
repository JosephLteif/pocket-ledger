# Pocket Ledger iOS design

## Approved direction

Compact native iOS controls with a warm copper tint. Neutral semantic grouped backgrounds, native inset lists, system separators, San Francisco text styles, and SF Symbols. Native bar materials remain; content surfaces use no decorative gradients, shadows, or nested cards.

## Navigation

Home, Transactions, Accounts, Insights, More. Global search opens a focused sheet from each main tab. Add opens an entry-type chooser. Overflow holds balance visibility and secondary actions. Main screens use collapsing large titles; detail screens and editors use short inline titles.

## Content and entry

Show currency balances, this month, and recent activity first on a new dashboard; preserve saved customization. Compact rows carry essential content. Optional empty widgets use one row. Forms put amount and accounts before optional notes, receipts, splits, schedules, and rates. Populated advanced options remain expanded when editing. Do not show validation errors on untouched drafts.

Help is contextual. Never hide warnings needed to avoid data loss, alter currency, or understand import exceptions. Pro eligibility and financial behavior remain unchanged.

## Accessibility

Use Dynamic Type, semantic colors, 44-point touch targets, meaningful persistent field labels, and accessible privacy descriptions. Support dark appearance and Reduce Motion. Financial amounts remain protected by the existing visibility control.

## Reference and verification

Reference board: [native-ios-reference.png](docs/design/native-ios-reference.png). Generated with the built-in ImageGen tool on 2026-10-09, showing Home, Add, Expense, Insights, and dark Home. Illustrative values and symbols are not product behavior or runtime evidence.

Prompt: Native iOS finance UI, neutral system grouped surfaces, copper accent, Home balances and activity, grouped Add chooser, essential expense fields before More options, compact Insights controls/chart, five native tabs, and representative dark appearance. No decorative gradients, oversized empty cards, slogans, or initial validation banner.

Use the existing design review screenshot suite on a macOS iPhone simulator to verify the implementation, including light/dark appearance, small screens, large text, empty/populated data, and Free/Pro states.
