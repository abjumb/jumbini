import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum SheetError: Error, Equatable {
    case noFrames
    case missingArt(String)
    case cannotWrite(String)
    case cannotDecode(String)
}

enum SheetBuilder {
    /// A horizontal strip of uniform cells, which is what CSS `steps()`
    /// expects: cell width is the widest frame, so every step advances by the
    /// same distance and the dog doesn't slide around inside his own box.
    /// Frames are centred horizontally and sit on a common baseline, because
    /// the art is not all the same size — sit was exported at 38px where idle
    /// is 46px.
    static func sheet(from frames: [CGImage], scale: CGFloat) throws -> CGImage {
        guard !frames.isEmpty else { throw SheetError.noFrames }

        let cellWidth = Int((CGFloat(frames.map(\.width).max()!) * scale).rounded())
        let cellHeight = Int((CGFloat(frames.map(\.height).max()!) * scale).rounded())

        let context = try makeContext(width: cellWidth * frames.count, height: cellHeight)
        // Nearest-neighbour: this is pixel art, and smoothing turns it to mush.
        context.interpolationQuality = .none

        for (index, frame) in frames.enumerated() {
            let width = CGFloat(frame.width) * scale
            let height = CGFloat(frame.height) * scale
            let x = CGFloat(index * cellWidth) + (CGFloat(cellWidth) - width) / 2
            context.draw(frame, in: CGRect(x: x, y: 0, width: width, height: height))
        }

        guard let image = context.makeImage() else {
            throw SheetError.cannotWrite("sheet")
        }
        return image
    }

    /// A grid, for the eight-rotation contact sheet that shows the art off.
    static func contactSheet(from frames: [CGImage], columns: Int, scale: CGFloat) throws -> CGImage {
        guard !frames.isEmpty else { throw SheetError.noFrames }

        let cellWidth = Int((CGFloat(frames.map(\.width).max()!) * scale).rounded())
        let cellHeight = Int((CGFloat(frames.map(\.height).max()!) * scale).rounded())
        let rows = Int(ceil(Double(frames.count) / Double(columns)))

        let context = try makeContext(width: cellWidth * columns, height: cellHeight * rows)
        context.interpolationQuality = .none

        for (index, frame) in frames.enumerated() {
            let column = index % columns
            // CoreGraphics is bottom-up; fill the grid top-down so the
            // directions read in the order a human expects.
            let row = rows - 1 - (index / columns)
            let width = CGFloat(frame.width) * scale
            let height = CGFloat(frame.height) * scale
            let x = CGFloat(column * cellWidth) + (CGFloat(cellWidth) - width) / 2
            let y = CGFloat(row * cellHeight)
            context.draw(frame, in: CGRect(x: x, y: y, width: width, height: height))
        }

        guard let image = context.makeImage() else {
            throw SheetError.cannotWrite("contact sheet")
        }
        return image
    }

    private static func makeContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SheetError.cannotWrite("\(width)x\(height)")
        }
        return context
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SheetError.missingArt(url.lastPathComponent)
        }
        return image
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw SheetError.cannotWrite(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SheetError.cannotWrite(url.path)
        }
    }
}
