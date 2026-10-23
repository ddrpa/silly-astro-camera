import CoreGraphics
import CoreVideo
import Foundation

struct ApparentDisk: Equatable {
    var center: CGPoint
    var radius: CGFloat
}

enum SceneMetering {
    static func previewRectangle(moonCenter: CGPoint?, previewSize: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: previewSize)
        guard let moonCenter, previewSize.width > 1, previewSize.height > 1 else { return full }
        let band = max(previewSize.height * 0.35, 1)
        if moonCenter.y < previewSize.height / 2 {
            return CGRect(x: 0, y: previewSize.height - band, width: previewSize.width, height: band)
        }
        return CGRect(x: 0, y: 0, width: previewSize.width, height: band)
    }

    static func clampedDeviceRect(from corners: [CGPoint], minimumSize: CGSize) -> CGRect {
        guard let minX0 = corners.map(\.x).min(),
              let maxX0 = corners.map(\.x).max(),
              let minY0 = corners.map(\.y).min(),
              let maxY0 = corners.map(\.y).max() else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        var width = max(0, maxX0 - minX0)
        var height = max(0, maxY0 - minY0)
        var minX = minX0
        var minY = minY0
        let minWidth = min(1, max(0, minimumSize.width))
        let minHeight = min(1, max(0, minimumSize.height))
        if width < minWidth {
            minX -= (minWidth - width) / 2
            width = minWidth
        }
        if height < minHeight {
            minY -= (minHeight - height) / 2
            height = minHeight
        }
        width = min(width, 1)
        height = min(height, 1)
        minX = min(max(0, minX), 1 - width)
        minY = min(max(0, minY), 1 - height)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }
}

struct CoverFill: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    static let black = CoverFill(red: 0, green: 0, blue: 0)
}

struct CoverMeasurement: Equatable {
    var disk: ApparentDisk?
    var fill: CoverFill
}

struct CoverTarget {
    var geometricCenter: CGPoint
    var geometricRadius: CGFloat
    var searchCenter: CGPoint
    var searchRadius: CGFloat
    var preferenceCenter: CGPoint?
    var previewSize: CGSize
    var acquire: Bool
    var sampleColor: Bool = true
}

struct GlowCover: Equatable {
    var fill: CoverFill
    var outerRadius: CGFloat
    var feather: CGFloat
}

enum MoonCover {
    static let radiusMargin: CGFloat = 1.05
    static let maxRadiusScale: CGFloat = 4
    static let minRadiusScale: CGFloat = 0.25
    static let smoothResponse: CGFloat = 0.35
    static let annulusInnerScale: CGFloat = 1.3
    static let annulusOuterScale: CGFloat = 2.8
    static let trackingSearchDegrees = 8.0
    static let glowRadiusCap: CGFloat = 16
    private static let glowRingCount = 48
    private static let glowSamplesPerRing = 36

    static func shouldPublishTrackingTarget(previous: CGPoint?, center: CGPoint) -> Bool {
        guard let previous else { return true }
        return hypot(center.x - previous.x, center.y - previous.y) >= 1
    }

    static func measure(
        luminance: [UInt8],
        width: Int,
        height: Int,
        geometricCenter: CGPoint,
        geometricRadius: CGFloat,
        searchCenter: CGPoint? = nil,
        searchRadius: CGFloat? = nil,
        red: [UInt8]? = nil,
        green: [UInt8]? = nil,
        blue: [UInt8]? = nil,
        preferenceCenter: CGPoint? = nil,
        acquire: Bool = true
    ) -> CoverMeasurement {
        let empty = CoverMeasurement(disk: nil, fill: .black)
        guard width > 1, height > 1, luminance.count >= width * height, geometricRadius > 0 else { return empty }
        let origin = searchCenter ?? geometricCenter
        let windowRadius = max(searchRadius ?? max(geometricRadius * maxRadiusScale, 8), 1)
        let disk = acquire
            ? selectDisk(
                luminance: luminance,
                width: width,
                height: height,
                geometricRadius: geometricRadius,
                searchCenter: origin,
                windowRadius: windowRadius,
                preferenceCenter: preferenceCenter
            )
            : nil
        let fillCenter = disk?.center ?? origin
        let fillRadius = disk?.radius ?? geometricRadius
        let fill = backgroundFill(
            red: red,
            green: green,
            blue: blue,
            luminance: luminance,
            width: width,
            height: height,
            center: fillCenter,
            radius: fillRadius
        )
        return CoverMeasurement(disk: disk, fill: fill)
    }

    private static func selectDisk(
        luminance: [UInt8],
        width: Int,
        height: Int,
        geometricRadius: CGFloat,
        searchCenter: CGPoint,
        windowRadius: CGFloat,
        preferenceCenter: CGPoint?
    ) -> ApparentDisk? {
        let capRadius = geometricRadius * maxRadiusScale
        let minRadius = geometricRadius * minRadiusScale
        var samples: [UInt8] = []
        samples.reserveCapacity(256)
        var windowCount = 0
        let minX = max(0, Int(floor(searchCenter.x - windowRadius)))
        let maxX = min(width - 1, Int(ceil(searchCenter.x + windowRadius)))
        let minY = max(0, Int(floor(searchCenter.y - windowRadius)))
        let maxY = min(height - 1, Int(ceil(searchCenter.y + windowRadius)))
        guard maxX >= minX, maxY >= minY else { return nil }
        let windowSquared = windowRadius * windowRadius
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = CGFloat(x) - searchCenter.x
                let dy = CGFloat(y) - searchCenter.y
                guard dx * dx + dy * dy <= windowSquared else { continue }
                windowCount += 1
                samples.append(luminance[y * width + x])
            }
        }
        guard windowCount > 0, !samples.isEmpty else { return nil }
        samples.sort()
        let background = Int(samples[samples.count / 5])
        let peak = Int(samples[samples.count - 1])
        let threshold = max(80, background + max(36, (peak - background) / 4))
        guard peak > threshold else { return nil }

        var bright = [Bool](repeating: false, count: width * height)
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = CGFloat(x) - searchCenter.x
                let dy = CGFloat(y) - searchCenter.y
                guard dx * dx + dy * dy <= windowSquared else { continue }
                let index = y * width + x
                bright[index] = Int(luminance[index]) > threshold
            }
        }

        var seen = [Bool](repeating: false, count: width * height)
        let reference = preferenceCenter ?? searchCenter
        var best: (center: CGPoint, radius: CGFloat, weight: CGFloat)?
        for y in minY...maxY {
            for x in minX...maxX {
                let index = y * width + x
                guard bright[index], !seen[index] else { continue }
                var stack = [index]
                seen[index] = true
                var component: [Int] = []
                while let current = stack.popLast() {
                    component.append(current)
                    let cx = current % width
                    let cy = current / width
                    let neighbors = [
                        (cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1),
                        (cx - 1, cy - 1), (cx + 1, cy - 1), (cx - 1, cy + 1), (cx + 1, cy + 1),
                    ]
                    for (nx, ny) in neighbors {
                        guard nx >= minX, nx <= maxX, ny >= minY, ny <= maxY else { continue }
                        let next = ny * width + nx
                        guard bright[next], !seen[next] else { continue }
                        let dx = CGFloat(nx) - searchCenter.x
                        let dy = CGFloat(ny) - searchCenter.y
                        guard dx * dx + dy * dy <= windowSquared else { continue }
                        seen[next] = true
                        stack.append(next)
                    }
                }
                guard !component.isEmpty else { continue }
                if CGFloat(component.count) > CGFloat(windowCount) * 0.6 { continue }
                var sumX = 0.0
                var sumY = 0.0
                for pixel in component {
                    sumX += Double(pixel % width)
                    sumY += Double(pixel / width)
                }
                let count = Double(component.count)
                let centroid = CGPoint(x: sumX / count, y: sumY / count)
                var farthest: CGFloat = 0
                for pixel in component {
                    farthest = max(farthest, hypot(CGFloat(pixel % width) - centroid.x, CGFloat(pixel / width) - centroid.y))
                }
                let enclosing = farthest * radiusMargin
                guard enclosing >= minRadius, enclosing <= capRadius else { continue }
                let distance = hypot(centroid.x - reference.x, centroid.y - reference.y)
                let weight = candidateWeight(distance: distance, geometricRadius: geometricRadius)
                if best == nil || weight > best!.weight {
                    best = (
                        centroid,
                        min(capRadius, max(geometricRadius, enclosing)),
                        weight
                    )
                }
            }
        }
        guard let best else { return nil }
        return ApparentDisk(center: best.center, radius: best.radius)
    }

    static func candidateWeight(distance: CGFloat, geometricRadius: CGFloat) -> CGFloat {
        let scale = max(geometricRadius, 1)
        return 1 / (1 + max(0, distance) / scale)
    }

    private static func backgroundFill(
        red: [UInt8]?,
        green: [UInt8]?,
        blue: [UInt8]?,
        luminance: [UInt8],
        width: Int,
        height: Int,
        center: CGPoint,
        radius: CGFloat
    ) -> CoverFill {
        guard let red, let green, let blue,
              red.count >= width * height,
              green.count == red.count,
              blue.count == red.count,
              radius > 0 else { return .black }
        let inner = radius * annulusInnerScale
        let outer = radius * annulusOuterScale
        let innerSquared = inner * inner
        let outerSquared = outer * outer
        let minX = max(0, Int(floor(center.x - outer)))
        let maxX = min(width - 1, Int(ceil(center.x + outer)))
        let minY = max(0, Int(floor(center.y - outer)))
        let maxY = min(height - 1, Int(ceil(center.y + outer)))
        guard maxX >= minX, maxY >= minY else { return .black }
        var samples: [(luminance: UInt8, red: UInt8, green: UInt8, blue: UInt8)] = []
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = CGFloat(x) - center.x
                let dy = CGFloat(y) - center.y
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared >= innerSquared, distanceSquared <= outerSquared else { continue }
                let index = y * width + x
                guard index < luminance.count else { continue }
                samples.append((luminance[index], red[index], green[index], blue[index]))
            }
        }
        guard !samples.isEmpty else { return .black }
        samples.sort { $0.luminance < $1.luminance }
        let darker = Array(samples.prefix(max(1, samples.count / 2)))
        return CoverFill(
            red: median(darker.map(\.red)),
            green: median(darker.map(\.green)),
            blue: median(darker.map(\.blue))
        )
    }

    private static func median(_ values: [UInt8]) -> CGFloat {
        let sorted = values.sorted()
        let count = sorted.count
        guard count > 0 else { return 0 }
        if count % 2 == 1 {
            return CGFloat(sorted[count / 2]) / 255
        }
        let sum = Int(sorted[count / 2 - 1]) + Int(sorted[count / 2])
        return CGFloat(sum) / 510
    }

    static func smooth(previous: ApparentDisk?, measured: ApparentDisk?) -> ApparentDisk? {
        guard let measured else { return nil }
        guard let previous else { return measured }
        let response = min(1, max(0, smoothResponse))
        return ApparentDisk(
            center: CGPoint(
                x: previous.center.x + (measured.center.x - previous.center.x) * response,
                y: previous.center.y + (measured.center.y - previous.center.y) * response
            ),
            radius: previous.radius + (measured.radius - previous.radius) * response
        )
    }

    static func measure(pixelBuffer: CVPixelBuffer, target: CoverTarget) -> CoverMeasurement? {
        guard target.previewSize.width > 1, target.previewSize.height > 1, target.geometricRadius > 0 else { return nil }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard bufferWidth > 1, bufferHeight > 1 else { return nil }
        let bufferAspect = CGFloat(bufferWidth) / CGFloat(bufferHeight)
        let previewAspect = target.previewSize.width / target.previewSize.height
        guard abs(bufferAspect - previewAspect) < 0.08 else { return nil }
        let scaleX = CGFloat(bufferWidth) / target.previewSize.width
        let scaleY = CGFloat(bufferHeight) / target.previewSize.height
        let stride = max(1, max(bufferWidth, bufferHeight) / 96)
        let sampleWidth = (bufferWidth + stride - 1) / stride
        let sampleHeight = (bufferHeight + stride - 1) / stride
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard bytesPerRow >= bufferWidth * 4 else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let count = sampleWidth * sampleHeight
        let sampleColor = target.sampleColor
        var red = sampleColor ? [UInt8](repeating: 0, count: count) : []
        var green = sampleColor ? [UInt8](repeating: 0, count: count) : []
        var blue = sampleColor ? [UInt8](repeating: 0, count: count) : []
        var luminance = [UInt8](repeating: 0, count: count)
        for y in 0..<sampleHeight {
            let row = min(bufferHeight - 1, y * stride)
            let rowStart = row * bytesPerRow
            for x in 0..<sampleWidth {
                let column = min(bufferWidth - 1, x * stride)
                let index = rowStart + column * 4
                let sample = y * sampleWidth + x
                let blueValue = pixels[index]
                let greenValue = pixels[index + 1]
                let redValue = pixels[index + 2]
                if sampleColor {
                    blue[sample] = blueValue
                    green[sample] = greenValue
                    red[sample] = redValue
                }
                luminance[sample] = UInt8((Int(redValue) + Int(greenValue) + Int(blueValue)) / 3)
            }
        }
        let sampleScale = (scaleX + scaleY) / (2 * CGFloat(stride))
        func samplePoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scaleX / CGFloat(stride), y: point.y * scaleY / CGFloat(stride))
        }
        let measurement = measure(
            luminance: luminance,
            width: sampleWidth,
            height: sampleHeight,
            geometricCenter: samplePoint(target.geometricCenter),
            geometricRadius: target.geometricRadius * sampleScale,
            searchCenter: samplePoint(target.searchCenter),
            searchRadius: target.searchRadius * sampleScale,
            red: sampleColor ? red : nil,
            green: sampleColor ? green : nil,
            blue: sampleColor ? blue : nil,
            preferenceCenter: target.preferenceCenter.map(samplePoint),
            acquire: target.acquire
        )
        guard let disk = measurement.disk else {
            return CoverMeasurement(disk: nil, fill: measurement.fill)
        }
        return CoverMeasurement(
            disk: ApparentDisk(
                center: CGPoint(
                    x: disk.center.x * CGFloat(stride) / scaleX,
                    y: disk.center.y * CGFloat(stride) / scaleY
                ),
                radius: disk.radius / sampleScale
            ),
            fill: measurement.fill
        )
    }

    static func measureGlow(
        pixels: [UInt8],
        width: Int,
        height: Int,
        center: CGPoint,
        geometricRadius: CGFloat
    ) -> GlowCover? {
        guard width > 1, height > 1, geometricRadius > 0, pixels.count >= width * height * 4 else { return nil }
        let maxRadius = geometricRadius * glowRadiusCap
        guard maxRadius >= 1 else { return nil }
        let ringCount = glowRingCount
        let ringWidth = maxRadius / CGFloat(ringCount)
        var medians: [(ring: Int, value: CGFloat)] = []
        medians.reserveCapacity(ringCount)
        for ring in 0..<ringCount {
            let radius = (CGFloat(ring) + 0.5) * ringWidth
            var values: [UInt8] = []
            values.reserveCapacity(glowSamplesPerRing)
            for step in 0..<glowSamplesPerRing {
                let angle = Double(step) / Double(glowSamplesPerRing) * 2 * Double.pi
                let x = Int((center.x + CGFloat(cos(angle)) * radius).rounded())
                let y = Int((center.y + CGFloat(sin(angle)) * radius).rounded())
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                values.append(luminance(pixels, width: width, x: x, y: y))
            }
            guard !values.isEmpty else { continue }
            values.sort()
            medians.append((ring, CGFloat(values[values.count / 2])))
        }
        guard medians.count >= 4 else { return nil }
        let peak = medians.map(\.value).max() ?? 0
        let outerCount = max(1, medians.count / 6)
        let background = medianValue(medians.suffix(outerCount).map(\.value))
        let span = peak - background
        guard span >= 8 else { return nil }
        let threshold = background + max(8, span * 0.12)
        let halfLevel = background + span * 0.5
        var outerRing = -1
        var halfRing = -1
        for sample in medians {
            if sample.value >= threshold { outerRing = sample.ring }
            if sample.value >= halfLevel { halfRing = sample.ring }
        }
        guard outerRing >= 0 else { return nil }
        let outerRadius = min(maxRadius, (CGFloat(outerRing) + 1) * ringWidth)
        let halfRadius = halfRing >= 0 ? (CGFloat(halfRing) + 0.5) * ringWidth : 0
        let feather = max(outerRadius - halfRadius, ringWidth)
        let fill = glowFill(
            pixels: pixels,
            width: width,
            height: height,
            center: center,
            inner: outerRadius,
            outer: min(maxRadius, outerRadius + max(feather, geometricRadius * 0.5))
        )
        return GlowCover(fill: fill, outerRadius: outerRadius, feather: feather)
    }

    static func apply(_ glow: GlowCover, to pixels: inout [UInt8], width: Int, height: Int, center: CGPoint) {
        guard glow.outerRadius > 0, glow.feather >= 0, pixels.count >= width * height * 4 else { return }
        let outer = glow.outerRadius
        let inner = max(0, outer - glow.feather)
        let minX = max(0, Int(floor(center.x - outer)))
        let maxX = min(width - 1, Int(ceil(center.x + outer)))
        let minY = max(0, Int(floor(center.y - outer)))
        let maxY = min(height - 1, Int(ceil(center.y + outer)))
        guard maxX >= minX, maxY >= minY else { return }
        let red = min(255, max(0, glow.fill.red * 255))
        let green = min(255, max(0, glow.fill.green * 255))
        let blue = min(255, max(0, glow.fill.blue * 255))
        for y in minY...maxY {
            for x in minX...maxX {
                let distance = hypot(CGFloat(x) - center.x, CGFloat(y) - center.y)
                guard distance < outer else { continue }
                let weight: CGFloat
                if distance <= inner {
                    weight = 1
                } else {
                    let t = (distance - inner) / max(glow.feather, 0.001)
                    let smooth = t * t * (3 - 2 * t)
                    weight = 1 - smooth
                }
                let index = (y * width + x) * 4
                pixels[index] = mix(pixels[index], toward: red, weight: weight)
                pixels[index + 1] = mix(pixels[index + 1], toward: green, weight: weight)
                pixels[index + 2] = mix(pixels[index + 2], toward: blue, weight: weight)
                pixels[index + 3] = 255
            }
        }
    }

    private static func luminance(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> UInt8 {
        let index = (y * width + x) * 4
        return UInt8((Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])) / 3)
    }

    private static func medianValue(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private static func glowFill(
        pixels: [UInt8],
        width: Int,
        height: Int,
        center: CGPoint,
        inner: CGFloat,
        outer: CGFloat
    ) -> CoverFill {
        let far = max(outer, inner + 1)
        var samples: [(luminance: UInt8, red: UInt8, green: UInt8, blue: UInt8)] = []
        let radii = 4
        for ring in 0..<radii {
            let radius = inner + (far - inner) * (CGFloat(ring) + 0.5) / CGFloat(radii)
            for step in 0..<glowSamplesPerRing {
                let angle = Double(step) / Double(glowSamplesPerRing) * 2 * Double.pi
                let x = Int((center.x + CGFloat(cos(angle)) * radius).rounded())
                let y = Int((center.y + CGFloat(sin(angle)) * radius).rounded())
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let index = (y * width + x) * 4
                let red = pixels[index]
                let green = pixels[index + 1]
                let blue = pixels[index + 2]
                samples.append((UInt8((Int(red) + Int(green) + Int(blue)) / 3), red, green, blue))
            }
        }
        guard !samples.isEmpty else { return .black }
        samples.sort { $0.luminance < $1.luminance }
        let darker = Array(samples.prefix(max(1, samples.count / 2)))
        return CoverFill(
            red: median(darker.map(\.red)),
            green: median(darker.map(\.green)),
            blue: median(darker.map(\.blue))
        )
    }

    private static func mix(_ value: UInt8, toward: CGFloat, weight: CGFloat) -> UInt8 {
        let mixed = (1 - weight) * CGFloat(value) + weight * toward
        return UInt8(min(255, max(0, mixed.rounded())))
    }
}
