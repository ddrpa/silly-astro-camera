import CoreGraphics
import Foundation
import ImageIO
import simd

struct MoonAlbedo {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 1, height > 1 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let wrote = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard wrote else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    static func bundled() -> MoonAlbedo? {
        guard let url = Bundle.main.url(forResource: "MoonAlbedo", withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return MoonAlbedo(image: image)
    }

    func sample(u: Double, v: Double) -> SIMD3<Double> {
        var wrappedU = u.truncatingRemainder(dividingBy: 1)
        if wrappedU < 0 { wrappedU += 1 }
        let clampedV = SkyAngles.clamp(v, 0, 0.999999)
        let x = wrappedU * Double(width - 1)
        let y = clampedV * Double(height - 1)
        let x0 = Int(x)
        let y0 = Int(y)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = x - Double(x0)
        let ty = y - Double(y0)
        let c00 = rgb(x: x0, y: y0)
        let c10 = rgb(x: x1, y: y0)
        let c01 = rgb(x: x0, y: y1)
        let c11 = rgb(x: x1, y: y1)
        return (c00 * (1 - tx) + c10 * tx) * (1 - ty) + (c01 * (1 - tx) + c11 * tx) * ty
    }

    private func rgb(x: Int, y: Int) -> SIMD3<Double> {
        let index = (y * width + x) * 4
        return SIMD3(
            Double(pixels[index]) / 255,
            Double(pixels[index + 1]) / 255,
            Double(pixels[index + 2]) / 255
        )
    }
}

enum MoonImageRenderer {
    static func render(
        albedo: MoonAlbedo,
        phaseAngle: Double,
        brightLimbPositionAngle: Double,
        axisPositionAngle: Double,
        librationLongitude: Double,
        librationLatitude: Double,
        earthshine: Double = 0,
        size: Int
    ) -> CGImage? {
        guard size > 1 else { return nil }
        let relativeLimb = brightLimbPositionAngle - axisPositionAngle
        let sinePhase = sin(phaseAngle)
        let sun = simd_normalize(SIMD3<Double>(
            -sin(relativeLimb) * sinePhase,
            cos(relativeLimb) * sinePhase,
            cos(phaseAngle)
        ))
        let earthshineGain = max(earthshine, 0)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let center = Double(size - 1) / 2
        let radius = center
        for y in 0..<size {
            for x in 0..<size {
                let nx = (Double(x) - center) / radius
                let ny = (center - Double(y)) / radius
                let radiusSquared = nx * nx + ny * ny
                guard radiusSquared <= 1 else { continue }
                let nz = sqrt(1 - radiusSquared)
                let viewPoint = SIMD3<Double>(nx, ny, nz)
                let texturePoint = rotateX(rotateY(viewPoint, -librationLongitude), -librationLatitude)
                let longitude = atan2(texturePoint.x, texturePoint.z)
                let latitude = asin(SkyAngles.clamp(texturePoint.y, -1, 1))
                let color = albedo.sample(
                    u: 0.5 + longitude / (2 * .pi),
                    v: 0.5 - latitude / .pi
                )
                let light = max(0, simd_dot(viewPoint, sun))
                let radial = sqrt(radiusSquared)
                let fade = radial < 0.985 ? 1 : max(0, (1 - radial) / 0.015)
                let cover = smoothstep(0, 0.05, light)
                let earth = 0.12 * nz * earthshineGain
                let sunAlpha = fade * cover
                let earthAlpha = fade * earth * (1 - cover)
                let alpha = sunAlpha + earthAlpha
                let shade = light * sunAlpha + earthAlpha
                let index = (y * size + x) * 4
                pixels[index] = UInt8(SkyAngles.clamp(color.x * shade, 0, 1) * 255)
                pixels[index + 1] = UInt8(SkyAngles.clamp(color.y * shade, 0, 1) * 255)
                pixels[index + 2] = UInt8(SkyAngles.clamp(color.z * shade, 0, 1) * 255)
                pixels[index + 3] = UInt8(SkyAngles.clamp(alpha, 0, 1) * 255)
            }
        }
        return image(from: pixels, size: size)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = SkyAngles.clamp((value - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    private static func rotateY(_ point: SIMD3<Double>, _ angle: Double) -> SIMD3<Double> {
        let cosine = cos(angle)
        let sine = sin(angle)
        return SIMD3(cosine * point.x + sine * point.z, point.y, -sine * point.x + cosine * point.z)
    }

    private static func rotateX(_ point: SIMD3<Double>, _ angle: Double) -> SIMD3<Double> {
        let cosine = cos(angle)
        let sine = sin(angle)
        return SIMD3(point.x, cosine * point.y - sine * point.z, sine * point.y + cosine * point.z)
    }

    private static func image(from pixels: [UInt8], size: Int) -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
