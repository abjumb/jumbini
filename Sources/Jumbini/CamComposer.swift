import AppKit
import CoreGraphics

/// Composes the Jumbini Cam picture: the dog, a captioned plate under him, and
/// a paw in the corner, on a transparent canvas.
///
/// Pure Core Graphics. Nothing here reaches into the scene — it is handed a
/// rendered dog and a date and hands back an image — which is what lets the
/// whole layout be reasoned about (and one day tested) without a running scene,
/// an SKView, or a window on screen.
enum CamComposer {
    /// Device pixels per scene point in the composed cam image: 2x keeps the
    /// pixel art crisp on retina displays.
    static let scale: CGFloat = 2

    /// "Jumbini, 3:42 PM" — real current time, localized short style.
    static func caption(for date: Date) -> String {
        "Jumbini, \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// Rounded system font for the caption (Menlo, then plain system, as
    /// fallbacks). `pixelSize` is in device pixels — all cam composition
    /// happens in pixel space.
    static func captionFont(pixelSize: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: pixelSize, weight: .semibold)
        if let rounded = system.fontDescriptor.withDesign(.rounded),
           let font = NSFont(descriptor: rounded, size: pixelSize) {
            return font
        }
        return NSFont(name: "Menlo", size: pixelSize) ?? system
    }

    /// Compose dog-above-caption on a transparent canvas. Everything is laid
    /// out in device pixels (points x `scale`) with nearest-neighbor
    /// sampling so the pixel art never picks up a smoothing blur; the caption
    /// sits on the kit's plate, white with a 1px dark outline so it reads
    /// whatever the plate is doing underneath.
    static func compose(
        dogImage: CGImage, dogPointSize: CGSize, date: Date
    ) -> NSImage? {
        let scale = Self.scale
        let pad = 12 * scale
        let gap = 8 * scale
        let outlineColor = NSColor(white: 0.08, alpha: 0.9)

        let font = captionFont(pixelSize: 13 * scale)
        let text = caption(for: date)
        let captionFace = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.white]
        )
        let captionOutline = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: outlineColor]
        )
        let textSize = captionFace.size()

        // The caption rides on the kit's plate — a rounded pixel slab, wider
        // than the text by a margin on each side. It replaces the bare
        // outlined text, and the SF Symbol paw that used to sit in front of
        // it: there's a hand-drawn paw in the corner now instead.
        let plate = sprite(named: "caption_plate")
        let platePadX = 11 * scale
        let platePadY = 7 * scale
        let plateSize = CGSize(
            width: textSize.width.rounded(.up) + platePadX * 2,
            height: textSize.height.rounded(.up) + platePadY * 2
        )
        let captionHeight = plate == nil ? textSize.height.rounded(.up) : plateSize.height

        let dogPixelSize = CGSize(
            width: (dogPointSize.width * scale).rounded(),
            height: (dogPointSize.height * scale).rounded()
        )
        let contentWidth = max(dogPixelSize.width, plate == nil ? textSize.width.rounded(.up) : plateSize.width)
        let canvasWidth = Int((contentWidth + pad * 2).rounded(.up))
        let canvasHeight = Int((pad + captionHeight + gap + dogPixelSize.height + pad).rounded(.up))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: canvasWidth, height: canvasHeight,
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .none // nearest-neighbor for the pixel art
        context.setShouldSmoothFonts(false)  // no subpixel fringing on transparency

        // The dog, centered, above the caption line.
        let dogRect = CGRect(
            x: ((CGFloat(canvasWidth) - dogPixelSize.width) / 2).rounded(),
            y: (pad + captionHeight + gap).rounded(),
            width: dogPixelSize.width, height: dogPixelSize.height
        )
        context.draw(dogImage, in: dogRect)

        // Caption row, centered under the dog: plate first, text on top.
        if let plate {
            let plateRect = CGRect(
                x: ((CGFloat(canvasWidth) - plateSize.width) / 2).rounded(), y: pad,
                width: plateSize.width, height: plateSize.height
            )
            drawPlate(plate, in: plateRect, corner: 9 * scale, context: context)
        }
        let textOrigin = CGPoint(
            x: ((CGFloat(canvasWidth) - textSize.width) / 2).rounded(),
            y: (pad + (captionHeight - textSize.height) / 2).rounded()
        )
        let appKitContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = appKitContext
        for dx: CGFloat in [-1, 0, 1] {
            for dy: CGFloat in [-1, 0, 1] where !(dx == 0 && dy == 0) {
                captionOutline.draw(at: CGPoint(x: textOrigin.x + dx, y: textOrigin.y + dy))
            }
        }
        captionFace.draw(at: textOrigin)
        NSGraphicsContext.restoreGraphicsState()

        // Signed top-right, at half strength — a maker's mark, not a sticker.
        // Top rather than bottom: the caption plate is as wide as the canvas
        // allows down there, and the corner beside his ears is always empty.
        if let paw = sprite(named: "paw_watermark") {
            let side = 16 * scale
            context.saveGState()
            context.setAlpha(0.55)
            context.draw(paw, in: CGRect(
                x: CGFloat(canvasWidth) - side - pad / 2,
                y: CGFloat(canvasHeight) - side - pad / 2,
                width: side, height: side
            ))
            context.restoreGState()
        }

        guard let composed = context.makeImage() else { return nil }
        // Point size = pixels / scale, so the image self-reports as retina
        // (2x) content on the pasteboard.
        return NSImage(
            cgImage: composed,
            size: NSSize(width: CGFloat(canvasWidth) / scale, height: CGFloat(canvasHeight) / scale)
        )
    }

    /// A sprite from Resources/sprites as a CGImage. The cam composes
    /// offscreen in Core Graphics, where an SKTexture is no use.
    private static func sprite(named name: String) -> CGImage? {
        guard let url = Bundle.assets.url(forResource: name, withExtension: "png", subdirectory: "sprites"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Stretch a small square plate across `rect` as a nine-slice: the four
    /// corners keep their size, the edges stretch along one axis, the middle
    /// fills the rest. Scaling the whole 48x48 plate to a caption-shaped
    /// oblong instead would smear its border and flatten its corners.
    ///
    /// Source rows/columns run top-down (`cropping(to:)` is in image space);
    /// destination rows are laid out from the top edge down, because the
    /// context's y grows upwards.
    private static func drawPlate(
        _ plate: CGImage, in rect: CGRect, corner: CGFloat, context: CGContext
    ) {
        let sw = CGFloat(plate.width), sh = CGFloat(plate.height)
        // A quarter of the plate per corner: enough to carry the border and
        // the rounding, and it leaves a middle band to stretch.
        let slice = (min(sw, sh) / 4).rounded()
        let cornerW = min(corner.rounded(), (rect.width / 2).rounded())
        let cornerH = min(corner.rounded(), (rect.height / 2).rounded())
        let columns: [(sx: CGFloat, sw: CGFloat, dx: CGFloat, dw: CGFloat)] = [
            (0, slice, rect.minX, cornerW),
            (slice, sw - slice * 2, rect.minX + cornerW, rect.width - cornerW * 2),
            (sw - slice, slice, rect.maxX - cornerW, cornerW),
        ]
        let rows: [(sy: CGFloat, sh: CGFloat, top: CGFloat, dh: CGFloat)] = [
            (0, slice, rect.maxY, cornerH),
            (slice, sh - slice * 2, rect.maxY - cornerH, rect.height - cornerH * 2),
            (sh - slice, slice, rect.minY + cornerH, cornerH),
        ]
        for row in rows where row.dh > 0 && row.sh > 0 {
            for column in columns where column.dw > 0 && column.sw > 0 {
                guard let piece = plate.cropping(to: CGRect(
                    x: column.sx, y: row.sy, width: column.sw, height: row.sh
                )) else { continue }
                context.draw(piece, in: CGRect(
                    x: column.dx, y: row.top - row.dh, width: column.dw, height: row.dh
                ))
            }
        }
    }
}
