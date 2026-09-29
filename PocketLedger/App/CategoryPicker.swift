import SwiftUI

struct CategorySelectionSheet: View {
    let categories: [LedgerCategory]
    @Binding var selectedCategoryID: UUID?
    let includeUncategorized: Bool
    var showsSelectionIndicator = true

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @AppStorage("pocketLedger.recentCategoryIDs") private var recentCategoryIDsValue = ""

    private var recentCategoryIDs: [UUID] {
        recentCategoryIDsValue.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    private var recentCategories: [LedgerCategory] {
        let categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        return recentCategoryIDs.compactMap { categoriesByID[$0] }
    }

    private var visibleSections: [CategoryPickerSection] {
        let sections = CategoryPickerSection.make(from: categories)
        guard !searchText.isEmpty else { return sections }
        return sections.compactMap { section in
            let entries = section.entries.filter {
                $0.category.name.localizedCaseInsensitiveContains(searchText)
            }
            return entries.isEmpty ? nil : CategoryPickerSection(title: section.title, entries: entries)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if includeUncategorized, searchText.isEmpty {
                    Button {
                        selectedCategoryID = nil
                        dismiss()
                    } label: {
                        selectionRow(title: "Uncategorized", systemImage: "tag", id: nil)
                    }
                    .accessibilityIdentifier("category-option-uncategorized")
                }

                if searchText.isEmpty, !recentCategories.isEmpty {
                    Section("Recent") {
                        ForEach(recentCategories) { category in
                            categoryButton(category, depth: 0)
                        }
                    }
                }

                ForEach(visibleSections) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            categoryButton(entry.category, depth: entry.depth)
                        }
                    }
                }

                if !searchText.isEmpty, visibleSections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Choose category")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search categories")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func categoryButton(_ category: LedgerCategory, depth: Int) -> some View {
        Button {
            selectedCategoryID = category.id
            remember(category.id)
            dismiss()
        } label: {
            selectionRow(title: category.name, systemImage: category.systemImage, id: category.id)
                .padding(.leading, CGFloat(depth) * 18)
        }
        .accessibilityIdentifier("category-option-\(category.id.uuidString)")
    }

    private func selectionRow(title: String, systemImage: String, id: UUID?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(PocketLedgerTheme.accent)
                .frame(width: 22)
            Text(title)
                .foregroundStyle(PocketLedgerTheme.textPrimary)
            Spacer()
            if showsSelectionIndicator, selectedCategoryID == id {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func remember(_ id: UUID) {
        let recent = ([id] + recentCategoryIDs.filter { $0 != id }).prefix(5)
        recentCategoryIDsValue = recent.map(\.uuidString).joined(separator: ",")
    }
}

struct CategoryPickerContent: View {
    let categories: [LedgerCategory]
    let includeUncategorized: Bool

    init(categories: [LedgerCategory], includeUncategorized: Bool = true) {
        self.categories = categories
        self.includeUncategorized = includeUncategorized
    }

    var body: some View {
        if includeUncategorized {
            Text("Uncategorized").tag(nil as UUID?)
        }

        ForEach(sections) { section in
            Section {
                ForEach(section.entries) { entry in
                    Text(entry.label)
                        .tag(Optional(entry.category.id))
                }
            } header: {
                Text(section.title)
            }
        }
    }

    private var sections: [CategoryPickerSection] {
        CategoryPickerSection.make(from: categories)
    }
}

struct CategoryPickerSection: Identifiable {
    struct Entry: Identifiable {
        let category: LedgerCategory
        let depth: Int

        var id: UUID { category.id }

        var label: String {
            guard depth > 0 else { return category.name }
            return "\(String(repeating: "  ", count: depth))\(category.name)"
        }
    }

    let title: String
    let entries: [Entry]

    var id: UUID { entries[0].category.id }

    static func make(from categories: [LedgerCategory]) -> [CategoryPickerSection] {
        var uniqueCategories: [LedgerCategory] = []
        var seenIDs: Set<UUID> = []
        for category in categories where seenIDs.insert(category.id).inserted {
            uniqueCategories.append(category)
        }

        let categoriesByID = Dictionary(uniqueKeysWithValues: uniqueCategories.map { ($0.id, $0) })
        let childrenByParentID = Dictionary(grouping: uniqueCategories) { $0.parentID }
        let roots = uniqueCategories.filter { category in
            guard let parentID = category.parentID else { return true }
            return categoriesByID[parentID] == nil
        }

        return sorted(roots).map { root in
            var entries: [Entry] = []
            var visited: Set<UUID> = []

            append(
                root,
                depth: 0,
                childrenByParentID: childrenByParentID,
                entries: &entries,
                visited: &visited
            )

            return CategoryPickerSection(title: root.name, entries: entries)
        }
    }

    private static func append(
        _ category: LedgerCategory,
        depth: Int,
        childrenByParentID: [UUID?: [LedgerCategory]],
        entries: inout [Entry],
        visited: inout Set<UUID>
    ) {
        guard visited.insert(category.id).inserted else { return }
        entries.append(Entry(category: category, depth: depth))

        for child in sorted(childrenByParentID[category.id] ?? []) {
            append(
                child,
                depth: depth + 1,
                childrenByParentID: childrenByParentID,
                entries: &entries,
                visited: &visited
            )
        }
    }

    private static func sorted(_ categories: [LedgerCategory]) -> [LedgerCategory] {
        categories.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString
                : comparison == .orderedAscending
        }
    }
}
