import SwiftUI

@MainActor
struct TemplatesView: View {
    @ObservedObject var store: LedgerStore
    @EnvironmentObject private var security: AppSecurityService
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false
    @State private var templateToUse: LedgerTemplate?
    @State private var templateToEdit: LedgerTemplate?
    @State private var templateToDelete: LedgerTemplate?
    @State private var isCreatingTemplate = false

    var body: some View {
        List {
            Text("Reuse repeat expenses, income, and transfers")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

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
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(Array(store.data.templates.enumerated()), id: \.element.id) { entry in
                    templateRow(entry.element)
                        .pocketGroupedListRow(index: entry.offset, count: store.data.templates.count)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .pocketScreen()
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            BalanceVisibilityToolbarItem(security: security)
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

    private func templateRow(_ template: LedgerTemplate) -> some View {
        let amount = store.transactionSummary(template.transactionTemplate)
        let subtitle = template.kind.displayName
            + (template.kind == .expense ? " · " + store.categoryPath(for: template.categoryID) : "")
        let tint: Color = switch template.kind {
        case .expense: PocketLedgerTheme.warning
        case .income: PocketLedgerTheme.income
        case .transfer: PocketLedgerTheme.positive
        }
        let icon = template.categoryID != nil
            ? store.ledgerIndex.categorySystemImage(for: template.categoryID)
            : template.kind == .expense ? "arrow.up.right"
                : template.kind == .income ? "arrow.down.left" : "arrow.left.arrow.right"

        return Button {
            templateToUse = template
        } label: {
            HStack(spacing: 12) {
                CategorySymbol(systemImage: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PocketLedgerTheme.textPrimary)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                ProtectedAmountText(value: amount, isRevealed: areBalancesRevealed)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            .padding(.vertical, 11)
            .frame(minHeight: 72)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(template.name), \(subtitle), \(areBalancesRevealed ? amount : "Hidden amount")")
        .accessibilityHint("Creates a transaction from this template")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            PocketSwipeActionButton(title: "Delete", systemImage: "trash", tint: .red, role: .destructive) {
                templateToDelete = template
            }
            PocketSwipeActionButton(title: "Edit", systemImage: "pencil", tint: PocketLedgerTheme.warning) {
                templateToEdit = template
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            PocketSwipeActionButton(title: "Use", systemImage: "arrow.turn.down.right", tint: PocketLedgerTheme.accent) {
                templateToUse = template
            }
        }
        .contextMenu {
            Button("Use", systemImage: "arrow.turn.down.right") { templateToUse = template }
            Button("Edit", systemImage: "pencil") { templateToEdit = template }
            Button("Delete", systemImage: "trash", role: .destructive) { templateToDelete = template }
        }
    }
}

@MainActor
struct TemplateNameEditor: View {
    @ObservedObject var store: LedgerStore
    @EnvironmentObject private var security: AppSecurityService
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false
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
                    ProtectedAmountText(value: store.transactionSummary(transaction), isRevealed: areBalancesRevealed)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .pocketListSurface()
            .navigationTitle("Save template")
            .toolbar {
                BalanceVisibilityToolbarItem(security: security)
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
