import AppKit
import Testing
@testable import Jumbini

// The sidebar-and-pages chrome the settings-style panels share.
//
// `PanelSectionCatalog` was already testable, so the matching rules are covered
// elsewhere. What was not reachable is everything between a catalog and a
// rendered panel: whether a sidebar click actually switches the page, whether
// typing reaches the matcher, and whether exactly one row ends up selected. Two
// copies of that code existed and had already drifted in three ways.
//
// The click and the search are driven through the real target-action rather than
// by calling `show` directly, because the wiring is the part that breaks in
// silence — a mistyped selector compiles, renders, and simply does nothing.

private let testCatalog = PanelSectionCatalog(groups: [
    PanelSectionGroup(title: "Group One", sections: [
        PanelSection(identifier: "alpha", title: "Alpha", symbol: "a.circle", tint: .systemRed),
        PanelSection(identifier: "beta", title: "Beta", symbol: "b.circle", tint: .systemBlue),
    ]),
    PanelSectionGroup(title: "Group Two", sections: [
        PanelSection(identifier: "gamma", title: "Gamma", symbol: "g.circle", tint: .systemGreen),
    ]),
])

@MainActor
private func makeShell(searchable: Bool = true) -> (PanelShell, [String: NSView]) {
    let shell = PanelShell(
        catalog: testCatalog,
        size: CGSize(width: 720, height: 480),
        search: searchable
            ? PanelShell.Search(placeholder: "Search…", accessibilityLabel: "Search")
            : nil
    )
    let pages = ["alpha": NSView(), "beta": NSView(), "gamma": NSView()]
    shell.setPages(pages)
    return (shell, pages)
}

@MainActor
private func allSubviews(_ root: NSView) -> [NSView] {
    root.subviews + root.subviews.flatMap(allSubviews)
}

@MainActor
private func sidebarButtons(of shell: PanelShell) -> [PanelSidebarButton] {
    allSubviews(shell.contentView).compactMap { $0 as? PanelSidebarButton }
}

@MainActor
private func searchField(of shell: PanelShell) -> NSSearchField? {
    allSubviews(shell.contentView).compactMap { $0 as? NSSearchField }.first
}

/// Fires a control's target-action the way AppKit does, so the test exercises
/// the wiring rather than the method it happens to point at.
@MainActor
private func activate(_ control: NSControl) {
    guard let action = control.action else {
        Issue.record("\(control) has no action wired")
        return
    }
    _ = NSApplication.shared.sendAction(action, to: control.target, from: control)
}

// MARK: - Selection

@Test @MainActor func theSectionItIsShownStartsVisible() {
    let (shell, pages) = makeShell()

    shell.show("beta")

    #expect(shell.visibleSection == "beta")
    #expect(pages["beta"]?.superview != nil, "the page must actually be in the container")
}

@Test @MainActor func clickingASidebarRowSwitchesThePage() {
    let (shell, pages) = makeShell()
    shell.show("alpha")
    let buttons = sidebarButtons(of: shell)
    #expect(buttons.count == 3, "one row per section, got \(buttons.count)")

    guard let gamma = buttons.first(where: { $0.identifier?.rawValue == "gamma" }) else {
        Issue.record("no sidebar row for gamma")
        return
    }
    activate(gamma)

    #expect(shell.visibleSection == "gamma")
    #expect(pages["gamma"]?.superview != nil)
    #expect(pages["alpha"]?.superview == nil, "the old page must come out of the container")
}

@Test @MainActor func exactlyOneRowIsSelectedAtATime() {
    let (shell, _) = makeShell()

    for identifier in ["alpha", "beta", "gamma", "alpha"] {
        shell.show(identifier)
        let selected = sidebarButtons(of: shell).filter(\.isSelectedRow)
        #expect(selected.count == 1, "showing \(identifier) selected \(selected.count) rows")
        #expect(selected.first?.identifier?.rawValue == identifier)
    }
}

@Test @MainActor func anIdentifierWithNoPageIsANoOp() {
    // It used to clear the container and THEN bail, so a catalog/page mismatch
    // emptied the content area and left its row highlighted — a panel that looks
    // broken rather than one that did nothing.
    let (shell, pages) = makeShell()
    shell.show("beta")

    shell.show("nonexistent")

    #expect(shell.visibleSection == "beta", "the last good section stays showing")
    #expect(pages["beta"]?.superview != nil, "and its page stays in the container")
}

// MARK: - Search

@Test @MainActor func typingJumpsToTheMatchingSection() {
    // PanelSectionCatalog.firstMatch is tested on its own; what is new here is
    // that typing actually reaches it.
    let (shell, _) = makeShell()
    shell.show("alpha")
    guard let field = searchField(of: shell) else {
        Issue.record("a searchable shell must have a search field")
        return
    }

    field.stringValue = "gam"
    activate(field)

    #expect(shell.visibleSection == "gamma")
}

@Test @MainActor func aSearchThatMatchesNothingLeavesTheSectionAlone() {
    let (shell, _) = makeShell()
    shell.show("beta")
    guard let field = searchField(of: shell) else {
        Issue.record("a searchable shell must have a search field")
        return
    }

    field.stringValue = "zzzz"
    activate(field)

    #expect(shell.visibleSection == "beta")
}

@Test @MainActor func aShellWithoutSearchHasNoSearchField() {
    // Tidy has three sections and does not want one.
    let (shell, _) = makeShell(searchable: false)

    #expect(searchField(of: shell) == nil)
    #expect(sidebarButtons(of: shell).count == 3, "the rows are unaffected")
}

// MARK: - The real panels agree with their own catalogs

@Test @MainActor func everySettingsSectionHasAPage() {
    // Nothing enforced that a catalog and a page dictionary line up. A section
    // with no page is now a no-op rather than a blank pane, but it is still
    // wrong, and this is where it would be caught.
    let panel = SettingsPanel(defaults: UserDefaults(suiteName: "panelshell.test") ?? .standard)

    for section in SettingsPanel.catalog.sections {
        panel.showSection(section.identifier)
        #expect(
            panel.visibleSection == section.identifier,
            "\(section.identifier) is in the catalog with no page behind it"
        )
    }
}

@Test @MainActor func everyTidySectionHasAPage() {
    let panel = TidySettingsPanel()

    for section in TidySettingsPanel.catalog.sections {
        panel.showSection(section.identifier)
        #expect(
            panel.visibleSection == section.identifier,
            "\(section.identifier) is in the catalog with no page behind it"
        )
    }
}
