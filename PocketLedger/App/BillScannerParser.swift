import Foundation

enum BillScannerParser {
    struct Payment: Sendable {
        let totals: [Money]
        let currencies: [LedgerCurrency]
        let hasPrintedTotal: Bool

        var currency: LedgerCurrency { currencies.first ?? .usd }
    }

    struct ItemSuggestion: Sendable {
        let name: String
        let lineTotal: String
    }

    private static let numberPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\d])(?:[-+−]\h*)?(?:[0-9]{1,3}(?:[ \u00A0\u202F\u2009][0-9]{3})+|[0-9]+)(?:[.,٫٬][0-9]+)*(?![\p{L}\d])"#
    )
    private static let currencyPattern = try! NSRegularExpression(
        pattern: #"(?i)(?<!\p{L})(?:USD|EUR|EUROS?|LBP|L\.?L\.?|US\x24|دولار|ل\s*\.?\s*ل\.?|ليرة لبنانية)(?!\p{L})|[\x24€]"#
    )
    private static let payableLabels = #"amount\s+(?:due|payable)|total\s+(?:due|payable|ttc|à\s+payer|général)|grand\s+total|(?:net|montant)\s+à\s+payer|montant\s+ttc|net\s+payable|balance\s+due|المبلغ\s+(?:المستحق|الإجمالي|الاجمالي)|(?:الإجمالي|الاجمالي|المجموع)\s+(?:النهائي|الكلي|المستحق)"#
    private static let totalPattern = try! NSRegularExpression(
        pattern: #"(?i)^(?:\#(payableLabels)|total|الإجمالي|الاجمالي|المجموع)(?!\p{L})\s*[:=]?\s*"#
    )
    private static let metadataPattern = try! NSRegularExpression(
        pattern: #"(?i)^(?:sub\s*total|sous[ -]total|tax|vat|tva|discount|remise|change(?:\s+due)?|monnaie|cash(?:\s+(?:tendered|received))?|espèces|(?:credit|debit)(?:\s+card)?|visa|mastercard|card|payment|balance|équivalent|equivalent|contre[ -]valeur|الضريبة|ضريبة|خصم|الحسم|الباقي|نقداً?|المقابل|يعادل|المجموع الفرعي)(?!\p{L})\s*[:=]?\s*"#
    )
    private static let referencePattern = try! NSRegularExpression(
        pattern: #"(?i)^(?:tel\.?|phone|mobile|fax|date|time|invoice|receipt|facture|cashier|reference|terminal|auth|transaction|order)(?:\s*(?:[:#]|n[°ºo]\.?\s*\d)|\s*\d)|\b\d{1,4}[/.-]\d{1,4}[/.-]\d{1,4}\b|\b\d{1,2}:\d{2}\b"#
    )
    private static let quantityPattern = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\d])(?:([1-9]\d?)\s*[x×](?!\p{L})|[x×]\s*([1-9]\d?)(?![\p{L}\d]))"#
    )

    static func orderedText(_ fragments: [(text: String, bounds: CGRect)]) -> String {
        let sorted = fragments.sorted {
            if $0.bounds.midY == $1.bounds.midY { return $0.bounds.minX < $1.bounds.minX }
            return $0.bounds.midY > $1.bounds.midY
        }
        var rows: [[(text: String, bounds: CGRect)]] = []
        for fragment in sorted {
            if let anchor = rows.last?.first,
               abs(anchor.bounds.midY - fragment.bounds.midY) <= min(anchor.bounds.height, fragment.bounds.height) / 2 {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { row in
            let columns = row.sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text)
            if let first = columns.first, let last = columns.last, columns.count > 1,
               isAmountOnly(cleanLine(first)),
               withoutCurrencies(last).range(of: #"\p{Arabic}"#, options: .regularExpression) != nil {
                return columns.reversed().joined(separator: "\t")
            }
            return columns.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func payment(in text: String) -> Payment {
        let lines = text.components(separatedBy: .newlines).map(cleanLine).filter { !$0.isEmpty }
        let itemCurrencies = Set(lines.filter { !isMetadata($0) && !numbers(in: withoutCurrencies($0)).isEmpty }
            .flatMap(currencies(in:)))

        let summaries = lines.enumerated().compactMap { index, line -> (text: String, rank: Int)? in
            guard let label = match(totalPattern, in: line) else { return nil }
            var amountText = (line as NSString).substring(from: NSMaxRange(label.range))
            if index + 1 < lines.count,
               numbers(in: withoutCurrencies(amountText)).isEmpty,
               isAmountOnly(amountText),
               isAmountOnly(lines[index + 1]) {
                amountText += "\t" + lines[index + 1]
            }
            guard isAmountOnly(amountText) else { return nil }
            let labelText = (line as NSString).substring(with: label.range)
            let isPayable = labelText.range(of: "^(?:\(payableLabels))", options: [.regularExpression, .caseInsensitive]) != nil
            return (amountText, isPayable ? 2 : 0)
        }
        let printedCurrencies = Set(summaries.flatMap { currencies(in: $0.text) })
        let inferredCurrencies = printedCurrencies.isEmpty ? itemCurrencies : printedCurrencies
        var totals: [Money] = []
        var preferredRank = 0
        for summary in summaries {
            let values = numbers(in: withoutCurrencies(summary.text))
            guard !values.isEmpty else { continue }
            let markers = currencies(in: summary.text)
            let rank = summary.rank + (markers.isEmpty ? 1 : 2)
            guard rank >= preferredRank else { continue }

            if rank > preferredRank {
                preferredRank = rank
                totals = []
            }
            guard !summary.text.contains("(") else { continue }
            let candidates: [Money]
            if Set(markers).count > 1, values.count == markers.count {
                let matched = zip(values, markers).compactMap { amount($0.0.value, currency: $0.1) }
                candidates = matched.count == markers.count ? matched : []
            } else if values.count == 1, let value = values.first {
                if let currency = markers.first ?? (inferredCurrencies.count == 1 ? inferredCurrencies.first : nil) {
                    candidates = amount(value.value, currency: currency).map { [$0] } ?? []
                } else if inferredCurrencies.isEmpty {
                    candidates = LedgerCurrency.allCases.compactMap { amount(value.value, currency: $0) }
                } else {
                    candidates = []
                }
            } else {
                candidates = []
            }
            for candidate in candidates where !totals.contains(candidate) {
                totals.append(candidate)
            }
        }

        let currencies = totals.isEmpty ? inferredCurrencies : Set(totals.map(\.currency))
        return Payment(
            totals: totals,
            currencies: LedgerCurrency.allCases.filter(currencies.contains),
            hasPrintedTotal: preferredRank > 0
        )
    }

    static func items(
        in text: String,
        currency: LedgerCurrency,
        suggestions: [ItemSuggestion] = [],
        locale: Locale = .current
    ) -> [BillLineItem] {
        let lines = text.components(separatedBy: .newlines).map(cleanLine).filter { !$0.isEmpty }
        return lines.enumerated().compactMap { index, line in
            if let item = item(from: line, currency: currency, locale: locale) { return item }
            guard !suggestions.isEmpty, index + 1 < lines.count,
                  isWrappedItem(line, price: lines[index + 1]),
                  let recovered = item(from: line + "\t" + lines[index + 1], currency: currency, locale: locale) else { return nil }
            // The model can identify a wrapped item. Its proposed name and amount must both match the OCR.
            guard suggestions.contains(where: {
                $0.name.compare(recovered.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    && amount(cleanLine($0.lineTotal), currency: currency) == recovered.total(in: currency, locale: locale)
            }) else { return nil }
            return recovered
        }
    }

    static func canRecoverWrappedItems(in text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).map(cleanLine).filter { !$0.isEmpty }
        return zip(lines, lines.dropFirst()).contains { isWrappedItem($0.0, price: $0.1) }
    }

    private static func isWrappedItem(_ name: String, price: String) -> Bool {
        name.rangeOfCharacter(from: .letters) != nil
            && !isMetadata(name)
            && isAmountOnly(price)
            && !numbers(in: withoutCurrencies(price)).isEmpty
    }

    private static func item(from original: String, currency: LedgerCurrency, locale: Locale) -> BillLineItem? {
        guard !isMetadata(original), currencies(in: original).allSatisfy({ $0 == currency }) else { return nil }
        var line = withoutCurrencies(original).trimmingCharacters(in: .whitespaces)
        var quantity = 1
        let explicitQuantity = match(quantityPattern, in: line)
        if let explicit = explicitQuantity {
            let source = line as NSString
            let quantityRange = explicit.range(at: explicit.range(at: 1).location == NSNotFound ? 2 : 1)
            quantity = Int(source.substring(with: quantityRange)) ?? 1
            line = source.replacingCharacters(in: explicit.range, with: " ").trimmingCharacters(in: .whitespaces)
        }

        let tokens = numbers(in: line)
        let source = line as NSString
        guard let last = tokens.last,
              let total = amount(last.value, currency: currency),
              source.substring(from: NSMaxRange(last.range)).allSatisfy({ $0.isWhitespace || ".*".contains($0) }) else { return nil }

        var unitPrice: Money?
        var removed = [last.range]
        if tokens.count >= 2 {
            let unit = tokens[tokens.count - 2]
            let gap = source.substring(with: NSRange(location: NSMaxRange(unit.range), length: last.range.location - NSMaxRange(unit.range)))
            if gap.allSatisfy(\.isWhitespace), let unitAmount = amount(unit.value, currency: currency) {
                if tokens.count >= 3, explicitQuantity == nil {
                    let first = tokens[tokens.count - 3]
                    if let count = Int(first.value), (1...99).contains(count),
                       total.minorUnits % Int64(count) == 0,
                       total.minorUnits / Int64(count) == unitAmount.minorUnits {
                        quantity = count
                        removed.append(first.range)
                    }
                }
                if quantity > 1 || unitAmount == total {
                    unitPrice = unitAmount
                    removed.append(unit.range)
                }
            }
        }
        if unitPrice == nil, total.minorUnits % Int64(quantity) == 0 {
            unitPrice = Money(currency: currency, minorUnits: total.minorUnits / Int64(quantity))
        }

        let name = removed.sorted { $0.location > $1.location }.reduce(line) {
            ($0 as NSString).replacingCharacters(in: $1, with: " ")
        }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
        guard name.rangeOfCharacter(from: .letters) != nil else { return nil }
        return BillLineItem(
            name: name,
            quantity: quantity,
            unitPriceText: unitPrice.map { currency.formattedInput(minorUnits: $0.minorUnits, locale: locale) } ?? "",
            lineTotalText: currency.formattedInput(minorUnits: total.minorUnits, locale: locale)
        )
    }

    private static func amount(_ raw: String, currency: LedgerCurrency) -> Money? {
        let compact = raw.filter { !$0.isWhitespace }
        let value = compact.replacingOccurrences(of: #"٬(?=[0-9]{3}(?:[.,٫٬]|$))"#, with: "", options: .regularExpression)
        let normalized: String
        if let arabicDecimal = value.firstIndex(of: "٫") {
            normalized = value[..<arabicDecimal].replacingOccurrences(of: ",", with: "") + "." + value[value.index(after: arabicDecimal)...]
        } else if let separator = value.lastIndex(where: { $0 == "." || $0 == "," }) {
            let groups = value.split(whereSeparator: { $0 == "." || $0 == "," })
            let suffix = value[value.index(after: separator)...]
            guard !suffix.isEmpty else { return nil }
            if (1...2).contains(suffix.count) {
                guard currency.fractionDigits > 0 || suffix.allSatisfy({ $0 == "0" }) else { return nil }
                let whole = groups.dropLast()
                guard whole.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
                normalized = whole.joined() + "." + suffix
            } else {
                guard groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
                normalized = groups.joined()
            }
        } else {
            normalized = value
        }
        guard normalized.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let scaled = decimal * Decimal(currency.minorUnitScale)
        var valueToRound = scaled
        var minorUnits = Decimal()
        NSDecimalRound(&minorUnits, &valueToRound, 0, .plain)
        guard minorUnits == scaled, minorUnits > 0, minorUnits <= Decimal(Int64.max) else { return nil }
        return Money(currency: currency, minorUnits: NSDecimalNumber(decimal: minorUnits).int64Value)
    }

    private static func isMetadata(_ line: String) -> Bool {
        if match(referencePattern, in: line) != nil { return true }
        let stripped = withoutCurrencies(line).trimmingCharacters(in: .whitespaces)
        return [totalPattern, metadataPattern].contains { pattern in
            guard let label = match(pattern, in: stripped) else { return false }
            let suffix = (stripped as NSString).substring(from: NSMaxRange(label.range))
            return isAmountOnly(suffix.replacingOccurrences(of: "%", with: ""))
        }
    }

    private static func isAmountOnly(_ text: String) -> Bool {
        let stripped = withoutCurrencies(text)
        return numberPattern.stringByReplacingMatches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: "")
            .allSatisfy { $0.isWhitespace || ":=()-*".contains($0) }
    }

    private static func cleanLine(_ text: String) -> String {
        String(text.map { character in
            guard character.isNumber, let digit = character.wholeNumberValue, digit < 10 else { return character }
            return Character(String(digit))
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func numbers(in text: String) -> [(range: NSRange, value: String)] {
        let source = text as NSString
        return numberPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            ($0.range, source.substring(with: $0.range))
        }
    }

    private static func currencies(in text: String) -> [LedgerCurrency] {
        let source = text as NSString
        return currencyPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            switch source.substring(with: $0.range).uppercased() {
            case "€", "EUR", "EURO", "EUROS": return .eur
            case "$", "US$", "USD", "دولار": return .usd
            default: return .lbp
            }
        }
    }

    private static func withoutCurrencies(_ text: String) -> String {
        currencyPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\t")
    }

    private static func match(_ pattern: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
