import Foundation
import SwiftUI

@MainActor
struct CategoriesView: View {
    @ObservedObject var store: LedgerStore
    @State private var isPresentingCategory = false
    @State private var editingCategory: LedgerCategory?

    var body: some View {
        List {
            Section {
                if store.rootCategories.isEmpty {
                    ContentUnavailableView("No categories", systemImage: "tag", description: Text("Add a category to organize transactions."))
                } else {
                    ForEach(store.rootCategories) { parent in
                        NavigationLink {
                            CategorySubcategoriesView(store: store, parent: parent)
                        } label: {
                            categoryRootTile(parent)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Edit", systemImage: "pencil") { presentCategory(parent) }
                            Button("Archive", systemImage: "archivebox") {
                                _ = store.setCategoryArchived(categoryID: parent.id, isArchived: true)
                            }
                        }
                    }
                }
            }
            if !archivedCategories.isEmpty {
                Section("Archived") {
                    ForEach(archivedCategories) { category in
                        HStack {
                            Label(category.name, systemImage: category.systemImage)
                            Spacer()
                            Button("Restore") {
                                _ = store.setCategoryArchived(categoryID: category.id, isArchived: false)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .pocketListSurface()
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

    private func categoryRootTile(_ parent: LedgerCategory) -> some View {
        let children = store.data.categories.filter { $0.parentID == parent.id && !$0.isArchived }
        return HStack(spacing: 12) {
            Image(systemName: parent.systemImage)
                .foregroundStyle(PocketLedgerTheme.accent)
                .frame(width: 28)
            Text(parent.name)
            Spacer()
            if !children.isEmpty {
                Text("\(children.count)")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
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
        List {
            if subcategories.isEmpty {
                ContentUnavailableView("No subcategories", systemImage: parent.systemImage, description: Text("Add a subcategory to organize expenses."))
            } else {
                ForEach(subcategories) { category in
                    Button {
                        presentCategory(category)
                    } label: {
                        Label(category.name, systemImage: category.systemImage)
                            .foregroundStyle(PocketLedgerTheme.textPrimary)
                            .frame(minHeight: 44)
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Archive", systemImage: "archivebox") {
                            _ = store.setCategoryArchived(categoryID: category.id, isArchived: true)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .pocketListSurface()
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
                    LabeledContent("Name") { TextField("Name", text: $name).multilineTextAlignment(.trailing) }
                    Picker("Parent category", selection: $parentID) {
                        Text("Top-level category").tag(UUID?.none)
                        ForEach(store.rootCategories.filter { $0.id != self.category?.id }) { parent in
                            Text(parent.name).tag(Optional(parent.id))
                        }
                    }
                    Picker("Icon", selection: $systemImage) {
                        ForEach(availableSystemImages, id: \.self) { symbol in
                            Label(symbol.replacingOccurrences(of: ".", with: " "), systemImage: symbol)
                                .tag(symbol)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("Include in totals and metrics", isOn: $includeInTotals)
                    DisclosureGroup("About totals") {
                    Text(includeInTotals
                         ? "Expenses in this category count toward totals and metrics."
                         : "Expenses in this category are kept in the ledger but excluded from totals and metrics.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
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
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Category not saved", isPresented: errorPresented) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("Discard category changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
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
