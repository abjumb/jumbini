import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// "Make Your Own Dog": turn three photos into a coat the dog can wear.
//
// The pipeline is `DogGenerator.generate` (photos -> Pixellab -> 56 sprites)
// plus two pure, AppKit-free steps that are unit-tested on their own:
// `postProcess` (normalise one Pixellab output into a 48x48 RGBA sprite with a
// transparent background and a closed dark outline) and `writeCoat` (lay the
// sprites out as `<state>_<direction>.png` in a coat folder). Everything here
// is Foundation + CoreGraphics so the whole layer is testable against a
// temporary directory with a mock client.

/// The seven states a generated dog draws. `run1`/`run2` are the two frames of
/// the gait; every other state is a single pose. States the generator does not
/// produce (stalk, pounce, fall, peek, hunch, …) fall back to Jumba's art at
/// render time, exactly as any incomplete hand-made coat would.
enum CoatState: String, CaseIterable {
    case idle, run1, run2, sit, sleep, bark, sniff
}

/// One Pixellab `animate-character` call and the coat states it feeds.
///
/// Pixellab animates one *action* per call (across all 8 directions), so five
/// actions cover the six non-idle states — `run` yields both `run1` and `run2`.
/// Each action requests `frameCount` frames and the pipeline picks the frames
/// that read as the pose: the last frame of a motion is the settled pose
/// (`sit`, `sleep`, `sniff`), the first is the mouth-open peak (`bark`), and
/// two spread frames make the gait.
enum PixellabAction: CaseIterable {
    case run, sit, sleep, bark, sniff

    /// Text description sent to Pixellab as the motion prompt.
    var actionDescription: String {
        switch self {
        case .run: return "running with a two-frame gait"
        case .sit: return "sitting down"
        case .sleep: return "lying down and sleeping"
        case .bark: return "barking with the mouth open"
        case .sniff: return "sniffing the ground"
        }
    }

    /// The `animation_name` we store the result under, so the client can find
    /// this action's frames again on the character.
    var animationName: String {
        switch self {
        case .run: return "run"
        case .sit: return "sit"
        case .sleep: return "sleep"
        case .bark: return "bark"
        case .sniff: return "sniff"
        }
    }

    /// Number of frames to request from Pixellab (v3 mode requires an even
    /// count between 4 and 16).
    var frameCount: Int { 4 }

    /// Which coat state each picked frame feeds, in order.
    var states: [(state: CoatState, frameIndex: Int)] {
        switch self {
        case .run: return [(.run1, 0), (.run2, 2)]
        case .sit: return [(.sit, 3)]
        case .sleep: return [(.sleep, 3)]
        case .bark: return [(.bark, 0)]
        case .sniff: return [(.sniff, 3)]
        }
    }
}

/// The three photos the user picks. The Pixellab character creator accepts a
/// single south-facing reference image, so `front` drives generation today;
/// `side` and `back` are collected (the panel asks for all three) and kept here
/// so a future multi-reference endpoint only changes the client, not the flow.
struct DogPhotos {
    let front: Data
    let side: Data
    let back: Data
}

enum DogGeneratorError: Error, Equatable {
    case invalidImage
    case encodeFailed
    case missingRotation(Facing)
    case missingFrame(CoatState, Facing)
}

/// The generation pipeline, the sprite normaliser, and the coat writer.
enum DogGenerator {
    /// The stable coat id. Regenerating overwrites the previous dog, so the
    /// user's selection (persisted under this id) survives a redo.
    static let coatID = "my-dog"
    static let coatName = "My Dog"

    /// Every coat sprite is 48x48 RGBA (COATS.md "Canvas and pixels").
    static let canvasSize = 48
    /// The closed 1px dark outline the importer relies on. Pure black is the
    /// most defensible "hard, dark" outline and makes the "is this pixel dark"
    /// test unambiguous.
    static let outlineColor = (r: UInt8(0), g: UInt8(0), b: UInt8(0))

    /// The sprite filename for a state + direction, e.g. `run1_north-east.png`.
    static func filename(state: CoatState, direction: Facing) -> String {
        "\(state.rawValue)_\(direction.fileSuffix).png"
    }

    // MARK: - Pipeline

    /// Run the whole generation: create the character, animate the five
    /// actions, normalise every sprite, and write the coat folder. Returns the
    /// coat folder written.
    static func generate(
        photos: DogPhotos,
        client: PixellabClientProtocol
    ) async throws -> [CoatState: [Facing: Data]] {
        let character = try await client.createCharacter(referenceImage: photos.front)

        var sprites: [CoatState: [Facing: Data]] = [:]
        for direction in Facing.allCases {
            guard let idle = character.rotations[direction] else {
                throw DogGeneratorError.missingRotation(direction)
            }
            sprites[.idle, default: [:]][direction] = try postProcess(idle)
        }

        for action in PixellabAction.allCases {
            let frames = try await client.animate(characterID: character.id, action: action)
            for (state, frameIndex) in action.states {
                for direction in Facing.allCases {
                    guard let directionFrames = frames[direction],
                          frameIndex < directionFrames.count else {
                        throw DogGeneratorError.missingFrame(state, direction)
                    }
                    sprites[state, default: [:]][direction] =
                        try postProcess(directionFrames[frameIndex])
                }
            }
        }
        return sprites
    }

    /// `generate` followed by writing to the user's coats directory.
    static func generateAndWrite(
        photos: DogPhotos,
        client: PixellabClientProtocol,
        coatsDirectory: URL,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let sprites = try await generate(photos: photos, client: client)
        return try writeCoat(
            sprites,
            to: coatsDirectory.appendingPathComponent(coatID, isDirectory: true),
            fileManager: fileManager
        )
    }

    // MARK: - Coat writing

    /// Write all 56 sprites (7 states x 8 directions) plus `coat.json` into
    /// `folder`. The folder is cleared first so a redo cannot leave stale
    /// sprites from a previous, larger generation.
    @discardableResult
    static func writeCoat(
        _ sprites: [CoatState: [Facing: Data]],
        to folder: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        for state in CoatState.allCases {
            for direction in Facing.allCases {
                guard let data = sprites[state]?[direction] else {
                    throw DogGeneratorError.missingFrame(state, direction)
                }
                let url = folder.appendingPathComponent(filename(state: state, direction: direction))
                try data.write(to: url)
            }
        }

        let manifest = #"{"name": "\#(coatName)"}"#
        try manifest.write(
            to: folder.appendingPathComponent("coat.json"),
            atomically: true,
            encoding: .utf8
        )
        return folder
    }

    // MARK: - Post-processing

    /// Normalise one Pixellab output into a coat sprite: 48x48 RGBA, nearest
    /// neighbour, transparent background, and a closed 1px dark outline.
    static func postProcess(_ input: Data) throws -> Data {
        guard let cgImage = decode(input) else { throw DogGeneratorError.invalidImage }
        guard var rgba = pixels(of: cgImage) else { throw DogGeneratorError.invalidImage }
        if rgba.width != canvasSize || rgba.height != canvasSize {
            rgba = resize(rgba, to: canvasSize, height: canvasSize)
        }
        stripBackground(&rgba)
        thresholdAlpha(&rgba, threshold: 128)
        enforceOutline(&rgba, color: outlineColor)
        guard let png = pngData(from: rgba) else { throw DogGeneratorError.encodeFailed }
        return png
    }
}

// MARK: - Image codec (CoreGraphics, no AppKit)

/// Raw 8-bit RGBA pixels, top-down row order.
struct RGBAImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

extension DogGenerator {
    /// Decode arbitrary image data to a CGImage.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Draw a CGImage into an unpremultiplied RGBA pixel buffer.
    ///
    /// CoreGraphics bitmap contexts only accept premultiplied alpha, so the
    /// bytes are drawn premultiplied and then un-premultiplied in place — every
    /// downstream operation (background strip, alpha threshold, outline) works
    /// on plain RGBA.
    static func pixels(of image: CGImage) -> RGBAImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        unpremultiply(&pixels)
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    /// Nearest-neighbour resize (crisp for pixel art; no blending).
    static func resize(_ source: RGBAImage, to width: Int, height: Int) -> RGBAImage {
        var dst = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let sy = min(source.height - 1, y * source.height / height)
            for x in 0..<width {
                let sx = min(source.width - 1, x * source.width / width)
                let si = (sy * source.width + sx) * 4
                let di = (y * width + x) * 4
                dst[di] = source.pixels[si]
                dst[di + 1] = source.pixels[si + 1]
                dst[di + 2] = source.pixels[si + 2]
                dst[di + 3] = source.pixels[si + 3]
            }
        }
        return RGBAImage(width: width, height: height, pixels: dst)
    }

    /// Encode unpremultiplied RGBA pixels as a PNG, re-premultiplying for the
    /// bitmap context (PNG itself stores unpremultiplied alpha, so the
    /// destination un-premultiplies again on write).
    static func pngData(from image: RGBAImage) -> Data? {
        var pixels = image.pixels
        premultiply(&pixels)
        let cgImage: CGImage? = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        guard let cgImage else { return nil }
        return pngData(from: cgImage)
    }

    private static func unpremultiply(_ pixels: inout [UInt8]) {
        var i = 0
        while i < pixels.count {
            let a = pixels[i + 3]
            if a != 0 {
                pixels[i] = UInt8(min(255, Int(pixels[i]) * 255 / Int(a)))
                pixels[i + 1] = UInt8(min(255, Int(pixels[i + 1]) * 255 / Int(a)))
                pixels[i + 2] = UInt8(min(255, Int(pixels[i + 2]) * 255 / Int(a)))
            }
            i += 4
        }
    }

    private static func premultiply(_ pixels: inout [UInt8]) {
        var i = 0
        while i < pixels.count {
            let a = pixels[i + 3]
            pixels[i] = UInt8(Int(pixels[i]) * Int(a) / 255)
            pixels[i + 1] = UInt8(Int(pixels[i + 1]) * Int(a) / 255)
            pixels[i + 2] = UInt8(Int(pixels[i + 2]) * Int(a) / 255)
            i += 4
        }
    }

    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Background strip

    /// The colour of the first opaque corner, or nil if the image is already
    /// transparent around its edges (so there is nothing to strip).
    private static func backgroundColor(_ image: RGBAImage) -> (r: UInt8, g: UInt8, b: UInt8)? {
        let w = image.width, h = image.height
        let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
        for (x, y) in corners {
            let i = (y * w + x) * 4
            if image.pixels[i + 3] > 0 {
                return (image.pixels[i], image.pixels[i + 1], image.pixels[i + 2])
            }
        }
        return nil
    }

    /// Flood-fill from the borders, clearing any background-coloured pixels
    /// connected to the outside. The dark outline (and anything the outline
    /// encloses) stops the fill — the same idea as the importer's edge fill.
    private static func stripBackground(_ image: inout RGBAImage, tolerance: Int = 40) {
        guard let background = backgroundColor(image) else { return }
        let w = image.width, h = image.height
        let bgR = Int(background.r), bgG = Int(background.g), bgB = Int(background.b)

        // `pixelIndex` is a row-major index into the image; multiply by 4 to
        // reach the RGBA bytes.
        func isBackground(_ pixelIndex: Int) -> Bool {
            let i = pixelIndex * 4
            if image.pixels[i + 3] == 0 { return true }
            let dr = abs(Int(image.pixels[i]) - bgR)
            let dg = abs(Int(image.pixels[i + 1]) - bgG)
            let db = abs(Int(image.pixels[i + 2]) - bgB)
            return dr <= tolerance && dg <= tolerance && db <= tolerance
        }

        var visited = [Bool](repeating: false, count: w * h)
        var queue: [Int] = []
        func seed(_ x: Int, _ y: Int) {
            let pixel = y * w + x
            if !visited[pixel] && isBackground(pixel) {
                visited[pixel] = true
                queue.append(pixel)
            }
        }
        for x in 0..<w {
            seed(x, 0)
            seed(x, h - 1)
        }
        for y in 0..<h {
            seed(0, y)
            seed(w - 1, y)
        }

        var head = 0
        while head < queue.count {
            let pixel = queue[head]
            head += 1
            let i = pixel * 4
            if image.pixels[i + 3] != 0 {
                image.pixels[i + 3] = 0
            }
            let x = pixel % w, y = pixel / w
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] {
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                let neighbour = ny * w + nx
                if !visited[neighbour] && isBackground(neighbour) {
                    visited[neighbour] = true
                    queue.append(neighbour)
                }
            }
        }
    }

    /// Snap alpha to fully opaque / fully transparent. This removes the
    /// anti-aliased fringe the outline must be free of.
    private static func thresholdAlpha(_ image: inout RGBAImage, threshold: UInt8) {
        var i = 0
        while i < image.pixels.count {
            image.pixels[i + 3] = image.pixels[i + 3] < threshold ? 0 : 255
            i += 4
        }
    }

    /// Darken every opaque pixel that borders a transparent one, guaranteeing
    /// a closed 1px outline around the whole sprite.
    private static func enforceOutline(
        _ image: inout RGBAImage,
        color: (r: UInt8, g: UInt8, b: UInt8)
    ) {
        let w = image.width, h = image.height
        func isTransparent(_ x: Int, _ y: Int) -> Bool {
            x < 0 || x >= w || y < 0 || y >= h || image.pixels[(y * w + x) * 4 + 3] == 0
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard image.pixels[i + 3] != 0 else { continue }
                if isTransparent(x - 1, y) || isTransparent(x + 1, y)
                    || isTransparent(x, y - 1) || isTransparent(x, y + 1) {
                    image.pixels[i] = color.r
                    image.pixels[i + 1] = color.g
                    image.pixels[i + 2] = color.b
                    image.pixels[i + 3] = 255
                }
            }
        }
    }
}
