import Foundation
import SwiftUI

@MainActor
struct CategoriesView: View {
    @ObservedObject var store: LedgerStore
    @State private var isPresentingCategory = false
    @State private var editingCategory: LedgerCategory?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                screenSubtitle

                if store.rootCategories.isEmpty {
                    Text("Add a top-level category to organize your transactions.")
                        .font(.subheadline)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pocketCard()
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                        ForEach(store.rootCategories) { parent in
                            NavigationLink {
                                CategorySubcategoriesView(store: store, parent: parent)
                            } label: {
                                categoryRootTile(parent)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") {
                                    presentCategory(parent)
                                }
                                Button("Archive", systemImage: "archivebox") {
                                    _ = store.setCategoryArchived(categoryID: parent.id, isArchived: true)
                                }
                            }
                        }
                    }
                }

                if !archivedCategories.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Archived")
                            .font(.title3.weight(.bold))
                        ForEach(archivedCategories) { category in
                            HStack {
                                Label(category.name, systemImage: category.systemImage)
                                Spacer()
                                Button("Restore") {
                                    _ = store.setCategoryArchived(categoryID: category.id, isArchived: false)
                                }
                                .buttonStyle(.borderless)
                            }
                            .font(.subheadline)
                        }
                    }
                    .pocketCard()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .pocketScreen()
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentCategory(nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add category")
            }
        }
        .sheet(isPresented: $isPresentingCategory, onDismiss: { editingCategory = nil }) {
            CategoryEditor(store: store, category: editingCategory)
        }
    }

    private var screenSubtitle: some View {
        Text("Make every expense easy to understand")
            .font(.subheadline)
            .foregroundStyle(PocketLedgerTheme.textSecondary)
    }

    private func categoryRootTile(_ parent: LedgerCategory) -> some View {
        let children = store.data.categories.filter { $0.parentID == parent.id && !$0.isArchived }

        return VStack(alignment: .leading, spacing: 12) {
            PocketIcon(systemImage: parent.systemImage, tint: PocketLedgerTheme.accent, size: 42)
            Spacer(minLength: 0)
            Text(parent.name)
                .font(.headline)
                .foregroundStyle(PocketLedgerTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(children.isEmpty ? "No subcategories" : "\(children.count) subcategories")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .padding(14)
        .pocketGroupedSurface(cornerRadius: 18)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens subcategories")
    }

    private var archivedCategories: [LedgerCategory] {
        store.data.categories.filter(\.isArchived)
    }

    private func presentCategory(_ category: LedgerCategory?) {
        editingCategory = category
        isPresentingCategory = true
    }
}

@MainActor
private struct CategorySubcategoriesView: View {
    @ObservedObject var store: LedgerStore
    let parent: LedgerCategory
    @State private var isPresentingCategory = false
    @State private var editingCategory: LedgerCategory?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Subcategories in \(parent.name)")
                    .font(.subheadline)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)

                if subcategories.isEmpty {
                    ContentUnavailableView(
                        "No subcategories",
                        systemImage: parent.systemImage,
                        description: Text("Add subcategories to make expenses easier to organize.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .pocketCard()
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                        ForEach(subcategories) { category in
                            CategoryTile(
                                category: category,
                                onEdit: { presentCategory(category) },
                                onArchive: {
                                    _ = store.setCategoryArchived(categoryID: category.id, isArchived: true)
                                }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .pocketScreen()
        .navigationTitle(parent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentCategory(nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add subcategory")
            }
        }
        .sheet(isPresented: $isPresentingCategory, onDismiss: { editingCategory = nil }) {
            CategoryEditor(
                store: store,
                category: editingCategory,
                initialParentID: editingCategory == nil ? parent.id : nil
            )
        }
    }

    private var subcategories: [LedgerCategory] {
        store.data.categories.filter { $0.parentID == parent.id && !$0.isArchived }
    }

    private func presentCategory(_ category: LedgerCategory?) {
        editingCategory = category
        isPresentingCategory = true
    }
}

private struct CategoryTile: View {
    let category: LedgerCategory
    let onEdit: () -> Void
    let onArchive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PocketIcon(systemImage: category.systemImage, tint: PocketLedgerTheme.accent, size: 38)
            Text(category.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PocketLedgerTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .padding(14)
        .pocketGroupedSurface(cornerRadius: 18)
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: onEdit)
            Button("Archive", systemImage: "archivebox", action: onArchive)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(category.name)
        .accessibilityHint("Hold for category actions")
    }
}

@MainActor
private struct CategoryEditor: View {
    private static let categorySymbols = [
        "tag", "fork.knife", "house", "car", "cart", "bag", "heart",
        "cross.case", "gamecontroller", "book", "airplane", "fuelpump",
        "phone", "gift", "lightbulb", "creditcard", "banknote", "repeat",
        "pawprint", "leaf", "wrench.and.screwdriver"
    ]

    @ObservedObject var store: LedgerStore
    let category: LedgerCategory?
    let onSaved: (LedgerCategory) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parentID: UUID?
    @State private var systemImage = "tag"
    @State private var includeInTotals = true
    @State private var errorMessage: String?
    @State private var isConfirmingDiscard = false

    init(
        store: LedgerStore,
        category: LedgerCategory? = nil,
        initialParentID: UUID? = nil,
        onSaved: @escaping (LedgerCategory) -> Void = { _ in }
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.category = category
        self.onSaved = onSaved
        _name = State(initialValue: category?.name ?? "")
        _parentID = State(initialValue: category?.parentID ?? initialParentID)
        _systemImage = State(initialValue: category?.systemImage ?? "tag")
        _includeInTotals = State(initialValue: category?.includeInTotals ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    TextField("Name", text: $name)
                    Picker("Parent category", selection: $parentID) {
                        Text("Top-level category").tag(UUID?.none)
                        ForEach(store.rootCategories.filter { $0.id != self.category?.id }) { parent in
                            Text(parent.name).tag(Optional(parent.id))
                        }
                    }
                    Label("Preview", systemImage: systemImage)
                        .font(.subheadline.weight(.medium))
                    Picker("Icon", selection: $systemImage) {
                        ForEach(availableSystemImages, id: \.self) { symbol in
                            Label(symbol.replacingOccurrences(of: ".", with: " "), systemImage: symbol)
                                .tag(symbol)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("Include in totals and metrics", isOn: $includeInTotals)
                    Text(includeInTotals
                         ? "Expenses in this category count toward totals and metrics."
                         : "Expenses in this category are kept in the ledger but excluded from totals and metrics.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .pocketListSurface()
            .navigationTitle(category == nil ? "New category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasUnsavedChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .errorMessageAlert(title: "Category not saved", message: $errorMessage)
            .confirmationDialog("Discard category changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
    }

    private var availableSystemImages: [String] {
        Self.categorySymbols + (Self.categorySymbols.contains(systemImage) ? [] : [systemImage])
    }

    private var hasUnsavedChanges: Bool {
        name != (category?.name ?? "")
            || parentID != category?.parentID
            || systemImage != (category?.systemImage ?? "tag")
            || includeInTotals != (category?.includeInTotals ?? true)
    }

    private func cancel() {
        if hasUnsavedChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter a category name."
            return
        }

        let trimmedSymbol = systemImage.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = LedgerCategory(
            id: category?.id ?? UUID(),
            name: trimmedName,
            parentID: parentID,
            systemImage: trimmedSymbol.isEmpty ? "tag" : trimmedSymbol,
            includeInTotals: includeInTotals,
            isArchived: category?.isArchived ?? false
        )
        let saved = category == nil ? store.addCategory(value) : store.updateCategory(value)
        guard saved else {
            errorMessage = store.lastActionStatus ?? "The category could not be saved."
            return
        }
        onSaved(value)
        dismiss()
    }
}
