import SwiftUI

struct CategorySelectionSheet: View {
    let categories: [LedgerCategory]
    @Binding var selectedCategoryID: UUID?
    let includeUncategorized: Bool
    let allowsParentSelection: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var navigationPath: [UUID] = []
    @AppStorage("pocketLedger.recentCategoryIDs") private var recentCategoryIDsValue = ""

    private var recentCategoryIDs: [UUID] {
        recentCategoryIDsValue.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    private var categorySections: [CategoryPickerSection] {
        CategoryPickerSection.make(from: categories)
    }

    private var categoryEntries: [CategoryPickerSection.Entry] {
        categorySections.flatMap(\.entries)
    }

    private var categoriesByID: [UUID: LedgerCategory] {
        Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var recentCategories: [LedgerCategory] {
        var seenIDs: Set<UUID> = []
        return recentCategoryIDs.compactMap { id in
            guard seenIDs.insert(id).inserted else { return nil }
            return categoriesByID[id]
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [SearchResult] {
        let query = normalizedSearchText
        guard !query.isEmpty else { return [] }

        let categoryLookup = categoriesByID
        return categoryEntries.compactMap { entry in
            let category = entry.category
            guard category.displayName.localizedCaseInsensitiveContains(query) else { return nil }
            return SearchResult(
                category: category,
                breadcrumb: CategoryPickerSection.breadcrumb(for: category, categoriesByID: categoryLookup)
            )
        }
    }

    private var hasSearchQuery: Bool {
        !normalizedSearchText.isEmpty
    }

    private struct SearchResult: Identifiable {
        let category: LedgerCategory
        let breadcrumb: String?

        var id: UUID { category.id }
    }

    var body: some View {
        let sections = categorySections
        let entries = sections.flatMap(\.entries)
        let expandableCategoryIDs = Set(entries.compactMap { $0.category.parentID })
        let recent = recentCategories
        let recentIDs = Set(recent.map(\.id))
        let results = searchResults

        NavigationStack(path: $navigationPath) {
            List {
                if hasSearchQuery {
                    if results.isEmpty {
                        ContentUnavailableView.search(text: normalizedSearchText)
                    } else {
                        Section("Search results") {
                            ForEach(results) { result in
                                categoryRow(
                                    result.category,
                                    breadcrumb: result.breadcrumb,
                                    canBrowse: expandableCategoryIDs.contains(result.category.id)
                                )
                            }
                        }
                    }
                } else {
                    if includeUncategorized {
                        Button {
                            selectedCategoryID = nil
                            dismiss()
                        } label: {
                            selectionRow(title: "Uncategorized", systemImage: "tag", id: nil)
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .accessibilityIdentifier("category-option-uncategorized")
                    }

                    if !recent.isEmpty {
                        Section("Recent") {
                            ForEach(recent) { category in
                                categoryRow(
                                    category,
                                    canBrowse: expandableCategoryIDs.contains(category.id)
                                )
                            }
                        }
                    }

                    let browseCategories = sections
                        .compactMap { $0.entries.first?.category }
                        .filter { !recentIDs.contains($0.id) }
                    if !browseCategories.isEmpty {
                        Section("Browse") {
                            ForEach(browseCategories) { category in
                                categoryRow(
                                    category,
                                    canBrowse: expandableCategoryIDs.contains(category.id)
                                )
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Choose category")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search categories")
            .navigationDestination(for: UUID.self) { categoryID in
                if let category = categoriesByID[categoryID] {
                    List(entries.filter { $0.category.parentID == category.id }.map(\.category)) { child in
                        categoryRow(child, canBrowse: expandableCategoryIDs.contains(child.id))
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle(category.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                } else {
                    ContentUnavailableView("Category unavailable", systemImage: "tag")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func categoryRow(
        _ category: LedgerCategory,
        breadcrumb: String? = nil,
        canBrowse: Bool
    ) -> some View {
        let canSelectCategory = allowsParentSelection || !canBrowse
        let row = selectionRow(
            title: category.displayName,
            iconEmoji: category.iconEmoji,
            systemImage: category.systemImage,
            id: category.id,
            breadcrumb: breadcrumb
        )

        return HStack(spacing: 0) {
            if canSelectCategory {
                Button {
                    selectedCategoryID = category.id
                    remember(category.id)
                    dismiss()
                } label: {
                    row
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("category-option-\(category.id.uuidString)")
            }

            if canBrowse {
                Button {
                    navigationPath.append(category.id)
                } label: {
                    if canSelectCategory {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    } else {
                        HStack(spacing: 0) {
                            row
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                                .frame(width: 44, height: 44)
                        }
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse \(category.displayName)")
                .accessibilityIdentifier("category-browse-\(category.id.uuidString)")
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    private func selectionRow(
        title: String,
        iconEmoji: String? = nil,
        systemImage: String,
        id: UUID?,
        breadcrumb: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            if let iconEmoji, !iconEmoji.isEmpty {
                Text(iconEmoji)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(PocketLedgerTheme.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(PocketLedgerTheme.textPrimary)
                if let breadcrumb {
                    Text(breadcrumb)
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }
            Spacer()
            if selectedCategoryID == id {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.accent)
                    .accessibilityHidden(true)
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
    let allowsParentSelection: Bool

    init(
        categories: [LedgerCategory],
        includeUncategorized: Bool = true,
        allowsParentSelection: Bool = true
    ) {
        self.categories = categories
        self.includeUncategorized = includeUncategorized
        self.allowsParentSelection = allowsParentSelection
    }

    var body: some View {
        let categoriesWithChildren = Set(categories.compactMap(\.parentID))

        if includeUncategorized {
            Text("Uncategorized").tag(nil as UUID?)
        }

        ForEach(sections) { section in
            Section {
                ForEach(section.entries) { entry in
                    Text(entry.label)
                        .tag(Optional(entry.category.id))
                        .disabled(
                            !allowsParentSelection && categoriesWithChildren.contains(entry.category.id)
                        )
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
            guard depth > 0 else { return category.displayName }
            return "\(String(repeating: "  ", count: depth))\(category.displayName)"
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

            return CategoryPickerSection(title: root.displayName, entries: entries)
        }
    }

    static func breadcrumb(
        for category: LedgerCategory,
        categoriesByID: [UUID: LedgerCategory]
    ) -> String? {
        var parentID = category.parentID
        var visited: Set<UUID> = [category.id]
        var ancestors: [String] = []

        while let id = parentID,
              visited.insert(id).inserted,
              let parent = categoriesByID[id] {
            ancestors.append(parent.displayName)
            parentID = parent.parentID
        }

        return ancestors.isEmpty ? nil : ancestors.reversed().joined(separator: " › ")
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
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString
                : comparison == .orderedAscending
        }
    }
}
