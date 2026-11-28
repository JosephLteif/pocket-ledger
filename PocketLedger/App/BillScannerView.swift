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

    func total(in currency: LedgerCurrency, locale: Locale = .current) -> Money? {
        let multiplier = Int64(max(quantity, 1))

        if let lineTotalOverrideText {
            guard let lineTotal = Money.parse(lineTotalOverrideText, currency: currency, locale: locale),
                  lineTotal.minorUnits > 0 else {
                return nil
            }
            return lineTotal
        }

        if quantity == initialQuantity,
           unitPriceText == initialUnitPriceText,
           let lineTotal = Money.parse(lineTotalText, currency: currency, locale: locale),
           lineTotal.minorUnits > 0 {
            return lineTotal
        }

        if let unitPrice = Money.parse(unitPriceText, currency: currency, locale: locale),
           unitPrice.minorUnits > 0 {
            let (minorUnits, overflow) = unitPrice.minorUnits.multipliedReportingOverflow(by: multiplier)
            guard !overflow else { return nil }
            return Money(currency: currency, minorUnits: minorUnits)
        }

        guard let lineTotal = Money.parse(lineTotalText, currency: currency, locale: locale),
              lineTotal.minorUnits > 0 else {
            return nil
        }
        return lineTotal
    }
}

private struct BillScanResult: Sendable {
    let payment: BillScannerParser.Payment
    var items: [LedgerCurrency: [BillLineItem]]
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
    static func recognize(from data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
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

            let fragments = (request.results ?? []).compactMap { observation -> (text: String, bounds: CGRect)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return (text, observation.boundingBox)
            }
            return BillScannerParser.orderedText(fragments)
        }.value
    }

    static func analyze(_ text: String) async -> BillScanResult {
        let payment = BillScannerParser.payment(in: text)
        var suggestions: [BillScannerParser.ItemSuggestion] = []
        if BillScannerParser.canRecoverWrappedItems(in: text) {
            let analysis = await FoundationModelService.analyzeReceipt(text: text)
            suggestions = analysis.items.compactMap { item in
                guard let lineTotal = item.lineTotalText else { return nil }
                return BillScannerParser.ItemSuggestion(name: item.name, lineTotal: lineTotal)
            }
        }

        let items = LedgerCurrency.allCases.map {
            ($0, BillScannerParser.items(in: text, currency: $0, suggestions: suggestions))
        }
        return BillScanResult(payment: payment, items: Dictionary(uniqueKeysWithValues: items))
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
    @State private var scanResult: BillScanResult?
    @State private var requiresCurrencySelection = false
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
                    Text("Scan a photo for detected items, or attach a PDF and enter the total yourself.")
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

                    if !isScanning, previewImage != nil {
                        totalCard
                        if !requiresCurrencySelection {
                            if lineItems.isEmpty {
                                Label("No priced items detected", systemImage: "exclamationmark.magnifyingglass")
                                    .font(.subheadline)
                                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                            } else {
                                reviewItems
                            }
                            Button(action: addManualItem) {
                                Label("Add item manually", systemImage: "plus.circle")
                            }
                            .foregroundStyle(PocketLedgerTheme.accent)
                        }
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
                    .disabled(isScanning)
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
                    Label("Attach PDF manually", systemImage: "doc.richtext")
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

            ForEach(lineItems) { item in
                lineItemEditor(lineItemBinding(for: item))
            }
        }
    }

    private func lineItemEditor(_ item: Binding<BillLineItem>) -> some View {
        let itemID = item.wrappedValue.id
        let isSelected = Binding<Bool>(
            get: { item.wrappedValue.isSelected },
            set: { item.wrappedValue.isSelected = $0 }
        )
        let unitPriceText = Binding<String>(
            get: { item.wrappedValue.unitPriceText },
            set: { newValue in
                let oldPrice = Money.parse(item.wrappedValue.unitPriceText, currency: currency)?.minorUnits
                let newPrice = Money.parse(newValue, currency: currency)?.minorUnits
                item.wrappedValue.unitPriceText = newValue
                guard oldPrice != newPrice else { return }
                item.wrappedValue.lineTotalOverrideText = nil
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
                }
            ), in: 1...99) {
                Text("Quantity \(item.wrappedValue.quantity)")
                    .font(.subheadline)
            }

            CurrencyInputField("Unit price", text: unitPriceText, currency: currency)

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
            }
        }
        .padding(14)
        .pocketGlassSurface(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
    }

    private func lineItemBinding(for item: BillLineItem) -> Binding<BillLineItem> {
        let itemID = item.id
        return Binding(
            get: { lineItems.first { $0.id == itemID } ?? item },
            set: { updatedItem in
                guard let index = lineItems.firstIndex(where: { $0.id == itemID }) else { return }
                lineItems[index] = updatedItem
            }
        )
    }

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bill total")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                    if requiresCurrencySelection {
                        Menu("Choose payment currency") {
                            ForEach(scanResult?.payment.currencies ?? []) { option in
                                Button {
                                    selectCurrency(option)
                                } label: {
                                    Text(scannedTotal(in: option)?.formatted ?? option.rawValue)
                                }
                            }
                        }
                    } else if isBillTotalFocused {
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
                if !requiresCurrencySelection {
                    CurrencySelectionMenu(currency: Binding(get: { currency }, set: selectCurrency))
                }
            }

            if !requiresCurrencySelection {
                if let selectedTotal, let currentBillTotal, selectedTotal != currentBillTotal {
                    Text("Selected items add up to \(selectedTotal.formatted).")
                        .font(.footnote)
                        .foregroundStyle(PocketLedgerTheme.warning)
                    Button("Use selected item total") {
                        billTotalOverrideText = editableAmountText(for: selectedTotal)
                    }
                    .font(.footnote)
                } else if currentBillTotal == nil, scanResult?.payment.hasPrintedTotal == true {
                    Text("Check the receipt and enter the amount paid in \(currency.rawValue).")
                        .font(.footnote)
                        .foregroundStyle(PocketLedgerTheme.warning)
                }
            }

            Button(action: useTotalInTransaction) {
                Label("Use total in transaction", systemImage: "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(PocketLedgerTheme.accent)
            .disabled(currentBillTotal == nil || !hasMatchingAccount)

            if !requiresCurrencySelection, !hasMatchingAccount {
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
        guard !requiresCurrencySelection else { return nil }
        guard let billTotalOverrideText else {
            if scanResult?.payment.hasPrintedTotal == true { return scannedTotal(in: currency) }
            return selectedTotal
        }
        guard let total = Money.parse(billTotalOverrideText, currency: currency), total.minorUnits > 0 else {
            return nil
        }
        return total
    }

    private var billTotalInput: Binding<String> {
        Binding(
            get: {
                self.billTotalOverrideText ?? self.currentBillTotal.map { self.editableAmountText(for: $0) } ?? ""
            },
            set: { self.billTotalOverrideText = $0 }
        )
    }

    private func editableAmountText(for money: Money) -> String {
        money.currency.formattedInput(minorUnits: money.minorUnits)
    }

    private func scannedTotal(in currency: LedgerCurrency) -> Money? {
        let totals = scanResult?.payment.totals.filter { $0.currency == currency } ?? []
        return totals.count == 1 ? totals.first : nil
    }

    private func selectCurrency(_ newCurrency: LedgerCurrency) {
        requiresCurrencySelection = false
        guard newCurrency != currency else { return }
        dismissKeyboard()
        if scanResult != nil {
            scanResult?.items[currency] = lineItems
            lineItems = scanResult?.items[newCurrency] ?? []
        }
        currency = newCurrency
        billTotalOverrideText = nil
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
        isScanning = true
        scanProgressMessage = "Reading receipt photo…"
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
                isScanning = false
            }
        }
    }

    private func handleImage(_ image: UIImage) {
        guard let resizedImage = resizedBillImage(image),
              let data = resizedImage.jpegData(compressionQuality: 0.88) else {
            errorMessage = BillScannerError.invalidImage.localizedDescription
            isScanning = false
            return
        }
        isScanning = true
        scanProgressMessage = "Reading receipt text…"
        Task { @MainActor in
            await scan(image: resizedImage, data: data)
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
            scanResult = nil
            requiresCurrencySelection = false
            transactionEditorRequest = BillTransactionEditorRequest(total: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scan(image: UIImage, data: Data) async {
        defer { isScanning = false }
        errorMessage = nil

        do {
            let text = try await BillOCRService.recognize(from: data)
            scanProgressMessage = "Organizing receipt items…"

            let result = await BillOCRService.analyze(text)
            setReceiptImage(image, data: data)
            recognizedText = text
            billTotalOverrideText = nil
            scanResult = result
            currency = result.payment.currency
            lineItems = result.items[currency] ?? []
            requiresCurrencySelection = result.payment.currencies.count > 1
        } catch {
            if attachmentData == nil {
                setReceiptImage(image, data: data)
            }
            errorMessage = error.localizedDescription
        }
    }

    private func setReceiptImage(_ image: UIImage, data: Data) {
        previewImage = image
        attachmentData = data
        attachmentFileName = "receipt-\(UUID().uuidString.lowercased()).jpg"
        attachmentContentType = "image/jpeg"
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
        editingLineItemNameID = item.id
        focusedLineItemNameID = item.id
    }

    private func finishLineItemNameEditing() {
        editingLineItemNameID = nil
        focusedLineItemNameID = nil
    }

    private func beginBillTotalEditing() {
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
struct ZoomableBillImageView: UIViewRepresentable {
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
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Receipt image"
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
