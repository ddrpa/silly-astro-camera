import CoreGraphics
import Foundation

enum MoonCompositor {
    static func composite(
        base: CGImage,
        sprite: CGImage,
        center: CGPoint,
        pixelRadius: CGFloat,
        rotation: CGFloat
    ) -> CGImage? {
        let width = base.width
        let height = base.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .none
        context.draw(base, in: bounds)
        let diameter = pixelRadius * 2
        context.saveGState()
        context.translateBy(x: center.x, y: CGFloat(height) - center.y)
        context.rotate(by: -rotation)
        context.draw(
            sprite,
            in: CGRect(x: -diameter / 2, y: diameter / 2, width: diameter, height: -diameter)
        )
        context.restoreGState()
        return context.makeImage()
    }
}
