import AppKit
import SwiftUI

enum LibrarySection: Hashable, CaseIterable {
    case albums
    case downloads

    fileprivate var systemImage: String {
        switch self {
        case .albums: "square.stack"
        case .downloads: "arrow.down.circle"
        }
    }

    fileprivate func title(locale: Locale) -> String {
        switch self {
        case .albums: String(localized: "Albums", locale: locale)
        case .downloads: String(localized: "Downloaded", locale: locale)
        }
    }
}

struct SidebarView: View {
    @Binding var selection: LibrarySection?

    var body: some View {
        AppKitLibrarySidebar(selection: $selection)
            .navigationTitle("Yorune")
    }
}

private struct AppKitLibrarySidebar: NSViewRepresentable {
    @Environment(\.locale) private var locale
    @Binding var selection: LibrarySection?

    fileprivate var items: [LibrarySection] {
        Array(LibrarySection.allCases)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reloadIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: AppKitLibrarySidebar
        private weak var tableView: NSTableView?
        private var items: [LibrarySection]
        private var localeIdentifier: String
        private var isSyncingSelection = false

        init(parent: AppKitLibrarySidebar) {
            self.parent = parent
            self.items = parent.items
            self.localeIdentifier = parent.locale.identifier
            super.init()
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.horizontalScrollElasticity = .none
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(
                top: 0,
                left: 0,
                bottom: 0,
                right: 0
            )

            let tableView = NSTableView()
            tableView.frame = scrollView.contentView.bounds
            tableView.autoresizingMask = [.width]
            tableView.delegate = self
            tableView.dataSource = self
            tableView.headerView = nil
            tableView.backgroundColor = .clear
            tableView.style = .sourceList
            tableView.selectionHighlightStyle = .regular
            tableView.rowSizeStyle = .custom
            tableView.intercellSpacing = NSSize(width: 0, height: 2)
            tableView.allowsMultipleSelection = false
            tableView.allowsEmptySelection = true
            tableView.floatsGroupRows = false
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier("LibrarySidebarColumn")
            )
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)

            scrollView.documentView = tableView
            self.tableView = tableView
            syncSelection(in: tableView)
            return scrollView
        }

        func reloadIfNeeded() {
            guard let tableView else { return }

            let nextItems = parent.items
            let nextLocaleIdentifier = parent.locale.identifier
            if nextItems != items || nextLocaleIdentifier != localeIdentifier {
                items = nextItems
                localeIdentifier = nextLocaleIdentifier
                tableView.reloadData()
            } else {
                reloadVisibleRows(in: tableView)
            }
            syncSelection(in: tableView)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            items.indices.contains(row)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            30
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            LibrarySidebarRowView()
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard items.indices.contains(row) else { return nil }

            let cell = tableView.makeView(
                withIdentifier: LibrarySidebarCell.reuseIdentifier,
                owner: self
            ) as? LibrarySidebarCell ?? LibrarySidebarCell()
            let section = items[row]
            cell.configure(
                title: section.title(locale: parent.locale),
                systemImage: section.systemImage,
                isSelected: tableView.selectedRow == row
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection,
                  let tableView = notification.object as? NSTableView,
                  items.indices.contains(tableView.selectedRow) else {
                return
            }

            let section = items[tableView.selectedRow]
            parent.selection = section
            if parent.selection != section {
                syncSelection(in: tableView)
            }
            applySelectionStyleToVisibleRows(in: tableView)
        }

        private func syncSelection(in tableView: NSTableView) {
            guard let selection = parent.selection,
                  let row = items.firstIndex(of: selection) else {
                isSyncingSelection = true
                tableView.deselectAll(nil)
                isSyncingSelection = false
                applySelectionStyleToVisibleRows(in: tableView)
                return
            }

            guard tableView.selectedRow != row else {
                applySelectionStyleToVisibleRows(in: tableView)
                return
            }

            isSyncingSelection = true
            tableView.selectRowIndexes(
                IndexSet(integer: row),
                byExtendingSelection: false
            )
            isSyncingSelection = false
            applySelectionStyleToVisibleRows(in: tableView)
        }

        private func reloadVisibleRows(in tableView: NSTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }

            for row in visibleRows.location ..< NSMaxRange(visibleRows) {
                guard items.indices.contains(row),
                      let cell = tableView.view(
                        atColumn: 0,
                        row: row,
                        makeIfNecessary: false
                      ) as? LibrarySidebarCell else {
                    continue
                }

                let section = items[row]
                cell.configure(
                    title: section.title(locale: parent.locale),
                    systemImage: section.systemImage,
                    isSelected: tableView.selectedRow == row
                )
            }
        }

        private func applySelectionStyleToVisibleRows(in tableView: NSTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }

            for row in visibleRows.location ..< NSMaxRange(visibleRows) {
                guard let cell = tableView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: false
                ) as? LibrarySidebarCell else {
                    continue
                }
                cell.applySelectionStyle(isSelected: tableView.selectedRow == row)
            }
        }
    }
}

private final class LibrarySidebarRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            applySelectionStyleToCell()
        }
    }

    override var isEmphasized: Bool {
        get { false }
        set { super.isEmphasized = false }
    }

    private func applySelectionStyleToCell() {
        for subview in subviews {
            (subview as? LibrarySidebarCell)?.applySelectionStyle(
                isSelected: isSelected
            )
        }
    }
}

private final class LibrarySidebarCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("LibrarySidebarCell")
    private static let leadingInset: CGFloat = 3
    private static let trailingInset: CGFloat = 14

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = NSColor(
            srgbRed: 1,
            green: 0,
            blue: 0.337,
            alpha: 1
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.leadingInset
            ),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleField.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: 8
            ),
            titleField.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Self.trailingInset
            ),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, systemImage: String, isSelected: Bool) {
        titleField.stringValue = title
        iconView.image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: title
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        )
        applySelectionStyle(isSelected: isSelected)
    }

    func applySelectionStyle(isSelected: Bool) {
        let weight: NSFont.Weight = isSelected ? .semibold : .regular
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: weight)
    }
}
