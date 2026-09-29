import SwiftUI
import UniformTypeIdentifiers

private struct PreparedFileImport: @unchecked Sendable {
    let backup: BackupImportCandidate?
    let document: ImportedDocument?
}

private struct PreparedFileImportResult: @unchecked Sendable {
    let result: Result<PreparedFileImport, Error>
}

private struct BackupExportInput: @unchecked Sendable {
    let data: FinanceData
    let attachmentURLs: [(UUID, URL)]
}

private struct PreparedTransferData: @unchecked Sendable {
    let result: Result<Data, Error>
}

@MainActor
struct DataTransferView: View {
    @ObservedObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let isImportOnly: Bool

    @State private var isShowingImporter = false
    @State private var isExportingBackup = false
    @State private var isExportingBackupBundle = false
    @State private var isExportingCSV = false
    @State private var backupDocument = PocketLedgerBackupDocument(data: Data())
    @State private var backupBundleDocument = PocketLedgerBackupBundleDocument(data: Data())
    @State private var csvDocument = LedgerCSVDocument(data: Data())
    @State private var pendingBackup: BackupImportCandidate?
    @State private var pendingDocument: ImportedDocument?
    @State private var isProcessingTransfer = false
    @State private var transferProgress = "Preparing file…"
    @State private var transferTask: Task<Void, Never>?
    @State private var transferToken = UUID()
    @State private var errorMessage: String?
    @State private var isShowingResetPreparation = false
    @State private var isShowingResetWarning = false
    @State private var isShowingFinalResetWarning = false
    @State private var isContinuingToResetAfterBackup = false
    @State private var isShowingResetSuccess = false
    @State private var isShowingRecoveryConfirmation = false
    @State private var isShowingRecoveryDeletionConfirmation = false

    init(store: LedgerStore, isImportOnly: Bool = false) {
        _store = ObservedObject(wrappedValue: store)
        self.isImportOnly = isImportOnly
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                introCard
                if isProcessingTransfer {
                    transferProgressCard
                }
                if isImportOnly {
                    importCard
                } else {
                    backupCard
                    if store.hasRecoverySnapshot {
                        recoveryCard
                    }
                    importCard
                    resetCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .pocketScreen()
        .onDisappear(perform: cancelTransfer)
        .navigationTitle("Import & Backup")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if isImportOnly {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false,
            onCompletion: importFile
        )
        .fileExporter(
            isPresented: $isExportingBackup,
            document: backupDocument,
            contentType: .json,
            defaultFilename: "Pocket-Ledger-backup",
            onCompletion: exportCompleted
        )
        .fileExporter(
            isPresented: $isExportingBackupBundle,
            document: backupBundleDocument,
            contentType: .data,
            defaultFilename: "Pocket-Ledger-backup.pocketledger",
            onCompletion: exportCompleted
        )
        .fileExporter(
            isPresented: $isExportingCSV,
            document: csvDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "Pocket-Ledger-transactions",
            onCompletion: exportCompleted
        )
        .sheet(item: $pendingBackup) { candidate in
            BackupRestoreView(store: store, candidate: candidate)
        }
        .sheet(item: $pendingDocument) { document in
            ImportWizardView(store: store, document: document)
                .presentationDetents([.large])
        }
        .alert("Ledger erased", isPresented: $isShowingResetSuccess) {
            Button("OK") {}
        } message: {
            Text("Your active ledger is empty. Any last-good recovery snapshot is available in Import & Backup. App lock and appearance settings were kept.")
        }
        .confirmationDialog(
            "Restore the last-good ledger?",
            isPresented: $isShowingRecoveryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore last-good snapshot", action: restoreLastGoodSnapshot)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current ledger with the snapshot captured before the last reset or replacement.")
        }
        .confirmationDialog(
            "Delete the recovery snapshot?",
            isPresented: $isShowingRecoveryDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete recovery snapshot", role: .destructive, action: deleteRecoverySnapshot)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local restore copy, including receipt files stored inside it. Your current ledger and exported backups are unchanged.")
        }
        .errorMessageAlert(title: "Data transfer failed", message: $errorMessage)
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Move your ledger safely", systemImage: "arrow.left.arrow.right")
                .font(.title3.weight(.bold))

            Text(isImportOnly
                 ? "Choose a file to bring your existing history into Pocket Ledger. You can review mapped rows before saving them. Files stay on this device."
                 : "Pocket Ledger can restore its own lossless backup or import rows from another app. Files are read on this device and are never uploaded.")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
        }
        .pocketCard()
    }

    private var backupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pocket Ledger backup", systemImage: "externaldrive")
                .font(.title3.weight(.bold))

            Text("Full backups keep accounts, categories, transactions, schedules, and local receipt attachments so they can be restored later.")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)

            Button {
                startBackupExport()
            } label: {
                Label("Export full backup", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.glassProminent)
                .disabled(isProcessingTransfer)

            Button {
                startJSONBackupExport()
            } label: {
                Label("Export JSON compatibility backup", systemImage: "doc.text")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(isProcessingTransfer)

            Button(action: exportCSV) {
                Label("Export transactions as CSV", systemImage: "tablecells")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(isProcessingTransfer)

            Text("The full backup includes local receipt files. JSON remains available for compatibility, while CSV is useful for spreadsheets and other finance apps.")
                .font(.footnote)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
        .pocketCard()
    }

    private var resetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Erase ledger data", systemImage: "trash")
                .font(.title3.weight(.bold))
                .foregroundStyle(PocketLedgerTheme.warning)

            Text("Reset replaces the active ledger with an empty one and normally keeps a local last-good recovery snapshot. Delete any snapshot from this screen if you also want to remove the recovery copy. Your app lock and appearance settings stay unchanged.")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)

            Button("Review reset warnings", role: .destructive) {
                isShowingResetPreparation = true
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.glass)
            .tint(PocketLedgerTheme.warning)
            .disabled(isProcessingTransfer)
            .confirmationDialog(
                "Back up before erasing?",
                isPresented: $isShowingResetPreparation,
                titleVisibility: .visible
            ) {
                Button("Export backup, then continue") {
                    startBackupExport(continueToReset: true)
                }
                Button("Continue without backup", role: .destructive) {
                    isShowingResetWarning = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A full Pocket Ledger backup is the safest way to restore if the on-device recovery snapshot is missing or deleted.")
            }
            .confirmationDialog(
                "Erase the active ledger?",
                isPresented: $isShowingResetWarning,
                titleVisibility: .visible
            ) {
                Button("Show final warning", role: .destructive) {
                    isShowingFinalResetWarning = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every account, category, transaction, scheduled transaction, and exchange rate from the active ledger. Any local recovery snapshot remains available until you delete it here.")
            }
            .confirmationDialog(
                "Final warning: erase the active ledger?",
                isPresented: $isShowingFinalResetWarning,
                titleVisibility: .visible
            ) {
                Button("Erase active ledger", role: .destructive, action: resetLedger)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This is the last confirmation. The active ledger will be replaced with an empty one immediately; any local recovery snapshot will remain.")
            }
        }
        .pocketCard()
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Last-good recovery snapshot", systemImage: "arrow.uturn.backward.circle")
                .font(.title3.weight(.bold))

            Text("Pocket Ledger keeps a local recovery copy before resetting or replacing the ledger. It can contain ledger details and available receipt files. Delete it here to remove the copy from app storage.")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)

            Button {
                isShowingRecoveryConfirmation = true
            } label: {
                Label("Restore last-good snapshot", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(PocketLedgerTheme.accent)
            .disabled(isProcessingTransfer)

            Button(role: .destructive) {
                isShowingRecoveryDeletionConfirmation = true
            } label: {
                Label("Delete recovery snapshot", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(PocketLedgerTheme.warning)
            .disabled(isProcessingTransfer)
        }
        .pocketCard()
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import from another app", systemImage: "arrow.down.doc")
                .font(.title3.weight(.bold))

            Text("Choose a CSV, TSV, JSON, Excel workbook, or SQLite backup such as Money Manager's .mmbak file. The next screen lets you select a table and map its columns.")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)

            Button {
                isShowingImporter = true
            } label: {
                Label("Choose import file", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(isProcessingTransfer)

            Text("Supported spreadsheet input is .xlsx. Legacy binary .xls files should be exported as .xlsx, CSV, or TSV first.")
                .font(.footnote)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
        .pocketCard()
    }

    private var transferProgressCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(transferProgress)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PocketLedgerTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pocketGroupedSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }

    private func importFile(_ result: Result<[URL], Error>) {
        guard !isProcessingTransfer else { return }
        do {
            guard let url = try result.get().first else { return }
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            isProcessingTransfer = true
            transferProgress = "Reading and preparing import…"
            transferToken = UUID()
            let token = transferToken
            transferTask = Task { @MainActor in
                defer {
                    if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                    if transferToken == token {
                        isProcessingTransfer = false
                        transferTask = nil
                    }
                }
                let prepared = await Task.detached(priority: .userInitiated) {
                    do {
                        let bytes = try Data(contentsOf: url)
                        if let bundle = try? LedgerBackupCodec.decodeBundle(bytes) {
                            return PreparedFileImportResult(result: .success(PreparedFileImport(
                                backup: BackupImportCandidate(
                                    fileName: url.lastPathComponent,
                                    backup: PocketLedgerBackup(data: bundle.data, exportedAt: bundle.exportedAt),
                                    attachmentFiles: Dictionary(uniqueKeysWithValues: bundle.attachments.map { ($0.id, $0.data) })
                                ),
                                document: nil
                            )))
                        }
                        if let backup = try? LedgerBackupCodec.decode(bytes) {
                            return PreparedFileImportResult(result: .success(PreparedFileImport(
                                backup: BackupImportCandidate(
                                    fileName: url.lastPathComponent,
                                    backup: backup,
                                    attachmentFiles: [:]
                                ),
                                document: nil
                            )))
                        }
                        return PreparedFileImportResult(result: .success(PreparedFileImport(
                            backup: nil,
                            document: try FinanceImportParser.parse(url: url, data: bytes)
                        )))
                    } catch {
                        return PreparedFileImportResult(result: .failure(error))
                    }
                }.value
                guard !Task.isCancelled else { return }
                do {
                    let payload = try prepared.result.get()
                    pendingBackup = payload.backup
                    pendingDocument = payload.document
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreLastGoodSnapshot() {
        guard store.restoreLastGoodSnapshot() else {
            errorMessage = store.lastActionStatus ?? "The recovery snapshot could not be restored."
            return
        }
    }

    private func exportCompleted(_ result: Result<URL, Error>) {
        let shouldContinueToReset = isContinuingToResetAfterBackup
        isContinuingToResetAfterBackup = false

        switch result {
        case .success:
            if shouldContinueToReset {
                isShowingResetWarning = true
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func startBackupExport(continueToReset: Bool = false) {
        guard !isProcessingTransfer else { return }
        let exportInput = BackupExportInput(
            data: store.data,
            attachmentURLs: store.data.attachments.compactMap { attachment in
                store.attachmentURL(for: attachment.id).map { (attachment.id, $0) }
            }
        )
        isProcessingTransfer = true
        transferProgress = "Building full backup…"
        transferToken = UUID()
        let token = transferToken
        transferTask = Task { @MainActor in
            defer {
                if transferToken == token {
                    isProcessingTransfer = false
                    transferTask = nil
                }
            }
            let prepared = await Task.detached(priority: .userInitiated) {
                do {
                    var files: [UUID: Data] = [:]
                    for (id, url) in exportInput.attachmentURLs {
                        if let file = try? Data(contentsOf: url) { files[id] = file }
                    }
                    return PreparedTransferData(result: .success(
                        try LedgerBackupCodec.encodeBundle(exportInput.data, attachmentData: files)
                    ))
                } catch {
                    return PreparedTransferData(result: .failure(error))
                }
            }.value
            guard !Task.isCancelled, transferToken == token else { return }
            do {
                backupBundleDocument = PocketLedgerBackupBundleDocument(data: try prepared.result.get())
                isContinuingToResetAfterBackup = continueToReset
                isExportingBackupBundle = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startJSONBackupExport() {
        guard !isProcessingTransfer else { return }
        let exportInput = BackupExportInput(data: store.data, attachmentURLs: [])
        isProcessingTransfer = true
        transferProgress = "Preparing JSON backup…"
        transferToken = UUID()
        let token = transferToken
        transferTask = Task { @MainActor in
            defer {
                if transferToken == token {
                    isProcessingTransfer = false
                    transferTask = nil
                }
            }
            let prepared = await Task.detached(priority: .userInitiated) {
                do {
                    return PreparedTransferData(result: .success(try LedgerBackupCodec.encode(exportInput.data)))
                } catch {
                    return PreparedTransferData(result: .failure(error))
                }
            }.value
            guard !Task.isCancelled, transferToken == token else { return }
            do {
                backupDocument = PocketLedgerBackupDocument(data: try prepared.result.get())
                isExportingBackup = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportCSV() {
        guard !isProcessingTransfer else { return }
        let exportInput = BackupExportInput(data: store.data, attachmentURLs: [])
        isProcessingTransfer = true
        transferProgress = "Preparing CSV…"
        transferToken = UUID()
        let token = transferToken
        transferTask = Task { @MainActor in
            defer {
                if transferToken == token {
                    isProcessingTransfer = false
                    transferTask = nil
                }
            }
            let prepared = await Task.detached(priority: .userInitiated) {
                PreparedTransferData(result: .success(LedgerCSVExporter.data(for: exportInput.data)))
            }.value
            guard !Task.isCancelled, transferToken == token else { return }
            do {
                csvDocument = LedgerCSVDocument(data: try prepared.result.get())
                isExportingCSV = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelTransfer() {
        transferToken = UUID()
        transferTask?.cancel()
        transferTask = nil
        isProcessingTransfer = false
    }

    private func resetLedger() {
        guard store.resetLedger() else {
            errorMessage = store.lastActionStatus ?? "The ledger could not be reset."
            return
        }
        isShowingResetSuccess = true
    }

    private func deleteRecoverySnapshot() {
        guard store.deleteRecoverySnapshot() else {
            errorMessage = store.lastActionStatus ?? "The recovery snapshot could not be deleted."
            return
        }
    }
}

private struct BackupImportCandidate: Identifiable {
    let id = UUID()
    let fileName: String
    let backup: PocketLedgerBackup
    let attachmentFiles: [UUID: Data]
}

@MainActor
private struct BackupRestoreView: View {
    @ObservedObject var store: LedgerStore
    let candidate: BackupImportCandidate

    @Environment(\.dismiss) private var dismiss
    @State private var isShowingReplaceConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Backup") {
                    LabeledContent("File", value: candidate.fileName)
                    LabeledContent("Created", value: candidate.backup.exportedAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                    LabeledContent("Accounts", value: "\(candidate.backup.data.accounts.count)")
                    LabeledContent("Categories", value: "\(candidate.backup.data.categories.count)")
                    LabeledContent("Transactions", value: "\(candidate.backup.data.transactions.count)")
                    if !candidate.backup.data.attachments.isEmpty {
                        LabeledContent("Attachments", value: "\(candidate.backup.data.attachments.count)")
                        if candidate.attachmentFiles.count < candidate.backup.data.attachments.count {
                            Text("Some attachment bytes are missing from this compatibility backup. The ledger will restore, but those files will show as unavailable.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("Merge into current ledger", action: merge)

                    Button("Replace current ledger", role: .destructive) {
                        isShowingReplaceConfirmation = true
                    }
                } footer: {
                    Text("Merge keeps existing records and adds records with new IDs. Replace removes the current ledger and restores this backup exactly.")
                }
            }
            .pocketListSurface()
            .navigationTitle("Restore backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                "Replace the current ledger?",
                isPresented: $isShowingReplaceConfirmation,
                titleVisibility: .visible
            ) {
                Button("Replace ledger", role: .destructive, action: replace)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The current accounts, categories, and transactions will be replaced by the backup.")
            }
            .errorMessageAlert(title: "Restore failed", message: $errorMessage)
        }
    }

    private func merge() {
        guard store.mergeData(
            candidate.backup.data,
            attachmentFiles: candidate.attachmentFiles
        ) else {
            errorMessage = store.lastActionStatus ?? "The backup could not be saved."
            return
        }
        dismiss()
    }

    private func replace() {
        guard store.replaceData(
            candidate.backup.data,
            attachmentFiles: candidate.attachmentFiles
        ) else {
            errorMessage = store.lastActionStatus ?? "The backup could not be saved."
            return
        }
        dismiss()
    }
}
