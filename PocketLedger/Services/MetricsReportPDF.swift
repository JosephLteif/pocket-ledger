import Foundation
import SwiftUI
import UIKit

struct MetricsReportCategory {
    let title: String
    let amount: Money
    let count: Int
    let percentage: Int
}

struct MetricsReportSeries {
    let title: String
    let amount: Money
    let percentage: Int
}

struct MetricsReportTransaction {
    let date: Date
    let note: String
    let kind: TransactionKind
    let category: String
    let amount: String
}

struct MetricsReportData {
    let periodTitle: String
    let dateRange: String
    let currency: LedgerCurrency
    let categoryScope: String
    let income: Money
    let expenses: Money
    let entryCount: Int
    let activityCounts: [TransactionKind: Int]
    let categories: [MetricsReportCategory]
    var currencyBreakdown: [MetricsReportSeries] = []
    var transactions: [MetricsReportTransaction] = []
    var totalTransactionCount = 0
    var includesTransactions = false
    let generatedAt: Date
}

enum MetricsReportPDF {
    static func data(for report: MetricsReportData) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        return renderer.pdfData { context in
            let canvas = MetricsReportPDFCanvas(context: context, pageRect: pageRect)
            canvas.beginPage()
            canvas.drawReport(report)
            canvas.finishPage()
        }
    }

    static func writeShareableFile(for report: MetricsReportData) throws -> URL {
        let reportsDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetricsReports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: reportsDirectory,
            withIntermediateDirectories: true
        )

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let fileName = "Pocket-Ledger-Metrics-\(dateFormatter.string(from: .now))-\(UUID().uuidString).pdf"
        let url = reportsDirectory.appendingPathComponent(fileName)
        let pdfData = data(for: report)
        guard !pdfData.isEmpty else {
            throw CocoaError(.fileWriteUnknown)
        }
        try pdfData.write(to: url, options: .atomic)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}

@MainActor
struct MetricsReportShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private final class MetricsReportPDFCanvas {
    private enum Palette {
        static let pageBackground = UIColor.white
        static let primary = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        static let secondary = UIColor(red: 0.36, green: 0.40, blue: 0.47, alpha: 1)
        static let accent = UIColor(red: 0.08, green: 0.36, blue: 0.82, alpha: 1)
        static let income = UIColor(red: 0.10, green: 0.55, blue: 0.28, alpha: 1)
        static let expense = UIColor(red: 0.78, green: 0.18, blue: 0.18, alpha: 1)
        static let scopeFill = UIColor(red: 0.92, green: 0.95, blue: 1.0, alpha: 1)
        static let cardFill = UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
        static let separator = UIColor(red: 0.82, green: 0.84, blue: 0.88, alpha: 1)
    }

    private let context: UIGraphicsPDFRendererContext
    private let pageRect: CGRect
    private let contentRect: CGRect
    private var y: CGFloat = 0
    private var pageNumber = 0

    init(context: UIGraphicsPDFRendererContext, pageRect: CGRect) {
        self.context = context
        self.pageRect = pageRect
        contentRect = pageRect.insetBy(dx: 54, dy: 0)
    }

    func beginPage() {
        context.beginPage()
        pageNumber += 1
        y = 42

        Palette.pageBackground.setFill()
        UIBezierPath(rect: pageRect).fill()

        drawFixed(
            "Pocket Ledger",
            in: CGRect(x: contentRect.minX, y: y, width: contentRect.width, height: 16),
            font: .systemFont(ofSize: 10, weight: .semibold),
            color: Palette.accent
        )
        y += 28
        drawLine()
        y += 20
    }

    func finishPage() {
        drawFixed(
            "Metrics report - page \(pageNumber)",
            in: CGRect(x: contentRect.minX, y: pageRect.maxY - 38, width: contentRect.width, height: 14),
            font: .systemFont(ofSize: 8),
            color: Palette.secondary
        )
    }

    func drawReport(_ report: MetricsReportData) {
        drawText(
            "Metrics report",
            font: .systemFont(ofSize: 26, weight: .bold),
            color: Palette.primary,
            spacingAfter: 4
        )
        drawText(
            "Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))",
            font: .systemFont(ofSize: 10),
            color: Palette.secondary,
            spacingAfter: 20
        )

        drawScope(report)
        drawSectionTitle("Summary")
        drawSummary(report)
        drawSectionTitle("Activity")
        drawText(
            "\(report.activityCounts[.expense] ?? 0) expenses   \(report.activityCounts[.income] ?? 0) income   \(report.activityCounts[.transfer] ?? 0) transfers   \(report.entryCount) total entries",
            font: .systemFont(ofSize: 11),
            color: Palette.primary,
            spacingAfter: 18
        )
        drawCategoryChart(report.categories)
        drawCurrencyChart(report.currencyBreakdown, currency: report.currency)
        drawTransactions(report)

        drawText(
            "Excluded accounts are omitted from this report, matching the Metrics screen.",
            font: .systemFont(ofSize: 9),
            color: Palette.secondary,
            spacingAfter: 0
        )
    }

    private func drawScope(_ report: MetricsReportData) {
        ensureSpace(82)
        let box = CGRect(x: contentRect.minX, y: y, width: contentRect.width, height: 70)
        Palette.scopeFill.setFill()
        UIBezierPath(roundedRect: box, cornerRadius: 12).fill()

        drawFixed("Period", in: CGRect(x: box.minX + 16, y: box.minY + 12, width: 70, height: 14), font: .systemFont(ofSize: 9, weight: .semibold), color: Palette.secondary)
        drawFixed(report.periodTitle, in: CGRect(x: box.minX + 92, y: box.minY + 10, width: box.width - 108, height: 18), font: .systemFont(ofSize: 12, weight: .semibold), color: Palette.primary)
        drawFixed("Range", in: CGRect(x: box.minX + 16, y: box.minY + 39, width: 70, height: 14), font: .systemFont(ofSize: 9, weight: .semibold), color: Palette.secondary)
        let normalizedRange = report.dateRange.replacingOccurrences(of: "–", with: "-")
        drawFixed("\(normalizedRange) | \(report.currency.rawValue) | \(report.categoryScope)", in: CGRect(x: box.minX + 92, y: box.minY + 37, width: box.width - 108, height: 18), font: .systemFont(ofSize: 10), color: Palette.primary)
        y = box.maxY + 20
    }

    private func drawSummary(_ report: MetricsReportData) {
        ensureSpace(96)
        let box = CGRect(x: contentRect.minX, y: y, width: contentRect.width, height: 84)
        Palette.cardFill.setFill()
        UIBezierPath(roundedRect: box, cornerRadius: 12).fill()

        drawSummaryMetric("Income", value: report.income.formatted, color: Palette.income, x: box.minX + 16, width: 150, y: box.minY + 16)
        drawSummaryMetric("Expenses", value: report.expenses.formatted, color: Palette.expense, x: box.minX + 177, width: 150, y: box.minY + 16)
        drawSummaryMetric("Net", value: Money(currency: report.currency, minorUnits: report.income.minorUnits - report.expenses.minorUnits).formatted, color: Palette.accent, x: box.minX + 338, width: 150, y: box.minY + 16)
        y = box.maxY + 18
    }

    private func drawSummaryMetric(_ title: String, value: String, color: UIColor, x: CGFloat, width: CGFloat, y: CGFloat) {
        drawFixed(title.uppercased(), in: CGRect(x: x, y: y, width: width, height: 14), font: .systemFont(ofSize: 9, weight: .semibold), color: Palette.secondary)
        drawFixed(value, in: CGRect(x: x, y: y + 21, width: width, height: 24), font: .systemFont(ofSize: 16, weight: .bold), color: color)
    }

    private func drawCategoryChart(_ categories: [MetricsReportCategory]) {
        drawSectionTitle("Top spending categories")
        guard let maximum = categories.map(\.amount.minorUnits).max(), maximum > 0 else {
            drawText(
                "No included expense activity was recorded in this range.",
                font: .systemFont(ofSize: 11),
                color: Palette.secondary,
                spacingAfter: 12
            )
            return
        }

        for category in categories {
            drawChartRow(
                title: category.title,
                detail: "\(category.count) entr\(category.count == 1 ? "y" : "ies") · \(category.percentage)%",
                amount: category.amount,
                maximum: maximum
            )
        }
    }

    private func drawCurrencyChart(_ series: [MetricsReportSeries], currency: LedgerCurrency) {
        drawSectionTitle("Spending by transaction currency")
        guard let maximum = series.map(\.amount.minorUnits).max(), maximum > 0 else {
            drawText(
                "No included expense activity was recorded in this range.",
                font: .systemFont(ofSize: 11),
                color: Palette.secondary,
                spacingAfter: 12
            )
            return
        }

        drawText(
            "Amounts are converted to \(currency.rawValue) using saved transaction exchange rates.",
            font: .systemFont(ofSize: 9),
            color: Palette.secondary,
            spacingAfter: 8
        )
        for entry in series {
            drawChartRow(
                title: entry.title,
                detail: "\(entry.percentage)% of converted spending",
                amount: entry.amount,
                maximum: maximum
            )
        }
    }

    private func drawChartRow(title: String, detail: String, amount: Money, maximum: Int64) {
        ensureSpace(48)
        let rowY = y
        drawFixed(
            title,
            in: CGRect(x: contentRect.minX, y: rowY, width: 320, height: 15),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: Palette.primary
        )
        drawFixed(
            amount.formatted,
            in: CGRect(x: contentRect.maxX - 160, y: rowY, width: 160, height: 15),
            font: .systemFont(ofSize: 10, weight: .semibold),
            color: Palette.primary,
            alignment: .right
        )
        drawFixed(
            detail,
            in: CGRect(x: contentRect.minX, y: rowY + 15, width: contentRect.width, height: 12),
            font: .systemFont(ofSize: 8),
            color: Palette.secondary
        )

        let track = CGRect(x: contentRect.minX, y: rowY + 31, width: contentRect.width, height: 7)
        UIColor(red: 0.91, green: 0.93, blue: 0.96, alpha: 1).setFill()
        UIBezierPath(roundedRect: track, cornerRadius: 3.5).fill()
        let ratio = min(1, max(0, CGFloat(Double(amount.minorUnits) / Double(maximum))))
        let bar = CGRect(x: track.minX, y: track.minY, width: max(1, track.width * ratio), height: track.height)
        Palette.accent.setFill()
        UIBezierPath(roundedRect: bar, cornerRadius: 3.5).fill()
        y = rowY + 46
    }

    private func drawTransactions(_ report: MetricsReportData) {
        drawSectionTitle("Transactions")
        guard report.includesTransactions else {
            drawText(
                "Transaction details were excluded from this export.",
                font: .systemFont(ofSize: 10),
                color: Palette.secondary,
                spacingAfter: 12
            )
            return
        }
        guard !report.transactions.isEmpty else {
            drawText(
                "No transactions were recorded in this range.",
                font: .systemFont(ofSize: 10),
                color: Palette.secondary,
                spacingAfter: 12
            )
            return
        }

        let shownCount = report.transactions.count
        let shownDescription = shownCount == report.totalTransactionCount
            ? "All \(shownCount) transactions"
            : "Latest \(shownCount) of \(report.totalTransactionCount) transactions"
        drawText(
            "\(shownDescription), newest first.",
            font: .systemFont(ofSize: 9),
            color: Palette.secondary,
            spacingAfter: 8
        )
        for transaction in report.transactions {
            drawTransaction(transaction)
        }
    }

    private func drawTransaction(_ transaction: MetricsReportTransaction) {
        let note = transaction.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = note.isEmpty ? "No description" : note.replacingOccurrences(of: "\n", with: " ")
        let noteAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .semibold)]
        let noteBounds = (description as NSString).boundingRect(
            with: CGSize(width: contentRect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: noteAttributes,
            context: nil
        )
        let noteHeight = max(12, ceil(noteBounds.height))
        ensureSpace(42 + noteHeight)
        let rowY = y
        let dateAndKind = "\(transaction.date.formatted(date: .abbreviated, time: .omitted)) · \(transaction.kind.displayName)"
        drawFixed(
            dateAndKind,
            in: CGRect(x: contentRect.minX, y: rowY, width: 330, height: 13),
            font: .systemFont(ofSize: 8),
            color: Palette.secondary
        )
        drawFixed(
            transaction.amount,
            in: CGRect(x: contentRect.maxX - 170, y: rowY, width: 170, height: 15),
            font: .systemFont(ofSize: 10, weight: .semibold),
            color: Palette.primary,
            alignment: .right
        )
        y = rowY + 15
        drawText(
            description,
            font: .systemFont(ofSize: 10, weight: .semibold),
            color: Palette.primary,
            spacingAfter: 2
        )
        drawFixed(
            transaction.category,
            in: CGRect(x: contentRect.minX, y: y, width: contentRect.width, height: 12),
            font: .systemFont(ofSize: 8),
            color: Palette.secondary
        )
        drawLine(at: y + 15)
        y += 20
    }

    private func drawSectionTitle(_ title: String) {
        ensureSpace(30)
        drawText(title, font: .systemFont(ofSize: 16, weight: .bold), color: Palette.primary, spacingAfter: 10)
    }

    private func drawText(_ text: String, font: UIFont, color: UIColor, spacingAfter: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: contentRect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        let height = max(1, ceil(measured.height))
        ensureSpace(height + spacingAfter)
        drawFixed(
            text,
            in: CGRect(x: contentRect.minX, y: y, width: contentRect.width, height: height),
            font: font,
            color: color
        )
        y += height + spacingAfter
    }

    private func drawFixed(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func ensureSpace(_ requiredHeight: CGFloat) {
        guard y + requiredHeight <= pageRect.maxY - 54 else {
            finishPage()
            beginPage()
            return
        }
    }

    private func drawLine(at yPosition: CGFloat? = nil) {
        let lineY = yPosition ?? y
        Palette.separator.setStroke()
        let path = UIBezierPath()
        path.move(to: CGPoint(x: contentRect.minX, y: lineY))
        path.addLine(to: CGPoint(x: contentRect.maxX, y: lineY))
        path.lineWidth = 0.5
        path.stroke()
    }
}
