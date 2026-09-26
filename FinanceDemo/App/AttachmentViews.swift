import PDFKit
import SwiftUI
import UIKit

private struct LoadedAttachmentPreview: @unchecked Sendable {
    let document: PDFDocument?
    let image: UIImage?
}

@MainActor
struct AttachmentPreviewView: View {
    @ObservedObject var store: LedgerStore
    let attachment: LedgerAttachment
    @State private var document: PDFDocument?
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let document {
                AttachmentPDFView(document: document)
            } else if let image {
                ScrollView([.vertical, .horizontal]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                }
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
        .navigationTitle(attachment.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attachment.id) {
            await loadPreview()
        }
    }

    private func loadPreview() async {
        isLoading = true
        document = nil
        image = nil
        guard let url = store.attachmentURL(for: attachment.id) else {
            isLoading = false
            return
        }
        let isPDF = attachment.contentType == "application/pdf"
        let loaded = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else {
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
