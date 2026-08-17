import Foundation
import CoreGraphics

/// One resolvable set of dog art.
///
/// Two things vary between coats, and they are deliberately separate. `root`
/// is *where* the art lives — nil for art baked into the app bundle, a folder
/// on disk for a coat the user installed. `prefix` is how a coat that shares a
/// folder with another one keeps its filenames apart. The bundled shaggy art
/// sits in the same `jumba/` directory as classic and is told apart by a
/// `shaggy_` prefix; an installed coat gets a directory to itself and needs no
/// prefix at all. Modelling both as a search root means custom coats slot in
/// beside the built-ins without disturbing them.
struct Coat: Identifiable {
    /// Stable identifier: the value persisted under the "coat" default, and
    /// the folder name for an installed coat.
    let id: String
    /// Menu title.
    let title: String
    /// Folder the sprites live in; nil means the app bundle's `jumba/`.
    let root: URL?
    /// Prefix applied to every sprite name in this coat, "" for its own folder.
    let prefix: String
    /// Per-state node scale, overriding the caller's default. See
    /// `CoatManifest.scales` for why this has to be per-coat data.
    let scales: [String: CGFloat]

    static let classic = Coat(id: "classic", title: "Classic", root: nil, prefix: "", scales: [:])
    static let shaggy = Coat(id: "shaggy", title: "Shaggy", root: nil, prefix: "shaggy_", scales: [:])

    /// The bundled coats, in menu order. Jumba's classic art is first and is
    /// what a fresh install uses.
    static let builtIn: [Coat] = [.classic, .shaggy]

    /// Where `name` would live if this coat carries its own art. Returns nil
    /// for the bundled coats, whose caller falls back to `Bundle.assets`.
    func fileURL(named name: String) -> URL? {
        root?.appendingPathComponent("\(prefix)\(name).png")
    }
}

/// Identity is the id alone. Two coats with the same id are the same coat even
/// if one was built before a manifest edit and the other after, which is what
/// lets a menu rebuild compare against the active coat without false misses.
extension Coat: Hashable {
    static func == (lhs: Coat, rhs: Coat) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The optional `coat.json` beside an installed coat's sprites.
///
/// `scales` exists because the art is not one canvas size. Jumba's own kit
/// draws 41 states on 48x48 but the three sitting poses on 68x76, with less of
/// the canvas filled — which is why `SpriteLibrary` carries a hardcoded
/// `sitScale` larger than its base scale. That constant is tuned to Jumba's
/// export specifically, so any coat drawn at a different density would render
/// the wrong size with no way to say so. A coat states its own overrides here.
/// It is `Codable` rather than `Decodable` because the Coat Workshop writes
/// this file back when the user edits a scale. Anything it does not recognise
/// is carried in `unrecognised` and re-encoded verbatim: a coat author may
/// have put an author or licence field in here, and a coat should not lose it
/// by being opened in the workshop.
struct CoatManifest: Codable, Equatable {
    var name: String?
    var scales: [String: Double]?
    /// Keys this version of the app does not interpret, kept for the round trip.
    var unrecognised: [String: UnknownValue] = [:]

    init(name: String? = nil, scales: [String: Double]? = nil, unrecognised: [String: UnknownValue] = [:]) {
        self.name = name
        self.scales = scales
        self.unrecognised = unrecognised
    }
}

extension CoatManifest {
    /// Any JSON value, held without interpretation so it can be written back
    /// exactly as it was read.
    enum UnknownValue: Codable, Equatable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([UnknownValue])
        case object([String: UnknownValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            // Bool before Double: JSON `true` is not a number, and a JSON
            // number is not a Bool, so the two never steal from each other.
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([UnknownValue].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: UnknownValue].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }

    /// A key of any name, so the decoder can see the whole object rather than
    /// only the two fields the app declares.
    private struct ManifestKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let knownKeys: Set<String> = ["name", "scales"]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ManifestKey.self)
        name = try container.decodeIfPresent(String.self, forKey: ManifestKey("name"))
        scales = try container.decodeIfPresent([String: Double].self, forKey: ManifestKey("scales"))
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            unrecognised[key.stringValue] = try container.decode(UnknownValue.self, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ManifestKey.self)
        try container.encodeIfPresent(name, forKey: ManifestKey("name"))
        try container.encodeIfPresent(scales, forKey: ManifestKey("scales"))
        for (key, value) in unrecognised where !Self.knownKeys.contains(key) {
            try container.encode(value, forKey: ManifestKey(key))
        }
    }
}

/// Finds the coats installed on disk and presents them alongside the bundled
/// ones. Pure path and JSON work: no AppKit, no SpriteKit, no bundle access,
/// so the resolution rules are testable against a temporary directory.
enum CoatCatalog {
    /// A coat folder must contain at least this, or there is nothing to draw
    /// and nothing to put in the menu.
    static let requiredSprite = "idle_south.png"

    /// `~/Library/Application Support/Jumbini/coats`, where installed coats go.
    static func defaultCoatsDirectory(
        fileManager: FileManager = .default
    ) -> URL? {
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return nil }
        return support.appendingPathComponent("Jumbini/coats", isDirectory: true)
    }

    /// Every coat the app can offer: the bundled ones first, then whatever is
    /// installed, sorted by title so the menu is stable between launches.
    ///
    /// A folder that fails to qualify is skipped in silence. Installing art is
    /// a file drop, so a half-copied folder is an ordinary transient state, not
    /// something to interrupt the user about.
    static func available(
        coatsDirectory: URL?,
        fileManager: FileManager = .default
    ) -> [Coat] {
        Coat.builtIn + installed(coatsDirectory: coatsDirectory, fileManager: fileManager)
    }

    /// The installed coats alone, sorted by title.
    static func installed(
        coatsDirectory: URL?,
        fileManager: FileManager = .default
    ) -> [Coat] {
        guard let coatsDirectory,
              let entries = try? fileManager.contentsOfDirectory(
                  at: coatsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }
        let builtInIDs = Set(Coat.builtIn.map(\.id))
        return entries
            .compactMap { coat(at: $0, fileManager: fileManager) }
            // An installed folder named "classic" must not shadow Jumba.
            .filter { !builtInIDs.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Read one coat folder, or nil if it isn't one.
    static func coat(at folder: URL, fileManager: FileManager = .default) -> Coat? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.fileExists(
                  atPath: folder.appendingPathComponent(requiredSprite).path
              )
        else { return nil }

        let id = folder.lastPathComponent
        let manifest = manifest(in: folder, fileManager: fileManager)
        let name = manifest?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Coat(
            id: id,
            title: name.flatMap { $0.isEmpty ? nil : $0 } ?? id,
            root: folder,
            prefix: "",
            scales: (manifest?.scales ?? [:]).mapValues { CGFloat($0) }
        )
    }

    /// A malformed manifest is treated as an absent one: the sprites are the
    /// thing that matters, and a coat with a bad `coat.json` should still load
    /// at default scale rather than vanish from the menu.
    static func manifest(in folder: URL, fileManager: FileManager = .default) -> CoatManifest? {
        let url = folder.appendingPathComponent("coat.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(CoatManifest.self, from: data)
    }
}
