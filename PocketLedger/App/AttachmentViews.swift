import PDFKit
import SwiftUI
import UIKit

private struct LoadedAttachmentPreview: @unchecked Sendable {
    let document: PDFDocument?
    let image: UIImage?
}

@MainActor
struct AttachmentPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let fileName: String
    let contentType: String
    var url: URL? = nil
    var data: Data? = nil
    @State private var document: PDFDocument?
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let document {
                AttachmentPDFView(document: document)
            } else if let image {
                ZoomableBillImageView(image: image)
            } else if isLoading {
                ProgressView("Loading receipt…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Attachment unavailable",
                    systemImage: "doc.questionmark",
                    description: Text("The local file is missing or could not be opened.")
                )
            }
        }
        .pocketScreen()
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            await loadPreview()
        }
    }

    private func loadPreview() async {
        isLoading = true
        document = nil
        image = nil
        let isPDF = contentType == "application/pdf"
        let loaded = await Task.detached(priority: .userInitiated) { [data, url] in
            guard let data = data ?? url.flatMap({ try? Data(contentsOf: $0) }) else {
                return LoadedAttachmentPreview(document: nil, image: nil)
            }
            return LoadedAttachmentPreview(
                document: isPDF ? PDFDocument(data: data) : nil,
                image: isPDF ? nil : UIImage(data: data)
            )
        }.value
        guard !Task.isCancelled else { return }
        document = loaded.document
        image = loaded.image
        isLoading = false
    }
}

private struct AttachmentPDFView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.document = document
    }
}
