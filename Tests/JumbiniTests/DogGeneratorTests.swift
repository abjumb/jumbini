import Testing
import Foundation
import CoreGraphics
@testable import Jumbini

// The pure, AppKit-free half of "Make Your Own Dog": filename mapping, sprite
// post-processing (48x48 RGBA, transparent background, closed dark outline),
// coat-folder writing, and the full pipeline run against a mock Pixellab client.
// None of it needs a network or a display, so it all runs against temp
// directories and synthetic PNGs.

// MARK: - Fixtures

/// Build an RGBA image directly and encode it as a PNG for feeding through
/// `DogGenerator.postProcess`.
private func makePNG(
    width: Int = 48,
    height: Int = 48,
    fill: (inout RGBAImage) -> Void
) -> Data {
    var image = RGBAImage(
        width: width, height: height,
        pixels: [UInt8](repeating: 0, count: width * height * 4)
    )
    fill(&image)
    return DogGenerator.pngData(from: image)!
}

/// A transparent canvas with a mid-grey square in the middle — a stand-in for
/// one generated sprite.
private func makeSpritePNG() -> Data {
    makePNG { image in
        for y in 12..<36 {
            for x in 12..<36 {
                let i = (y * image.width + x) * 4
                image.pixels[i] = 120
                image.pixels[i + 1] = 120
                image.pixels[i + 2] = 120
                image.pixels[i + 3] = 255
            }
        }
    }
}

/// A canvas filled with an opaque background colour and a dark square in the
/// middle — a stand-in for a Pixellab output that still has a background.
private func makeBackdroppedPNG(
    width: Int = 48,
    height: Int = 48,
    background: (UInt8, UInt8, UInt8) = (255, 255, 255)
) -> Data {
    makePNG(width: width, height: height) { image in
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                image.pixels[i] = background.0
                image.pixels[i + 1] = background.1
                image.pixels[i + 2] = background.2
                image.pixels[i + 3] = 255
            }
        }
        let lo = min(width, height) / 3
        let hi = min(width, height) * 2 / 3
        for y in lo..<hi {
            for x in lo..<hi {
                let i = (y * width + x) * 4
                image.pixels[i] = 0
                image.pixels[i + 1] = 0
                image.pixels[i + 2] = 0
                image.pixels[i + 3] = 255
            }
        }
    }
}

/// Decode a PNG back into its pixels for assertions.
private func decode(_ data: Data) -> RGBAImage {
    let image = DogGenerator.decode(data)!
    return DogGenerator.pixels(of: image)!
}

/// A Pixellab stand-in that returns canned sprites, so the pipeline can be
/// exercised without a network call.
private final class MockPixellabClient: PixellabClientProtocol {
    func createCharacter(referenceImage: Data) async throws -> GeneratedCharacter {
        var rotations: [Facing: Data] = [:]
        for facing in Facing.allCases {
            rotations[facing] = makeSpritePNG()
        }
        return GeneratedCharacter(id: "mock-character", rotations: rotations)
    }

    func animate(characterID: String, action: PixellabAction) async throws -> [Facing: [Data]] {
        var frames: [Facing: [Data]] = [:]
        for facing in Facing.allCases {
            frames[facing] = (0..<action.frameCount).map { _ in makeSpritePNG() }
        }
        return frames
    }
}

/// A scratch coats directory that cleans itself up.
private final class TempCoats {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jumbini-my-dog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Filename mapping

@Test func filenameIsStateUnderscoreDirection() {
    #expect(DogGenerator.filename(state: .idle, direction: .south) == "idle_south.png")
    #expect(DogGenerator.filename(state: .run1, direction: .northEast) == "run1_north-east.png")
    #expect(DogGenerator.filename(state: .sniff, direction: .southWest) == "sniff_south-west.png")
}

@Test func everyStateDirectionHasAUniqueFilename() {
    var names = Set<String>()
    for state in CoatState.allCases {
        for direction in Facing.allCases {
            let name = DogGenerator.filename(state: state, direction: direction)
            #expect(name == "\(state.rawValue)_\(direction.fileSuffix).png")
            names.insert(name)
        }
    }
    #expect(names.count == 56)  // 7 states x 8 directions, no collisions
}

// MARK: - Post-processing

@Test func postProcessResizesTo48x48() throws {
    let input = makeBackdroppedPNG(width: 96, height: 96)
    let output = decode(try DogGenerator.postProcess(input))
    #expect(output.width == 48)
    #expect(output.height == 48)
}

@Test func postProcessLeavesAClearTransparentBackground() throws {
    let input = makeBackdroppedPNG(background: (255, 255, 255))
    let output = decode(try DogGenerator.postProcess(input))
    // The four corners were background, so they must now be transparent.
    for (x, y) in [(0, 0), (47, 0), (0, 47), (47, 47)] {
        #expect(output.pixels[(y * 48 + x) * 4 + 3] == 0)
    }
    // The middle square survived as opaque art.
    let centre = (24 * 48 + 24) * 4
    #expect(output.pixels[centre + 3] == 255)
}

@Test func postProcessEnforcesAClosedDarkOutline() throws {
    let input = makeSpritePNG()  // transparent canvas, grey square, no outline
    let output = decode(try DogGenerator.postProcess(input))
    // Alpha is snapped hard: only fully transparent or fully opaque remain.
    for i in stride(from: 3, to: output.pixels.count, by: 4) {
        #expect(output.pixels[i] == 0 || output.pixels[i] == 255)
    }
    // Every opaque pixel that touches a transparent one must be dark (outline).
    let w = output.width, h = output.height
    func alpha(_ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, x < w, y >= 0, y < h else { return 0 }
        return output.pixels[(y * w + x) * 4 + 3]
    }
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            guard output.pixels[i + 3] != 0 else { continue }
            let touchesTransparent = alpha(x - 1, y) == 0 || alpha(x + 1, y) == 0
                || alpha(x, y - 1) == 0 || alpha(x, y + 1) == 0
            if touchesTransparent {
                let sum = Int(output.pixels[i]) + Int(output.pixels[i + 1]) + Int(output.pixels[i + 2])
                #expect(sum < 200, "edge pixel at (\(x),\(y)) is not a dark outline")
            }
        }
    }
}

// MARK: - Coat writing

@Test func writeCoatWritesAll56SpritesPlusManifest() throws {
    var sprites: [CoatState: [Facing: Data]] = [:]
    for state in CoatState.allCases {
        for direction in Facing.allCases {
            sprites[state, default: [:]][direction] = makeSpritePNG()
        }
    }

    let temp = TempCoats()
    let folder = try DogGenerator.writeCoat(sprites, to: temp.url.appendingPathComponent("my-dog"))

    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    let pngs = files.filter { $0.hasSuffix(".png") }
    #expect(pngs.count == 56)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("idle_south.png").path))
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("coat.json").path))

    let manifest = try String(contentsOf: folder.appendingPathComponent("coat.json"), encoding: .utf8)
    #expect(manifest.contains(#""name": "My Dog""#))
}

@Test func writeCoatReplacesAPreviousGeneration() throws {
    var sprites: [CoatState: [Facing: Data]] = [:]
    for state in CoatState.allCases {
        for direction in Facing.allCases {
            sprites[state, default: [:]][direction] = makeSpritePNG()
        }
    }

    let temp = TempCoats()
    let folder = temp.url.appendingPathComponent("my-dog")
    try DogGenerator.writeCoat(sprites, to: folder)
    // Drop a stale extra file, then regenerate: it must be swept away.
    FileManager.default.createFile(
        atPath: folder.appendingPathComponent("stalk_south.png").path, contents: Data()
    )
    try DogGenerator.writeCoat(sprites, to: folder)

    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    let pngs = files.filter { $0.hasSuffix(".png") }
    #expect(pngs.count == 56)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("stalk_south.png").path))
}

// MARK: - Integration (mock client -> coat on disk)

@Test func mockClientGeneratesACoatTheCatalogDiscovers() async throws {
    let temp = TempCoats()
    let folder = try await DogGenerator.generateAndWrite(
        photos: DogPhotos(front: Data(), side: Data(), back: Data()),
        client: MockPixellabClient(),
        coatsDirectory: temp.url
    )

    let coats = CoatCatalog.installed(coatsDirectory: temp.url)
    #expect(coats.map(\.id) == ["my-dog"])
    #expect(coats.first?.title == "My Dog")

    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(files.filter { $0.hasSuffix(".png") }.count == 56)
}

@Test func generateProducesEveryStateInEveryDirection() async throws {
    let sprites = try await DogGenerator.generate(
        photos: DogPhotos(front: Data(), side: Data(), back: Data()),
        client: MockPixellabClient()
    )

    #expect(sprites.count == CoatState.allCases.count)
    for state in CoatState.allCases {
        #expect(sprites[state]?.count == Facing.allCases.count, "\(state.rawValue) missing directions")
    }
    // Every sprite came out normalised to 48x48.
    for (_, directions) in sprites {
        for (_, data) in directions {
            let image = decode(data)
            #expect(image.width == 48 && image.height == 48)
        }
    }
}
