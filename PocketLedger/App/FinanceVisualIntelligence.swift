import Combine
import Foundation
import AppIntents
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import Vision
#if compiler(>=6.4) && canImport(VisualIntelligence)
import VisualIntelligence
#endif

@MainActor
final class VisualBillScanRouter: ObservableObject {
    static let shared = VisualBillScanRouter()

    struct Request: Equatable {
        let id: UUID
        let imageData: Data
    }

    @Published private(set) var pendingBillScan: Request?

    func open(imageData: Data) {
        pendingBillScan = Request(id: UUID(), imageData: imageData)
    }

    func consumePendingBillScan() -> Request? {
        defer { pendingBillScan = nil }
        return pendingBillScan
    }
}

#if !compiler(>=6.4) || canImport(VisualIntelligence)
#if compiler(>=6.4)
@available(iOS 27.0, *)
typealias FinanceVisualContentDescriptor = VisualIntelligence.SemanticContentDescriptor
#else
@available(iOS 26.0, *)
typealias FinanceVisualContentDescriptor = SemanticContentDescriptor
#endif

#if compiler(>=6.4)
@available(iOS 27.0, *)
#else
@available(iOS 26.0, *)
#endif
struct VisualBillScanEntity: AppEntity, Hashable, Sendable {
    let id: String
    let imageData: Data

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Scan this bill",
            subtitle: "Review detected items in Pocket Ledger",
            image: .init(data: imageData)
        )
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bill"
    static let defaultQuery = VisualBillScanEntityQuery()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
#else
@available(iOS 26.0, *)
#endif
struct VisualBillScanEntityQuery: EntityQuery {
    func entities(for identifiers: [VisualBillScanEntity.ID]) async throws -> [VisualBillScanEntity] {
        await VisualBillScanEntityCache.shared.entities(for: identifiers)
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
#else
@available(iOS 26.0, *)
#endif
struct VisualBillIntentValueQuery: IntentValueQuery {
    func values(for input: FinanceVisualContentDescriptor) async throws -> [VisualBillScanEntity] {
        guard let pixelBuffer = input.pixelBuffer else { return [] }

        var capturedImage: CGImage?
        _ = pixelBuffer.withUnsafeBuffer {
            VTCreateCGImageFromCVPixelBuffer($0, options: nil, imageOut: &capturedImage)
        }
        guard let capturedImage,
              let imageData = Self.jpegData(from: capturedImage),
              await Self.isBill(imageData, labels: input.labels) else {
            return []
        }

        let entity = VisualBillScanEntity(id: UUID().uuidString, imageData: imageData)
        await VisualBillScanEntityCache.shared.cache(entity)
        return [entity]
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: 0.84,
            kCGImageDestinationImageMaxPixelSize: 2200
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func isBill(_ imageData: Data, labels: [String]) async -> Bool {
        let billLabels: Set<String> = ["receipt", "invoice", "bill"]
        if labels.contains(where: { billLabels.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }) {
            return true
        }

        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return false
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            if let languages = try? request.supportedRecognitionLanguages() {
                let supported = languages.filter { language in
                    ["en", "ar", "fr"].contains { language == $0 || language.hasPrefix("\($0)-") }
                }
                if !supported.isEmpty {
                    request.recognitionLanguages = supported
                }
            }

            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                return false
            }

            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .lowercased()
            let hasBillCue = [
                "receipt", "invoice", "subtotal", "total", "amount due", "tax", "vat",
                "فاتورة", "المجموع", "المبلغ", "ضريبة"
            ].contains { text.contains($0) }
            let hasAmount = text.range(
                of: #"(?:usd|eur|lbp|ll|[$€])\s*[\d,.]+|\b\d+[.,]\d{2}\b"#,
                options: .regularExpression
            ) != nil
            return hasBillCue && hasAmount
        }.value
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
#else
@available(iOS 26.0, *)
#endif
struct OpenVisualBillScanIntent: OpenIntent {
    static let title: LocalizedStringResource = "Scan Bill in Pocket Ledger"

    @Parameter(title: "Bill")
    var target: VisualBillScanEntity

    func perform() async throws -> some IntentResult {
        await VisualBillScanEntityCache.shared.remove(target.id)
        await VisualBillScanRouter.shared.open(imageData: target.imageData)
        return .result()
    }
}

#if compiler(>=6.4)
@MainActor
@available(iOS 27.0, *)
#else
@MainActor
@available(iOS 26.0, *)
#endif
private final class VisualBillScanEntityCache {
    static let shared = VisualBillScanEntityCache()

    private var entitiesByID: [String: VisualBillScanEntity] = [:]
    private var cachedEntityIDs: [String] = []

    func cache(_ entity: VisualBillScanEntity) {
        entitiesByID[entity.id] = entity
        cachedEntityIDs.removeAll { $0 == entity.id }
        cachedEntityIDs.append(entity.id)
        if cachedEntityIDs.count > 3 {
            entitiesByID[cachedEntityIDs.removeFirst()] = nil
        }
    }

    func entities(for identifiers: [String]) -> [VisualBillScanEntity] {
        identifiers.compactMap { entitiesByID[$0] }
    }

    func remove(_ identifier: String) {
        entitiesByID[identifier] = nil
        cachedEntityIDs.removeAll { $0 == identifier }
    }
}
#endif
