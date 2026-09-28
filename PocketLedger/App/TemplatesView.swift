import SwiftUI

@MainActor
struct TemplatesView: View {
    @ObservedObject var store: LedgerStore
    @State private var templateToUse: LedgerTemplate?
    @State private var templateToEdit: LedgerTemplate?
    @State private var templateToDelete: LedgerTemplate?
    @State private var isCreatingTemplate = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reuse repeat expenses, income, and transfers")
                            .font(.subheadline)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    }

                    if store.data.templates.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "rectangle.stack")
                                .font(.title2)
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                            Text("No templates yet")
                                .font(.headline)
                            Text("Save a transaction as a template from the transaction history context menu.")
                                .font(.subheadline)
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                                .multilineTextAlignment(.center)
                            Button("Create template", systemImage: "plus") {
                                isCreatingTemplate = true
                            }
                            .buttonStyle(.glassProminent)
                            .tint(PocketLedgerTheme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                        .padding(.horizontal, 20)
                        .pocketGroupedSurface(cornerRadius: 20)
                    } else {
                        ForEach(store.data.templates) { template in
                            templateCard(template)
                        }
                    }
            }
            .padding(16)
        }
        .pocketScreen()
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isCreatingTemplate = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create template")
            }
        }
        .sheet(item: $templateToUse) { template in
            TransactionEditor(store: store, template: template)
        }
        .sheet(item: $templateToEdit) { template in
            TransactionEditor(store: store, editingTemplate: template)
        }
        .sheet(isPresented: $isCreatingTemplate) {
            TransactionEditor(store: store, createTemplate: true)
        }
        .confirmationDialog("Delete template?", isPresented: Binding(
            get: { templateToDelete != nil },
            set: { if !$0 { templateToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let templateToDelete {
                    _ = store.deleteTemplate(id: templateToDelete.id)
                }
                self.templateToDelete = nil
            }
            Button("Cancel", role: .cancel) { templateToDelete = nil }
        }
    }

    private func templateCard(_ template: LedgerTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.headline)
                    Text(store.transactionSummary(template.transactionTemplate))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(template.kind.displayName + (template.kind == .expense ? " · " + store.categoryPath(for: template.categoryID) : ""))
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(PocketLedgerTheme.accent)
            }

            HStack(spacing: 8) {
                Button("Edit", systemImage: "pencil") { templateToEdit = template }
                    .buttonStyle(.bordered)
                Button("Use", systemImage: "arrow.turn.down.right") { templateToUse = template }
                    .buttonStyle(.glassProminent)
                    .tint(PocketLedgerTheme.accent)
                    .frame(maxWidth: .infinity)
                Button(role: .destructive) { templateToDelete = template } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Delete template")
            }
        }
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 20)
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
    }
}

@MainActor
struct TemplateNameEditor: View {
    @ObservedObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let transaction: LedgerTransaction
    @State private var name: String

    init(store: LedgerStore, transaction: LedgerTransaction) {
        _store = ObservedObject(wrappedValue: store)
        self.transaction = transaction
        _name = State(initialValue: transaction.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    TextField("Template name", text: $name)
                    Text(store.transactionSummary(transaction))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .pocketListSurface()
            .navigationTitle("Save template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        if store.addTemplate(LedgerTemplate(name: trimmedName, transaction: transaction)) {
            dismiss()
        }
    }
}
