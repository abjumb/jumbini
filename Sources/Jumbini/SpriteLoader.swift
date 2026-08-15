import SpriteKit

/// One of the 8 directions Jumba's art is drawn in.
enum Facing: CaseIterable {
    case south, southEast, east, northEast, north, northWest, west, southWest

    var fileSuffix: String {
        switch self {
        case .south: "south"
        case .southEast: "south-east"
        case .east: "east"
        case .northEast: "north-east"
        case .north: "north"
        case .northWest: "north-west"
        case .west: "west"
        case .southWest: "south-west"
        }
    }

    /// Octant of a movement vector (scene coords, +y is up/north).
    static func from(dx: CGFloat, dy: CGFloat) -> Facing {
        guard dx != 0 || dy != 0 else { return .south }
        let idx = Int((atan2(dy, dx) / (.pi / 4)).rounded())
        switch idx {
        case 0: return .east
        case 1: return .northEast
        case 2: return .north
        case 3: return .northWest
        case -1: return .southEast
        case -2: return .south
        case -3: return .southWest
        default: return .west // 4 / -4
        }
    }

    var unitVector: CGPoint {
        let d: CGFloat = 0.7071
        switch self {
        case .south: return CGPoint(x: 0, y: -1)
        case .southEast: return CGPoint(x: d, y: -d)
        case .east: return CGPoint(x: 1, y: 0)
        case .northEast: return CGPoint(x: d, y: d)
        case .north: return CGPoint(x: 0, y: 1)
        case .northWest: return CGPoint(x: -d, y: d)
        case .west: return CGPoint(x: -1, y: 0)
        case .southWest: return CGPoint(x: -d, y: -d)
        }
    }

    var isNorthish: Bool {
        self == .north || self == .northEast || self == .northWest
    }
}

/// Which coat Jumba is wearing. The raw value is the sprite-file prefix the
/// importer writes (classic art is unprefixed) and the value persisted under
/// the "coat" default.
enum Coat: String, CaseIterable {
    case classic
    case shaggy

    var title: String {
        switch self {
        case .classic: "Classic"
        case .shaggy: "Shaggy"
        }
    }

    /// Prefix applied to every sprite name in this coat, "" for classic.
    var filePrefix: String { self == .classic ? "" : "\(rawValue)_" }
}

/// Loads Jumba's hand-made 8-directional sprites (imported by Tools/import_jumba.py)
/// plus the generated props (ball, heart). Nearest-neighbor keeps pixels crisp.
final class SpriteLibrary {
    static let shared = SpriteLibrary()

    /// The active coat. Every dog animation is resolved through this first and
    /// falls back to the classic art when the coat can't cover a pose. Nothing
    /// to invalidate on a change: `textureCache` is keyed by the full filename,
    /// so the two coats simply occupy different keys. The scene still has to
    /// re-`play` the current animation to put the new textures on screen.
    var coat: Coat = .classic

    /// Poses the shaggy art doesn't include, and what it borrows instead.
    /// The kit ships one shaggy sprint pose where classic has two, so the
    /// second run frame uses the shaggy pounce (legs gathered, body compressed)
    /// — together they read as a gallop. Letting run2 fall through to the
    /// classic art instead would swap his coat on every other frame at 13fps,
    /// and dropping the whole run cycle to classic would un-shag him for most
    /// of his waking life.
    private static let coatSubstitutes: [Coat: [String: String]] = [
        .shaggy: ["run2": "pounce"],
    ]

    struct Animation {
        let textures: [SKTexture]
        let fps: Double
        /// Node size in points (canvas size × state scale).
        let nodeSize: CGSize
        /// Mirror horizontally (bark art only exists facing east).
        let flipX: Bool
    }

    /// Base pixel scale: 48px art renders at ×2.4.
    private static let baseScale: CGFloat = 2.4
    /// The sit set was exported at a smaller pixel density than idle — upscale
    /// it so Jumba doesn't shrink when he sits (idle content 46px vs sit 38px).
    private static let sitScale: CGFloat = 2.9

    private var textureCache: [String: SKTexture] = [:]

    func animation(for dogAnimation: DogAnimation, facing: Facing) -> Animation? {
        let d = facing.fileSuffix
        switch dogAnimation {
        case .idle:
            return make(["idle_\(d)"], fps: 1, scale: Self.baseScale)
        case .walk:
            return make(["run1_\(d)", "run2_\(d)"], fps: 4, scale: Self.baseScale)
        case .run:
            return make(["run1_\(d)", "run2_\(d)"], fps: 13, scale: Self.baseScale)
        case .carryWalk:
            return make(["run1_\(d)", "run2_\(d)"], fps: 6, scale: Self.baseScale)
        case .sit:
            return make(["sit_\(d)"], fps: 1, scale: Self.sitScale)
        case .lie, .sleep:
            return make(["sleep_\(d)"], fps: 1, scale: Self.baseScale)
        case .spin:
            // A real spin: cycle through all 8 rotations of the idle pose.
            let cycle = [Facing.south, .southWest, .west, .northWest,
                         .north, .northEast, .east, .southEast]
            return make(cycle.map { "idle_\($0.fileSuffix)" }, fps: 24, scale: Self.baseScale)
        case .happy:
            return yap(facing: facing, fps: 8)
        case .dangle:
            // Held in the air: the sitting pose, facing the user.
            return make(["sit_south"], fps: 1, scale: Self.sitScale)
        case .sniff:
            return make(["sniff_\(d)"], fps: 1, scale: Self.baseScale)
        case .hunch:
            return make(["hunch_\(d)"], fps: 1, scale: Self.baseScale)
        // v4 states: the real filename first, an older pose as the stand-in
        // behind it — which is what let the hand-made art light these up with
        // no code change at all. All of them are real now except rollOver and
        // shakeToy, which nobody has drawn yet; leave the fallbacks in place.
        case .bark:
            return yap(facing: facing, fps: 8)
        case .stalk:
            return make(["stalk_\(d)"], fps: 1, scale: Self.baseScale)
                ?? make(["sniff_\(d)"], fps: 1, scale: Self.baseScale)
        case .pounce:
            return make(["pounce_\(d)"], fps: 1, scale: Self.baseScale)
                ?? make(["run2_\(d)"], fps: 1, scale: Self.baseScale)
        case .shakePaw:
            return make(["paw_\(d)"], fps: 1, scale: Self.baseScale)
                ?? make(["sit_\(d)"], fps: 1, scale: Self.sitScale)
        case .highFive:
            return make(["highfive_\(d)"], fps: 1, scale: Self.baseScale)
                ?? make(["sit_\(d)"], fps: 1, scale: Self.sitScale)
        case .playDead:
            return make(["playdead_\(d)"], fps: 1, scale: Self.baseScale)
                ?? make(["sleep_\(d)"], fps: 1, scale: Self.baseScale)
        case .rollOver:
            if let real = make(["rollover_\(d)"], fps: 1, scale: Self.baseScale) { return real }
            let cycle = [Facing.south, .southWest, .west, .northWest,
                         .north, .northEast, .east, .southEast]
            return make(cycle.map { "idle_\($0.fileSuffix)" }, fps: 8, scale: Self.baseScale)
        case .shakeToy:
            if let real = make(["shaketoy_\(d)"], fps: 8, scale: Self.baseScale) { return real }
            return yap(facing: facing, fps: 12)
        case .tug:
            return make(["brace_\(d)"], fps: 1, scale: Self.baseScale)
                ?? make(["sit_\(d)"], fps: 1, scale: Self.sitScale)
        case .fall:
            // Legs out, ears up. The run frame reads as airborne once the
            // dog is descending with nothing under him.
            return make(["fall_\(d)"], fps: 1, scale: Self.baseScale)
                ?? make(["run2_\(d)"], fps: 1, scale: Self.baseScale)
        case .land:
            // The touchdown absorb: a crouch, which the hunch pose already is.
            return make(["land_\(d)"], fps: 1, scale: Self.baseScale)
                ?? make(["hunch_\(d)"], fps: 1, scale: Self.baseScale)
        case .peek:
            // Nose over the edge of a window, looking down at the desktop.
            return make(["peek_\(d)"], fps: 1, scale: Self.baseScale)
                ?? make(["sniff_\(d)"], fps: 1, scale: Self.baseScale)
        }
    }

    /// True once the 8-rotation barking art is present. `Dog.renderedFacing`
    /// asks, so wardrobe placement stops pretending he's facing east.
    var hasDirectionalBark: Bool {
        texture(named: "bark_\(Facing.south.fileSuffix)") != nil
    }

    /// The bark cycle: the open-mouthed bark pose alternating with the
    /// mouth-shut idle of the SAME direction — a yap.
    ///
    /// The kit draws `barking` as the idle pose with the mouth open and the
    /// same silhouette, in all 8 rotations, so this gets both things the old
    /// art could only pick one of: he barks at what he's actually barking at,
    /// and his jaw still moves. (The old animation was six frames of motion
    /// that only existed facing east, mirrored for the three west-ish facings
    /// and simply wrong for the other four.) That six-frame strip is kept as
    /// the fallback so a build without the new art behaves exactly as before.
    private func yap(facing: Facing, fps: Double) -> Animation? {
        let d = facing.fileSuffix
        if let real = make(["bark_\(d)", "idle_\(d)"], fps: fps, scale: Self.baseScale) {
            return real
        }
        let flip = facing == .west || facing == .northWest || facing == .southWest
        return make((0..<6).map { "bark_\($0)" }, fps: 10, scale: Self.baseScale, flipX: flip)
    }

    private var propCache: [String: Animation] = [:]

    /// Generated props from Resources/sprites (horizontal-strip sheets).
    func prop(named name: String, frameWidth: Int, fps: Double) -> Animation? {
        if let cached = propCache[name] { return cached }
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "sprites"),
            let image = NSImage(contentsOf: url),
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let sheet = SKTexture(cgImage: cg)
        sheet.filteringMode = .nearest
        let count = max(1, cg.width / frameWidth)
        let textures = (0..<count).map { i -> SKTexture in
            let rect = CGRect(x: CGFloat(i) / CGFloat(count), y: 0, width: 1 / CGFloat(count), height: 1)
            let texture = SKTexture(rect: rect, in: sheet)
            texture.filteringMode = .nearest
            return texture
        }
        let animation = Animation(
            textures: textures,
            fps: fps,
            nodeSize: CGSize(width: CGFloat(frameWidth) * 3, height: CGFloat(cg.height) * 3),
            flipX: false
        )
        propCache[name] = animation
        return animation
    }

    /// Single-frame prop: the whole PNG as one texture at prop scale (×3).
    /// Used by imported furniture whose frame width varies per file.
    func singleProp(named name: String) -> Animation? {
        if let cached = propCache[name] { return cached }
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "sprites"),
            let image = NSImage(contentsOf: url),
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let texture = SKTexture(cgImage: cg)
        texture.filteringMode = .nearest
        let animation = Animation(
            textures: [texture],
            fps: 1,
            nodeSize: CGSize(width: CGFloat(cg.width) * 3, height: CGFloat(cg.height) * 3),
            flipX: false
        )
        propCache[name] = animation
        return animation
    }

    /// Build an animation from classic sprite names, rendered in the active
    /// coat. All-or-nothing per animation: a coat that's missing even one frame
    /// of a cycle hands the whole cycle back to the classic art rather than
    /// alternating coats mid-gait.
    /// Multi-frame prop assembled from individually numbered files —
    /// `dust_0.png`, `dust_1.png`, … — rather than sliced out of one strip
    /// sheet. Alex's art arrives one PNG per frame, and this keeps it that way:
    /// redrawing a single frame is a file drop, with no sheet to recompose.
    ///
    /// Frame size comes from the first file (the kit's frames are all square
    /// and equal-sized); the whole sequence is rejected if any file is missing,
    /// so a caller's `?? fallback` sees an incomplete sequence as no sequence.
    func propSequence(named name: String, frames: Int, fps: Double) -> Animation? {
        // Namespaced so a sequence can't collide with `prop`/`singleProp` art
        // of the same base name (there is a `frisbee_mouth` single AND a
        // `frisbee` sequence).
        let key = "seq:\(name):\(frames)"
        if let cached = propCache[key] { return cached }
        guard frames > 0 else { return nil }
        var textures: [SKTexture] = []
        var frameSize: CGSize = .zero
        for index in 0..<frames {
            guard
                let url = Bundle.module.url(
                    forResource: "\(name)_\(index)", withExtension: "png", subdirectory: "sprites"
                ),
                let image = NSImage(contentsOf: url),
                let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }
            let texture = SKTexture(cgImage: cg)
            texture.filteringMode = .nearest
            if textures.isEmpty {
                frameSize = CGSize(width: CGFloat(cg.width) * 3, height: CGFloat(cg.height) * 3)
            }
            textures.append(texture)
        }
        let animation = Animation(textures: textures, fps: fps, nodeSize: frameSize, flipX: false)
        propCache[key] = animation
        return animation
    }

    private func make(_ files: [String], fps: Double, scale: CGFloat, flipX: Bool = false) -> Animation? {
        if coat != .classic,
           let themed = build(files.map { coated($0) }, fps: fps, scale: scale, flipX: flipX) {
            return themed
        }
        return build(files, fps: fps, scale: scale, flipX: flipX)
    }

    /// `"run1_north-east"` in the shaggy coat -> `"shaggy_run1_north-east"`.
    /// The state is everything before the first underscore; the direction (or
    /// the legacy bark frame index) rides along untouched.
    private func coated(_ file: String) -> String {
        let state = file.prefix { $0 != "_" }
        let substituted = Self.coatSubstitutes[coat]?[String(state)] ?? String(state)
        return coat.filePrefix + substituted + file.dropFirst(state.count)
    }

    private func build(_ files: [String], fps: Double, scale: CGFloat, flipX: Bool) -> Animation? {
        let textures = files.compactMap(texture(named:))
        guard textures.count == files.count, let first = textures.first else { return nil }
        return Animation(
            textures: textures,
            fps: fps,
            nodeSize: CGSize(width: first.size().width * scale, height: first.size().height * scale),
            flipX: flipX
        )
    }

    private func texture(named name: String) -> SKTexture? {
        if let cached = textureCache[name] { return cached }
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "jumba"),
            let image = NSImage(contentsOf: url),
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let texture = SKTexture(cgImage: cg)
        texture.filteringMode = .nearest
        textureCache[name] = texture
        return texture
    }
}
