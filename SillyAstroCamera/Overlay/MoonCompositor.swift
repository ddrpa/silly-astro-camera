import CoreGraphics
import Foundation

struct MoonChannelImages {
    var red: CGImage
    var green: CGImage
    var blue: CGImage
}

enum MoonCompositor {
    static func composite(
        base: CGImage,
        sprite: CGImage,
        center: CGPoint,
        pixelRadius: CGFloat,
        rotation: CGFloat,
        verticalScale: CGFloat = 1,
        zenithRotation: CGFloat = 0,
        tint: MoonTint = .neutral,
        redDispersion: CGFloat = 0,
        blueDispersion: CGFloat = 0
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
        let centerCG = CGPoint(x: center.x, y: CGFloat(height) - center.y)
        let identity = abs(verticalScale - 1) < 1e-6
            && abs(zenithRotation) < 1e-6
            && abs(redDispersion) < 1e-4
            && abs(blueDispersion) < 1e-4
            && tint == .neutral
        if identity {
            drawSprite(
                in: context,
                sprite: sprite,
                center: centerCG,
                pixelRadius: pixelRadius,
                rotation: rotation,
                verticalScale: 1,
                zenithRotation: 0,
                altitudeShift: 0
            )
            return context.makeImage()
        }
        guard let moon = dispersedMoon(
            sprite: sprite,
            pixelRadius: pixelRadius,
            rotation: rotation,
            verticalScale: verticalScale,
            zenithRotation: zenithRotation,
            tint: tint,
            redDispersion: redDispersion,
            blueDispersion: blueDispersion
        ) else { return nil }
        context.draw(moon.image, in: moon.rect.offsetBy(dx: centerCG.x, dy: centerCG.y))
        return context.makeImage()
    }

    static func channelImages(sprite: CGImage, tint: MoonTint) -> MoonChannelImages? {
        let width = sprite.width
        let height = sprite.height
        guard width > 0, height > 0,
              sprite.bitsPerPixel == 32,
              sprite.bitsPerComponent == 8,
              let data = sprite.dataProvider?.data,
              CFDataGetLength(data) >= height * sprite.bytesPerRow,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let rowBytes = sprite.bytesPerRow
        let count = width * height * 4
        var redPixels = [UInt8](repeating: 0, count: count)
        var greenPixels = [UInt8](repeating: 0, count: count)
        var bluePixels = [UInt8](repeating: 0, count: count)
        let redGain = max(tint.red, 0)
        let greenGain = max(tint.green, 0)
        let blueGain = max(tint.blue, 0)
        for y in 0..<height {
            for x in 0..<width {
                let source = y * rowBytes + x * 4
                let destination = (y * width + x) * 4
                let alpha = Int(bytes[source + 3])
                redPixels[destination + 3] = bytes[source + 3]
                greenPixels[destination + 3] = bytes[source + 3]
                bluePixels[destination + 3] = bytes[source + 3]
                guard alpha > 0 else { continue }
                redPixels[destination] = scaledComponent(bytes[source], gain: redGain, alpha: alpha)
                greenPixels[destination + 1] = scaledComponent(bytes[source + 1], gain: greenGain, alpha: alpha)
                bluePixels[destination + 2] = scaledComponent(bytes[source + 2], gain: blueGain, alpha: alpha)
            }
        }
        guard let red = image(pixels: redPixels, width: width, height: height),
              let green = image(pixels: greenPixels, width: width, height: height),
              let blue = image(pixels: bluePixels, width: width, height: height) else { return nil }
        return MoonChannelImages(red: red, green: green, blue: blue)
    }

    private static func drawSprite(
        in context: CGContext,
        sprite: CGImage,
        center: CGPoint,
        pixelRadius: CGFloat,
        rotation: CGFloat,
        verticalScale: CGFloat,
        zenithRotation: CGFloat,
        altitudeShift: CGFloat
    ) {
        let diameter = pixelRadius * 2
        let scale = verticalScale.isFinite && verticalScale > 0 ? verticalScale : 1
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.translateBy(
            x: sin(zenithRotation) * altitudeShift,
            y: cos(zenithRotation) * altitudeShift
        )
        context.rotate(by: -zenithRotation)
        context.scaleBy(x: 1, y: scale)
        context.rotate(by: -(rotation - zenithRotation))
        context.draw(
            sprite,
            in: CGRect(x: -diameter / 2, y: diameter / 2, width: diameter, height: -diameter)
        )
        context.restoreGState()
    }

    private static func dispersedMoon(
        sprite: CGImage,
        pixelRadius: CGFloat,
        rotation: CGFloat,
        verticalScale: CGFloat,
        zenithRotation: CGFloat,
        tint: MoonTint,
        redDispersion: CGFloat,
        blueDispersion: CGFloat
    ) -> (image: CGImage, rect: CGRect)? {
        let scale = verticalScale.isFinite && verticalScale > 0 ? verticalScale : 1
        let pad = ceil(max(abs(redDispersion), abs(blueDispersion))) + 2
        let halfWidth = pixelRadius
        let halfHeight = pixelRadius * scale
        let cosine = abs(cos(zenithRotation))
        let sine = abs(sin(zenithRotation))
        let boxWidth = max(1, Int(ceil((halfWidth * cosine + halfHeight * sine + pad) * 2)))
        let boxHeight = max(1, Int(ceil((halfWidth * sine + halfHeight * cosine + pad) * 2)))
        let shifts = [redDispersion, 0, blueDispersion]
        let buffers = shifts.compactMap { shift in
            renderChannel(
                sprite: sprite,
                boxWidth: boxWidth,
                boxHeight: boxHeight,
                pixelRadius: pixelRadius,
                rotation: rotation,
                verticalScale: scale,
                zenithRotation: zenithRotation,
                altitudeShift: shift
            )
        }
        guard buffers.count == 3 else { return nil }
        var pixels = [UInt8](repeating: 0, count: boxWidth * boxHeight * 4)
        let redGain = max(tint.red, 0)
        let greenGain = max(tint.green, 0)
        let blueGain = max(tint.blue, 0)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(max(buffers[0][index + 3], buffers[1][index + 3], buffers[2][index + 3]))
            guard alpha > 0 else { continue }
            pixels[index] = UInt8(min(alpha, Int((Double(buffers[0][index]) * redGain).rounded())))
            pixels[index + 1] = UInt8(min(alpha, Int((Double(buffers[1][index + 1]) * greenGain).rounded())))
            pixels[index + 2] = UInt8(min(alpha, Int((Double(buffers[2][index + 2]) * blueGain).rounded())))
            pixels[index + 3] = UInt8(alpha)
        }
        guard let image = image(pixels: pixels, width: boxWidth, height: boxHeight) else { return nil }
        return (
            image,
            CGRect(
                x: -CGFloat(boxWidth) / 2,
                y: -CGFloat(boxHeight) / 2,
                width: CGFloat(boxWidth),
                height: CGFloat(boxHeight)
            )
        )
    }

    private static func renderChannel(
        sprite: CGImage,
        boxWidth: Int,
        boxHeight: Int,
        pixelRadius: CGFloat,
        rotation: CGFloat,
        verticalScale: CGFloat,
        zenithRotation: CGFloat,
        altitudeShift: CGFloat
    ) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: boxWidth * boxHeight * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: boxWidth,
                height: boxHeight,
                bitsPerComponent: 8,
                bytesPerRow: boxWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            drawSprite(
                in: context,
                sprite: sprite,
                center: CGPoint(x: CGFloat(boxWidth) / 2, y: CGFloat(boxHeight) / 2),
                pixelRadius: pixelRadius,
                rotation: rotation,
                verticalScale: verticalScale,
                zenithRotation: zenithRotation,
                altitudeShift: altitudeShift
            )
            return true
        }
        return drew ? pixels : nil
    }

    private static func scaledComponent(_ component: UInt8, gain: Double, alpha: Int) -> UInt8 {
        let scaled = min(Double(alpha), max(0, (Double(component) * gain).rounded()))
        return UInt8(scaled)
    }

    private static func image(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
