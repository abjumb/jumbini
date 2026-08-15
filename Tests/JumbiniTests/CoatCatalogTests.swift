import Testing
import CoreGraphics
import Foundation
@testable import Jumbini

// `CoatCatalog` is the disk half of the coat system: which folders count as
// installed coats, what they are called, and what scale overrides they carry.
// None of it touches AppKit or SpriteKit, so these tests build coat folders in
// a temporary directory — valid ones, half-copied ones, ones with a broken
// manifest — and check what the menu would be offered.
//
// The rule the whole feature rests on: a fresh install, with no coats
// directory at all, must be indistinguishable from before this existed.

// MARK: - Fixtures

/// A scratch coats directory that cleans itself up.
private final class TempCoats {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jumbini-coats-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Write a coat folder. `sprites` are bare names; `.png` is appended.
    @discardableResult
    func install(_ id: String, sprites: [String] = ["idle_south"], manifest: String? = nil) -> URL {
        let folder = url.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for sprite in sprites {
            FileManager.default.createFile(
                atPath: folder.appendingPathComponent("\(sprite).png").path, contents: Data()
            )
        }
        if let manifest {
            try? manifest.write(
                to: folder.appendingPathComponent("coat.json"), atomically: true, encoding: .utf8
            )
        }
        return folder
    }

    /// Drop a loose file in the coats directory — not a coat.
    func installLooseFile(_ name: String) {
        FileManager.default.createFile(atPath: url.appendingPathComponent(name).path, contents: Data())
    }
}

// MARK: - The untouched-install guarantee

@Test func noCoatsDirectoryOffersExactlyTheBuiltIns() {
    let coats = CoatCatalog.available(coatsDirectory: nil)
    #expect(coats.map(\.id) == ["classic", "shaggy"])
}

@Test func missingCoatsDirectoryOffersExactlyTheBuiltIns() {
    let absent = FileManager.default.temporaryDirectory
        .appendingPathComponent("jumbini-not-here-\(UUID().uuidString)", isDirectory: true)
    #expect(CoatCatalog.available(coatsDirectory: absent).map(\.id) == ["classic", "shaggy"])
}

@Test func emptyCoatsDirectoryOffersExactlyTheBuiltIns() {
    let temp = TempCoats()
    #expect(CoatCatalog.available(coatsDirectory: temp.url).map(\.id) == ["classic", "shaggy"])
}

@Test func builtInsResolveThroughTheBundle() {
    // A nil root is what sends resolution to `Bundle.module`; the shaggy art
    // shares classic's folder and is told apart by its prefix.
    #expect(Coat.classic.fileURL(named: "idle_south") == nil)
    #expect(Coat.classic.prefix.isEmpty)
    #expect(Coat.shaggy.fileURL(named: "idle_south") == nil)
    #expect(Coat.shaggy.prefix == "shaggy_")
}

// MARK: - What counts as an installed coat

@Test func aFolderWithIdleSouthIsACoat() {
    let temp = TempCoats()
    temp.install("nova")
    let coats = CoatCatalog.installed(coatsDirectory: temp.url)
    #expect(coats.map(\.id) == ["nova"])
    // No manifest: the folder name is the menu title.
    #expect(coats.first?.title == "nova")
}

@Test func aFolderWithoutIdleSouthIsSkipped() {
    // The half-copied case. Nothing to draw and nothing to thumbnail, so it
    // must not reach the menu — and must not raise anything either.
    let temp = TempCoats()
    temp.install("partial", sprites: ["sit_south", "run1_south"])
    #expect(CoatCatalog.installed(coatsDirectory: temp.url).isEmpty)
}

@Test func looseFilesAreNotCoats() {
    let temp = TempCoats()
    temp.installLooseFile("notes.txt")
    temp.installLooseFile("idle_south.png")
    #expect(CoatCatalog.installed(coatsDirectory: temp.url).isEmpty)
}

@Test func installedCoatsCannotShadowTheBuiltIns() {
    // Someone naming a folder "classic" must not be able to displace Jumba,
    // who is the app's identity and its default.
    let temp = TempCoats()
    temp.install("classic")
    temp.install("shaggy")
    temp.install("nova")
    #expect(CoatCatalog.installed(coatsDirectory: temp.url).map(\.id) == ["nova"])

    let all = CoatCatalog.available(coatsDirectory: temp.url)
    #expect(all.map(\.id) == ["classic", "shaggy", "nova"])
    #expect(all.first?.root == nil)  // still the bundled Jumba
}

@Test func installedCoatsSortByTitleAfterTheBuiltIns() {
    let temp = TempCoats()
    temp.install("zephyr")
    temp.install("aster")
    temp.install("mabel")
    #expect(CoatCatalog.available(coatsDirectory: temp.url).map(\.id)
            == ["classic", "shaggy", "aster", "mabel", "zephyr"])
}

// MARK: - The manifest

@Test func manifestNameBecomesTheMenuTitle() {
    let temp = TempCoats()
    temp.install("nova-2026", manifest: #"{"name": "Nova"}"#)
    let coat = CoatCatalog.installed(coatsDirectory: temp.url).first
    #expect(coat?.title == "Nova")
    #expect(coat?.id == "nova-2026")  // identity stays the folder name
}

@Test func manifestCarriesPerStateScales() {
    // The reason a manifest exists at all: Jumba's own kit draws 41 states on
    // 48x48 but the sitting poses on 68x76, which is why SpriteLibrary carries
    // a hardcoded sit scale tuned to his export. A coat drawn at a different
    // density says so here instead.
    let temp = TempCoats()
    temp.install("nova", manifest: #"{"name": "Nova", "scales": {"sit": 3.1, "sleep": 2.2}}"#)
    let coat = CoatCatalog.installed(coatsDirectory: temp.url).first
    #expect(coat?.scales["sit"] == 3.1)
    #expect(coat?.scales["sleep"] == 2.2)
    #expect(coat?.scales["idle"] == nil)  // unlisted states keep the app default
}

@Test func aBrokenManifestDoesNotHideTheCoat() {
    // The sprites are the thing that matters. A coat with unparseable JSON
    // should still load at default scale rather than vanish from the menu.
    let temp = TempCoats()
    temp.install("nova", manifest: "{ this is not json")
    let coat = CoatCatalog.installed(coatsDirectory: temp.url).first
    #expect(coat?.id == "nova")
    #expect(coat?.title == "nova")
    #expect(coat?.scales.isEmpty == true)
}

@Test func anEmptyManifestNameFallsBackToTheFolder() {
    let temp = TempCoats()
    temp.install("nova", manifest: #"{"name": "   "}"#)
    #expect(CoatCatalog.installed(coatsDirectory: temp.url).first?.title == "nova")
}

// MARK: - Sprite paths

@Test func installedCoatResolvesSpritesInItsOwnFolder() {
    let temp = TempCoats()
    let folder = temp.install("nova")
    let coat = CoatCatalog.coat(at: folder)
    #expect(coat?.fileURL(named: "idle_south")?.lastPathComponent == "idle_south.png")
    #expect(coat?.fileURL(named: "run1_north-east")?.deletingLastPathComponent() == folder)
    // Its own folder, so no prefix to disambiguate against.
    #expect(coat?.prefix.isEmpty == true)
}

@Test func coatIdentityIsTheIdAlone() {
    // The menu compares the active coat against freshly-scanned ones to place
    // its checkmark; a manifest edit between scans must not read as a
    // different coat.
    let a = Coat(id: "nova", title: "Nova", root: URL(fileURLWithPath: "/a"), prefix: "", scales: [:])
    let b = Coat(id: "nova", title: "Renamed", root: URL(fileURLWithPath: "/b"), prefix: "", scales: ["sit": 3])
    #expect(a == b)
    #expect(Set([a, b]).count == 1)
    #expect(a != Coat.classic)
}
