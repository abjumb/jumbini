import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import spritefilm

// A sprite sheet is driven by CSS `steps()`, which assumes every cell is
// exactly the same width and that they are laid out left to right with no
// padding. Get either wrong and the dog jitters horizontally as he walks.

private func solidImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Test func sheetWidthIsCellWidthTimesFrameCount() throws {
    let frames = [solidImage(width: 48, height: 48), solidImage(width: 48, height: 48)]
    let sheet = try SheetBuilder.sheet(from: frames, scale: 1)
    #expect(sheet.width == 96)
    #expect(sheet.height == 48)
}

// Frames are not all the same size on disk — sit was exported at 38px where
// idle is 46px. Cells must still be uniform or steps() drifts.
@Test func unevenFramesArePaddedIntoUniformCells() throws {
    let frames = [solidImage(width: 40, height: 30), solidImage(width: 48, height: 48)]
    let sheet = try SheetBuilder.sheet(from: frames, scale: 1)
    #expect(sheet.width == 96)
    #expect(sheet.height == 48)
}

@Test func scaleMultipliesEveryCell() throws {
    let frames = [solidImage(width: 48, height: 48)]
    let sheet = try SheetBuilder.sheet(from: frames, scale: 2)
    #expect(sheet.width == 96)
    #expect(sheet.height == 96)
}

@Test func theSheetKeepsItsAlphaChannel() throws {
    let frames = [solidImage(width: 48, height: 48)]
    let sheet = try SheetBuilder.sheet(from: frames, scale: 1)
    // Spell the enum out — a bare `.none` here resolves against Optional.
    #expect(sheet.alphaInfo != CGImageAlphaInfo.none)
    #expect(sheet.alphaInfo != CGImageAlphaInfo.noneSkipLast)
}

@Test func anEmptyFrameListIsAnError() {
    #expect(throws: SheetError.noFrames) {
        _ = try SheetBuilder.sheet(from: [], scale: 1)
    }
}

@Test func contactSheetLaysOutAGrid() throws {
    let frames = (0..<8).map { _ in solidImage(width: 48, height: 48) }
    let contact = try SheetBuilder.contactSheet(from: frames, columns: 4, scale: 1)
    #expect(contact.width == 192)
    #expect(contact.height == 96)
}
