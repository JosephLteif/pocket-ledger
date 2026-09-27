import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision

struct BillLineItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var quantity: Int
    var unitPriceText: String
    var lineTotalText: String
    var lineTotalOverrideText: String? = nil
    var isSelected: Bool
    private let initialQuantity: Int
    private let initialUnitPriceText: String

    init(
        id: UUID = UUID(),
        name: String,
        quantity: Int = 1,
        unitPriceText: String = "",
        lineTotalText: String = "",
        isSelected: Bool = true
    ) {
        let normalizedQuantity = max(quantity, 1)
        self.id = id
        self.name = name
        self.quantity = normalizedQuantity
        self.unitPriceText = unitPriceText
        self.lineTotalText = lineTotalText
        self.isSelected = isSelected
        self.initialQuantity = normalizedQuantity
        self.initialUnitPriceText = unitPriceText
    }

    func total(in currency: LedgerCurrency) -> Money? {
        let multiplier = Int64(max(quantity, 1))

        if let lineTotalOverrideText {
            guard let lineTotal = Money.parse(lineTotalOverrideText, currency: currency),
                  lineTotal.minorUnits > 0 else {
                return nil
            }
            return lineTotal
        }

        if quantity == initialQuantity,
           unitPriceText == initialUnitPriceText,
           let lineTotal = Money.parse(lineTotalText, currency: currency),
           lineTotal.minorUnits > 0 {
            return lineTotal
        }

        if let unitPrice = Money.parse(unitPriceText, currency: currency),
           unitPrice.minorUnits > 0 {
            let (minorUnits, overflow) = unitPrice.minorUnits.multipliedReportingOverflow(by: multiplier)
            guard !overflow else { return nil }
            return Money(currency: currency, minorUnits: minorUnits)
        }

        guard let lineTotal = Money.parse(lineTotalText, currency: currency),
              lineTotal.minorUnits > 0 else {
            return nil
        }
        return lineTotal
    }
}

private struct BillOCRResult: Sendable {
    let text: String
    let items: [BillLineItem]
    let currency: LedgerCurrency
}

private struct BillScanResult: Sendable {
    let text: String
    let items: [BillLineItem]
    let currency: LedgerCurrency
    let statusMessage: String
}

private struct BillTransactionEditorRequest: Identifiable {
    let id = UUID()
    let total: Money?
}

private enum BillScannerError: LocalizedError, Sendable {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The selected image could not be read."
        }
    }
}

private enum BillOCRService {
    static func recognize(from data: Data) async throws -> BillOCRResult {
        let visionResult = try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data),
                  let cgImage = image.cgImage else {
                throw BillScannerError.invalidImage
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            if let supportedLanguages = try? request.supportedRecognitionLanguages() {
                let preferredPrefixes = ["en", "ar", "fr"]
                let languages = preferredPrefixes.compactMap { prefix in
                    supportedLanguages.first { language in
                        language == prefix || language.hasPrefix("\(prefix)-")
                    }
                }
                if !languages.isEmpty {
                    request.recognitionLanguages = languages
                }
            }

            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: CGImagePropertyOrientation(image.imageOrientation),
                options: [:]
            )
            try handler.perform([request])

            let lines = (request.results ?? [])
                .sorted { lhs, rhs in
                    let verticalDifference = abs(lhs.boundingBox.minY - rhs.boundingBox.minY)
                    if verticalDifference > 0.02 {
                        return lhs.boundingBox.minY > rhs.boundingBox.minY
                    }
                    return lhs.boundingBox.minX < rhs.boundingBox.minX
                }
                .compactMap { $0.topCandidates(1).first?.string }
            let recognizedText = lines.joined(separator: "\n")
            return BillScannerParser.parse(recognizedText)
        }.value

        return BillOCRResult(
            text: visionResult.text,
            items: visionResult.items,
            currency: visionResult.currency
        )
    }

    static func analyze(_ visionResult: BillOCRResult) async -> BillScanResult {
        let analysis = await FoundationModelService.analyzeReceipt(text: visionResult.text)
        let aiItems: [BillLineItem] = analysis.items.compactMap { item -> BillLineItem? in
            let unitPriceText = item.unitPriceText.flatMap {
                BillScannerParser.validAmountText($0, currency: visionResult.currency)
            }
            let lineTotalText = item.lineTotalText.flatMap {
                BillScannerParser.validAmountText($0, currency: visionResult.currency)
            }
            guard unitPriceText != nil || lineTotalText != nil else { return nil }

            return BillLineItem(
                name: item.name,
                quantity: item.quantity,
                unitPriceText: unitPriceText ?? "",
                lineTotalText: lineTotalText ?? ""
            )
        }

        switch analysis.status {
        case .applied(let provider) where !aiItems.isEmpty:
            return BillScanResult(
                text: visionResult.text,
                items: aiItems,
                currency: visionResult.currency,
                statusMessage: receiptAnalysisMessage(for: provider)
            )
        case .applied:
            return BillScanResult(
                text: visionResult.text,
                items: visionResult.items,
                currency: visionResult.currency,
                statusMessage: "AI cleanup returned no usable prices, so Vision OCR was used instead. Review the items before saving."
            )
        case .unavailable(let message), .failed(let message):
            return BillScanResult(
                text: visionResult.text,
                items: visionResult.items,
                currency: visionResult.currency,
                statusMessage: message
            )
        }
    }

    private static func receiptAnalysisMessage(
        for provider: FoundationModelService.ReceiptAnalysis.Provider
    ) -> String {
        switch provider {
        case .privateCloudCompute:
            return "Private Cloud Compute cleaned up the receipt items. Review the selection before saving."
        case .onDevice:
            return "On-device AI cleaned up the receipt items. Review the selection before saving."
        case .onDeviceFallback:
            return "Private Cloud Compute was unavailable, so on-device AI cleaned up the receipt items. Review the selection before saving."
        }
    }
}

private enum BillScannerParser {
    private struct NumberToken {
        let range: NSRange
        let value: Decimal
    }

    static func parse(_ text: String) -> BillScanResult {
        let currency = detectCurrency(in: text)
        let items = text
            .components(separatedBy: .newlines)
            .compactMap(parseLine)

        return BillScanResult(
            text: text,
            items: items,
            currency: currency,
            statusMessage: "Vision OCR read the receipt. Review the detected items before saving."
        )
    }

    private static func parseLine(_ line: String) -> BillLineItem? {
        let trimmedLine = normalizeNumerals(in: line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.count >= 2 else { return nil }
        guard !isMetadataLine(trimmedLine) else { return nil }
        guard trimmedLine.rangeOfCharacter(from: .letters) != nil else { return nil }

        let tokens = numberTokens(in: trimmedLine)
        guard let totalToken = tokens.last, totalToken.value > 0 else { return nil }
        guard hasPriceSuffix(after: totalToken, in: trimmedLine) else { return nil }

        var quantity = 1
        var unitPrice = totalToken.value
        if let possibleQuantity = integerQuantity(tokens[0].value) {
            let prefix = (trimmedLine as NSString)
                .substring(to: tokens[0].range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let quantityIsPlausible = prefix.isEmpty
                || prefix.rangeOfCharacter(from: .letters) != nil
                || tokens.count >= 3

            if quantityIsPlausible {
                quantity = possibleQuantity
                if tokens.count >= 3 {
                    unitPrice = tokens[tokens.count - 2].value
                } else {
                    unitPrice = totalToken.value / Decimal(quantity)
                }
            }
        }

        let itemName = cleanedName(from: trimmedLine, removing: tokens)
        let uppercasedName = itemName.uppercased()
        guard itemName.count >= 2,
              !["USD", "LBP", "EUR", "LL"].contains(uppercasedName) else {
            return nil
        }

        return BillLineItem(
            name: itemName,
            quantity: quantity,
            unitPriceText: decimalText(unitPrice),
            lineTotalText: decimalText(totalToken.value)
        )
    }

    fileprivate static func normalizeNumerals(in text: String) -> String {
        String(text.map { character -> Character in
            switch character {
            case "٠": return "0"
            case "١": return "1"
            case "٢": return "2"
            case "٣": return "3"
            case "٤": return "4"
            case "٥": return "5"
            case "٦": return "6"
            case "٧": return "7"
            case "٨": return "8"
            case "٩": return "9"
            case "۰": return "0"
            case "۱": return "1"
            case "۲": return "2"
            case "۳": return "3"
            case "۴": return "4"
            case "۵": return "5"
            case "۶": return "6"
            case "۷": return "7"
            case "۸": return "8"
            case "۹": return "9"
            case "٫": return "."
            case "٬": return ","
            default: return character
            }
        })
    }

    private static func numberTokens(in line: String) -> [NumberToken] {
        let regex = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d{1,3})*"#)
        let nsLine = line as NSString
        let searchRange = NSRange(location: 0, length: nsLine.length)

        return regex.matches(in: line, range: searchRange).compactMap { match in
            let rawValue = nsLine.substring(with: match.range)
            guard let value = decimal(from: rawValue) else { return nil }
            return NumberToken(range: match.range, value: value)
        }
    }

    private static func decimal(from rawValue: String) -> Decimal? {
        let normalizedValue: String
        if let comma = rawValue.lastIndex(of: ","),
           let dot = rawValue.lastIndex(of: ".") {
            if comma > dot {
                normalizedValue = rawValue
                    .replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            } else {
                normalizedValue = rawValue.replacingOccurrences(of: ",", with: "")
            }
        } else if rawValue.filter({ $0 == "," }).count == 1,
                  let comma = rawValue.firstIndex(of: ",") {
            let suffix = rawValue[rawValue.index(after: comma)...]
            normalizedValue = suffix.count == 3
                ? rawValue.replacingOccurrences(of: ",", with: "")
                : rawValue.replacingOccurrences(of: ",", with: ".")
        } else {
            normalizedValue = rawValue.replacingOccurrences(of: ",", with: "")
        }

        return Decimal(
            string: normalizedValue,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func integerQuantity(_ value: Decimal) -> Int? {
        guard value >= 1, value <= 99 else { return nil }
        let integer = NSDecimalNumber(decimal: value).intValue
        return Decimal(integer) == value ? integer : nil
    }

    private static func cleanedName(from line: String, removing tokens: [NumberToken]) -> String {
        var name = line
        for token in tokens.reversed() {
            name = (name as NSString).replacingCharacters(in: token.range, with: " ")
        }

        return name
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && $0.lowercased() != "x" }
            .joined(separator: " ")
    }

    private static func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    fileprivate static func validAmountText(_ text: String, currency: LedgerCurrency) -> String? {
        let normalized = normalizeNumerals(in: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              (Money.parse(normalized, currency: currency)?.minorUnits ?? 0) > 0 else {
            return nil
        }
        return normalized
    }

    private static func hasPriceSuffix(after token: NumberToken, in line: String) -> Bool {
        let suffix = (line as NSString)
            .substring(from: NSMaxRange(token.range))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return true }

        var removableSuffixCharacters = CharacterSet.punctuationCharacters
        removableSuffixCharacters.formUnion(.symbols)
        let normalizedSuffix = suffix
            .trimmingCharacters(in: removableSuffixCharacters)
            .uppercased()
        if normalizedSuffix.isEmpty { return true }
        return ["USD", "LBP", "EUR", "LL", "دولار", "ل.ل"].contains(normalizedSuffix)
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        let lowercasedLine = line.lowercased()
        let ignoredPatterns = [
            #"\b(?:subtotal|total|tax|vat|discount|change|cash|credit|debit|invoice|receipt|thank|date|time|tel|phone|mobile|fax|address|customer|cashier|terminal|reference|auth|approval|order|transaction|loyalty|card|payment)\b"#,
            #"\bamount\s+due\b"#,
            #"\bbalance\b"#
        ]
        guard !ignoredPatterns.contains(where: {
            lowercasedLine.range(of: $0, options: .regularExpression) != nil
        }) else { return true }

        let metadataPatterns = [
            #"\b(?:street|st\.|road|rd\.|avenue|ave\.|boulevard|blvd\.|highway|hwy|lane|ln\.|drive|dr\.|floor|fl\.|suite|ste\.|apt\.|unit|zip|postal)\b"#,
            #"\b\d{1,4}[/.-]\d{1,4}[/.-]\d{1,4}\b"#,
            #"\b\d{1,2}:\d{2}(?::\d{2})?\b"#,
            #"(?:https?://|www\.|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,})"#
        ]
        if metadataPatterns.contains(where: {
            lowercasedLine.range(of: $0, options: .regularExpression) != nil
        }) {
            return true
        }

        let tokens = numberTokens(in: line)
        let digitCount = line.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let hasCurrencyMarker = lowercasedLine.range(
            of: #"(?:\$|€|£|\b(?:usd|lbp|eur|ll)\b|ل\.ل)"#,
            options: .regularExpression
        ) != nil
        if digitCount >= 7 && tokens.count >= 2 && !hasCurrencyMarker {
            return true
        }

        return false
    }

    fileprivate static func detectCurrency(in text: String) -> LedgerCurrency {
        let uppercasedText = text.uppercased()
        let hasStandaloneLL = uppercasedText.range(
            of: #"\bLL\b"#,
            options: .regularExpression
        ) != nil

        if uppercasedText.contains("LBP")
            || uppercasedText.contains("L.L")
            || uppercasedText.contains("ل.ل")
            || hasStandaloneLL {
            return .lbp
        }
        if uppercasedText.contains("EUR")
            || uppercasedText.contains("EURO")
            || uppercasedText.contains("€") {
            return .eur
        }
        return .usd
    }
}

@MainActor
struct BillScannerView: View {
    @ObservedObject var store: LedgerStore
    let initialSource: BillScanSource?
    let initialImageData: Data?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isShowingSourceOptions = false
    @State private var isShowingPhotoPicker = false
    @State private var isShowingFullScreenImage = false
    @State private var pendingCameraImage: UIImage?
    @State private var previewImage: UIImage?
    @State private var recognizedText = ""
    @State private var lineItems: [BillLineItem] = []
    @State private var scanStatusMessage: String?
    @State private var currency: LedgerCurrency = .usd
    @State private var isScanning = false
    @State private var scanProgressMessage = "Reading receipt text…"
    @State private var isShowingCamera = false
    @State private var isShowingDocumentImporter = false
    @State private var isShowingAccountEditor = false
    @State private var transactionEditorRequest: BillTransactionEditorRequest?
    @FocusState private var focusedLineTotalID: UUID?
    @FocusState private var focusedLineItemNameID: UUID?
    @FocusState private var isBillTotalFocused: Bool
    @State private var editingLineItemNameID: UUID?
    @State private var billTotalOverrideText: String?
    @State private var attachmentData: Data?
    @State private var attachmentFileName = "receipt.jpg"
    @State private var attachmentContentType = "image/jpeg"
    @State private var errorMessage: String?
    @State private var didLoadInitialImage = false

    init(
        store: LedgerStore,
        initialSource: BillScanSource? = nil,
        initialImageData: Data? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.initialSource = initialSource
        self.initialImageData = initialImageData
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Add a photo or PDF, then review the detected items.")
                        .font(.subheadline)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)

                    if let previewImage {
                        Button {
                            isShowingFullScreenImage = true
                        } label: {
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(alignment: .bottomTrailing) {
                                    Label("View full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .padding(10)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(PocketLedgerTheme.divider, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open bill image full screen")
                        .accessibilityHint("Pinch to zoom and drag to inspect the receipt")
                    }

                    if isScanning {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(PocketLedgerTheme.accent)
                            Text(scanProgressMessage)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        .padding(14)
                        .pocketGlassSurface(cornerRadius: 16)
                    }

                    if let scanStatusMessage, !scanStatusMessage.isEmpty, !isScanning {
                        Label(scanStatusMessage, systemImage: "sparkles")
                            .font(.footnote)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pocketGlassSurface(cornerRadius: 14)
                    }

                    if !lineItems.isEmpty {
                        reviewItems
                    } else if !isScanning, previewImage != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("No priced items detected", systemImage: "exclamationmark.magnifyingglass")
                                .font(.headline)
                            Text("Add an item manually or try a clearer, closer photo.")
                                .font(.subheadline)
                                .foregroundStyle(PocketLedgerTheme.textSecondary)

                            Button(action: addManualItem) {
                                Label("Add item manually", systemImage: "plus.circle")
                            }
                            .foregroundStyle(PocketLedgerTheme.accent)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pocketGlassSurface(cornerRadius: 18)
                    }

                    if !recognizedText.isEmpty {
                        DisclosureGroup("Recognized text") {
                            Text(recognizedText)
                                .font(.caption.monospaced())
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                        .padding(16)
                        .pocketGlassSurface(cornerRadius: 18)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .pocketScreen()
            .navigationTitle("Scan bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingSourceOptions = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add bill photo or PDF")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done", action: dismissKeyboard)
                }
            }
            .confirmationDialog("Add a bill", isPresented: $isShowingSourceOptions, titleVisibility: .visible) {
                Button {
                    isShowingPhotoPicker = true
                } label: {
                    Label("Choose photo", systemImage: "photo")
                }

                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        isShowingCamera = true
                    } label: {
                        Label("Take photo", systemImage: "camera")
                    }
                }

                Button {
                    isShowingDocumentImporter = true
                } label: {
                    Label("Choose PDF", systemImage: "doc.richtext")
                }
            }
            .photosPicker(
                isPresented: $isShowingPhotoPicker,
                selection: $selectedPhoto,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                loadPhoto(item)
            }
            .onChange(of: currency) { _, newCurrency in
                if let billTotalOverrideText {
                    self.billTotalOverrideText = newCurrency.formattedInput(billTotalOverrideText)
                }
            }
            .fileImporter(
                isPresented: $isShowingDocumentImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false,
                onCompletion: importDocument
            )
            .fullScreenCover(isPresented: $isShowingCamera, onDismiss: processPendingCameraImage) {
                BillCameraView { image in
                    pendingCameraImage = image
                }
            }
            .sheet(item: $transactionEditorRequest) { request in
                TransactionEditor(
                    store: store,
                    initialAmount: request.total,
                    initialBillTotal: request.total,
                    initialNote: transactionNote,
                    initialAttachmentData: attachmentData,
                    initialAttachmentFileName: attachmentFileName,
                    initialAttachmentContentType: attachmentContentType,
                    initialReceiptItems: persistedReceiptItems
                )
                .id(request.id)
            }
            .sheet(isPresented: $isShowingAccountEditor) {
                AccountEditor(store: store, initialCurrency: currency)
            }
            .alert("Bill scan failed", isPresented: errorPresented) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .fullScreenCover(isPresented: $isShowingFullScreenImage) {
                if let previewImage {
                    BillImageFullScreenView(image: previewImage)
                }
            }
            .task {
                switch initialSource {
                case .photoLibrary:
                    isShowingPhotoPicker = true
                case .camera:
                    isShowingCamera = true
                case .pdf:
                    isShowingDocumentImporter = true
                case nil:
                    break
                }

                guard !didLoadInitialImage, let initialImageData else { return }
                didLoadInitialImage = true
                guard let image = UIImage(data: initialImageData) else {
                    errorMessage = BillScannerError.invalidImage.localizedDescription
                    return
                }
                handleImage(image)
            }
        }
    }

    private var reviewItems: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose your items")
                        .font(.title3.weight(.bold))
                    Text("Selected \(selectedItemCount) of \(lineItems.count)")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }

                Spacer()
            }

            ForEach($lineItems) { $item in
                lineItemEditor($item)
            }

            Button(action: addManualItem) {
                Label("Add item manually", systemImage: "plus.circle")
            }
            .foregroundStyle(PocketLedgerTheme.accent)

            totalCard
        }
    }

    private func lineItemEditor(_ item: Binding<BillLineItem>) -> some View {
        let itemID = item.wrappedValue.id
        let isSelected = Binding<Bool>(
            get: { item.wrappedValue.isSelected },
            set: {
                item.wrappedValue.isSelected = $0
                billTotalOverrideText = nil
            }
        )
        let unitPriceText = Binding<String>(
            get: { item.wrappedValue.unitPriceText },
            set: { newValue in
                let oldPrice = Money.parse(item.wrappedValue.unitPriceText, currency: currency)?.minorUnits
                let newPrice = Money.parse(newValue, currency: currency)?.minorUnits
                item.wrappedValue.unitPriceText = newValue
                guard oldPrice != newPrice else { return }
                item.wrappedValue.lineTotalOverrideText = nil
                billTotalOverrideText = nil
            }
        )
        let lineTotalOverrideText = Binding<String>(
            get: {
                let lineItem = item.wrappedValue
                if let lineTotalOverrideText = lineItem.lineTotalOverrideText {
                    return lineTotalOverrideText
                }
                guard let total = lineItem.total(in: currency) else { return "" }
                return editableAmountText(for: total)
            },
            set: {
                item.wrappedValue.lineTotalOverrideText = $0
                billTotalOverrideText = nil
                guard let total = Money.parse($0, currency: currency), total.minorUnits > 0 else { return }
                var unitPriceMinorUnits = Decimal(total.minorUnits)
                    / Decimal(max(item.wrappedValue.quantity, 1))
                var roundedUnitPriceMinorUnits = Decimal()
                NSDecimalRound(&roundedUnitPriceMinorUnits, &unitPriceMinorUnits, 0, .plain)
                item.wrappedValue.unitPriceText = currency.formattedInput(
                    minorUnits: NSDecimalNumber(decimal: roundedUnitPriceMinorUnits).int64Value
                )
            }
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("Include item", isOn: isSelected)
                    .labelsHidden()
                    .accessibilityLabel("Include \(item.wrappedValue.name.isEmpty ? "item" : item.wrappedValue.name)")
                    .accessibilityValue(item.wrappedValue.isSelected ? "Selected" : "Not selected")

                if editingLineItemNameID == itemID {
                    TextField("Item name", text: item.name)
                        .focused($focusedLineItemNameID, equals: itemID)
                        .submitLabel(.done)
                        .onSubmit(finishLineItemNameEditing)
                } else {
                    Text(item.wrappedValue.name.isEmpty ? "Untitled item" : item.wrappedValue.name)
                        .font(.subheadline.weight(.semibold))
                }

                Spacer(minLength: 4)

                Button {
                    if editingLineItemNameID == itemID {
                        finishLineItemNameEditing()
                    } else {
                        editingLineItemNameID = itemID
                        focusedLineItemNameID = itemID
                    }
                } label: {
                    Image(systemName: editingLineItemNameID == itemID ? "checkmark" : "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(PocketLedgerTheme.accent)
                .accessibilityLabel(editingLineItemNameID == itemID ? "Finish editing item name" : "Edit item name")
            }

            Stepper(value: Binding(
                get: { item.wrappedValue.quantity },
                set: { quantity in
                    item.wrappedValue.quantity = quantity
                    item.wrappedValue.lineTotalOverrideText = nil
                    billTotalOverrideText = nil
                }
            ), in: 1...99) {
                Text("Quantity \(item.wrappedValue.quantity)")
                    .font(.subheadline)
            }

            CurrencyInputField("Unit price", text: unitPriceText, currency: $currency)

            HStack {
                Text("Item total")
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                Spacer()
                TextField("Enter total", text: lineTotalOverrideText)
                    .keyboardType(.decimalPad)
                    .focused($focusedLineTotalID, equals: itemID)
                    .multilineTextAlignment(.trailing)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 80, maxWidth: 150)
                    .accessibilityLabel("Item total")
                    .onChange(of: currency) { _, newCurrency in
                        guard let totalOverride = item.wrappedValue.lineTotalOverrideText,
                              !totalOverride.isEmpty else { return }
                        item.wrappedValue.lineTotalOverrideText = newCurrency.formattedInput(totalOverride)
                    }
                CurrencySelectionMenu(currency: $currency)
            }
        }
        .padding(14)
        .pocketGlassSurface(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var totalCard: some View {
        if !lineItems.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bill total")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                        if isBillTotalFocused {
                            TextField("Enter total", text: billTotalInput)
                                .keyboardType(.decimalPad)
                                .focused($isBillTotalFocused)
                                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                                .frame(minWidth: 120, maxWidth: 200)
                        } else {
                            Button(action: beginBillTotalEditing) {
                                HStack(spacing: 8) {
                                    Text(currentBillTotal?.formatted ?? "Enter a price")
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                }
                                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(currentBillTotal == nil ? PocketLedgerTheme.textTertiary : PocketLedgerTheme.textPrimary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit bill total")
                        }
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(PocketLedgerTheme.positive)
                }

                Button(action: useTotalInTransaction) {
                    Label("Use total in transaction", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(PocketLedgerTheme.accent)
                .disabled(currentBillTotal == nil)

                if !hasMatchingAccount {
                    Text("Add a \(currency.rawValue) account first to use this total.")
                        .font(.footnote)
                        .foregroundStyle(PocketLedgerTheme.warning)

                    Button {
                        isShowingAccountEditor = true
                    } label: {
                        Label("Add \(currency.rawValue) account", systemImage: "plus.circle")
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(16)
            .pocketGlassSurface(cornerRadius: 20, tint: PocketLedgerTheme.accent.opacity(0.08))
        }
    }

    private var selectedItemCount: Int {
        lineItems.filter { $0.isSelected }.count
    }

    private var selectedTotal: Money? {
        let selectedItems = lineItems.filter { $0.isSelected }
        guard !selectedItems.isEmpty else { return nil }

        let totals = selectedItems.compactMap { $0.total(in: currency) }
        guard totals.count == selectedItems.count else { return nil }

        var minorUnits = Int64.zero
        for money in totals {
            let (nextTotal, overflow) = minorUnits.addingReportingOverflow(money.minorUnits)
            guard !overflow else { return nil }
            minorUnits = nextTotal
        }
        return Money(currency: currency, minorUnits: minorUnits)
    }

    private var currentBillTotal: Money? {
        guard let billTotalOverrideText else { return selectedTotal }
        guard let total = Money.parse(billTotalOverrideText, currency: currency), total.minorUnits > 0 else {
            return nil
        }
        return total
    }

    private var billTotalInput: Binding<String> {
        Binding(
            get: {
                self.billTotalOverrideText
                    ?? self.selectedTotal.map { self.editableAmountText(for: $0) }
                    ?? ""
            },
            set: { self.billTotalOverrideText = $0 }
        )
    }

    private func editableAmountText(for money: Money) -> String {
        let units = Decimal(money.minorUnits) / Decimal(money.currency.minorUnitScale)
        return currency.formattedInput(NSDecimalNumber(decimal: units).stringValue)
    }

    private var hasMatchingAccount: Bool {
        store.activeAccounts.contains { $0.currency == currency }
    }

    private var persistedReceiptItems: [LedgerReceiptLineItem] {
        lineItems
            .filter(\.isSelected)
            .map { item in
                LedgerReceiptLineItem(
                    name: item.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    quantity: max(item.quantity, 1),
                    unitPrice: Money.parse(item.unitPriceText, currency: currency),
                    lineTotal: item.total(in: currency)
                )
            }
            .filter { !$0.name.isEmpty }
    }

    private var transactionNote: String {
        let names = lineItems
            .filter { $0.isSelected && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !names.isEmpty else { return "Scanned bill" }

        let prefix = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "Bill: \(prefix), …" : "Bill: \(prefix)"
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        Task { @MainActor in
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    throw BillScannerError.invalidImage
                }
                selectedPhoto = nil
                handleImage(image)
            } catch {
                selectedPhoto = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleImage(_ image: UIImage) {
        guard let resizedImage = resizedBillImage(image),
              let data = resizedImage.jpegData(compressionQuality: 0.88) else {
            errorMessage = BillScannerError.invalidImage.localizedDescription
            return
        }
        previewImage = resizedImage
        attachmentData = data
        attachmentFileName = "receipt-\(UUID().uuidString.lowercased()).jpg"
        attachmentContentType = "image/jpeg"
        Task { @MainActor in
            await scan(data: data)
        }
    }

    private func processPendingCameraImage() {
        guard let image = pendingCameraImage else { return }
        pendingCameraImage = nil
        handleImage(image)
    }

    private func resizedBillImage(_ image: UIImage) -> UIImage? {
        let sourceSize: CGSize
        if let cgImage = image.cgImage {
            let rotated = [.left, .leftMirrored, .right, .rightMirrored].contains(image.imageOrientation)
            sourceSize = rotated
                ? CGSize(width: cgImage.height, height: cgImage.width)
                : CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            sourceSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        }

        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let factor = min(1, 2400 / max(sourceSize.width, sourceSize.height))
        let targetSize = CGSize(
            width: max(1, (sourceSize.width * factor).rounded(.down)),
            height: max(1, (sourceSize.height * factor).rounded(.down))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func importDocument(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            attachmentData = try Data(contentsOf: url)
            attachmentFileName = url.lastPathComponent
            attachmentContentType = "application/pdf"
            previewImage = nil
            recognizedText = ""
            lineItems = []
            billTotalOverrideText = nil
            scanStatusMessage = "PDF ready. Add the transaction details, then review the attachment before saving."
            transactionEditorRequest = BillTransactionEditorRequest(total: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scan(data: Data) async {
        isScanning = true
        scanProgressMessage = "Reading receipt text…"
        errorMessage = nil
        recognizedText = ""
        lineItems = []
        billTotalOverrideText = nil
        scanStatusMessage = nil

        do {
            let visionResult = try await BillOCRService.recognize(from: data)
            recognizedText = visionResult.text
            lineItems = visionResult.items
            currency = visionResult.currency
            scanProgressMessage = "Organizing receipt items…"

            let result = await BillOCRService.analyze(visionResult)
            recognizedText = result.text
            lineItems = result.items
            currency = result.currency
            scanStatusMessage = result.statusMessage
        } catch {
            errorMessage = error.localizedDescription
        }

        isScanning = false
    }

    private func useTotalInTransaction() {
        guard let total = currentBillTotal else { return }
        guard hasMatchingAccount else {
            errorMessage = "Add a \(currency.rawValue) account before adding this bill as a transaction."
            return
        }

        transactionEditorRequest = BillTransactionEditorRequest(total: total)
    }

    private func addManualItem() {
        let item = BillLineItem(name: "")
        lineItems.append(item)
        billTotalOverrideText = nil
        editingLineItemNameID = item.id
        focusedLineItemNameID = item.id
    }

    private func finishLineItemNameEditing() {
        editingLineItemNameID = nil
        focusedLineItemNameID = nil
    }

    private func beginBillTotalEditing() {
        if billTotalOverrideText == nil, let selectedTotal {
            billTotalOverrideText = editableAmountText(for: selectedTotal)
        }
        isBillTotalFocused = true
    }

    private func dismissKeyboard() {
        focusedLineTotalID = nil
        focusedLineItemNameID = nil
        editingLineItemNameID = nil
        isBillTotalFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

@MainActor
private struct BillImageFullScreenView: View {
    let image: UIImage

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZoomableBillImageView(image: image)
                .background(.black)
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

@MainActor
private struct ZoomableBillImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView, imageView.image !== image else { return }
        imageView.image = image
        scrollView.setZoomScale(1, animated: false)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}

@MainActor
private struct BillCameraView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: { dismiss() })
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: () -> Void

        init(onImage: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up:
            self = .up
        case .upMirrored:
            self = .upMirrored
        case .down:
            self = .down
        case .downMirrored:
            self = .downMirrored
        case .left:
            self = .left
        case .leftMirrored:
            self = .leftMirrored
        case .right:
            self = .right
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
