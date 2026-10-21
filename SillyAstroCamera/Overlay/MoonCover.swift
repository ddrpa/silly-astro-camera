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

enum MoonCover {
    static let measuredPull = 0.65
    static let radiusMargin: CGFloat = 1.05
    static let maxRadiusScale: CGFloat = 4
    static let smoothResponse: CGFloat = 0.35

    static func measure(
        luminance: [UInt8],
        width: Int,
        height: Int,
        geometricCenter: CGPoint,
        geometricRadius: CGFloat
    ) -> ApparentDisk? {
        guard width > 1, height > 1, luminance.count >= width * height, geometricRadius > 0 else { return nil }
        let windowRadius = max(geometricRadius * maxRadiusScale, 8)
        let capRadius = geometricRadius * maxRadiusScale
        var samples: [UInt8] = []
        samples.reserveCapacity(256)
        var windowCount = 0
        let minX = max(0, Int(floor(geometricCenter.x - windowRadius)))
        let maxX = min(width - 1, Int(ceil(geometricCenter.x + windowRadius)))
        let minY = max(0, Int(floor(geometricCenter.y - windowRadius)))
        let maxY = min(height - 1, Int(ceil(geometricCenter.y + windowRadius)))
        guard maxX >= minX, maxY >= minY else { return nil }
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = CGFloat(x) - geometricCenter.x
                let dy = CGFloat(y) - geometricCenter.y
                guard dx * dx + dy * dy <= windowRadius * windowRadius else { continue }
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
        var seeds: [Int] = []
        let overlap = max(geometricRadius, 1)
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = CGFloat(x) - geometricCenter.x
                let dy = CGFloat(y) - geometricCenter.y
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared <= windowRadius * windowRadius else { continue }
                let index = y * width + x
                guard Int(luminance[index]) > threshold else { continue }
                bright[index] = true
                if distanceSquared <= overlap * overlap {
                    seeds.append(index)
                }
            }
        }
        guard !seeds.isEmpty else { return nil }

        var stack = seeds
        var component: [Int] = []
        var seen = [Bool](repeating: false, count: width * height)
        for seed in seeds {
            seen[seed] = true
        }
        while let index = stack.popLast() {
            component.append(index)
            let x = index % width
            let y = index / width
            let neighbors = [
                (x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1),
                (x - 1, y - 1), (x + 1, y - 1), (x - 1, y + 1), (x + 1, y + 1),
            ]
            for (nx, ny) in neighbors {
                guard nx >= minX, nx <= maxX, ny >= minY, ny <= maxY else { continue }
                let next = ny * width + nx
                guard bright[next], !seen[next] else { continue }
                seen[next] = true
                stack.append(next)
            }
        }
        guard !component.isEmpty else { return nil }
        if CGFloat(component.count) > CGFloat(windowCount) * 0.6 { return nil }

        var sumX = 0.0
        var sumY = 0.0
        for index in component {
            sumX += Double(index % width)
            sumY += Double(index / width)
        }
        let count = Double(component.count)
        let centroid = CGPoint(x: sumX / count, y: sumY / count)
        let center = CGPoint(
            x: geometricCenter.x + (centroid.x - geometricCenter.x) * measuredPull,
            y: geometricCenter.y + (centroid.y - geometricCenter.y) * measuredPull
        )
        var farthest: CGFloat = 0
        for index in component {
            let dx = CGFloat(index % width) - center.x
            let dy = CGFloat(index / width) - center.y
            farthest = max(farthest, hypot(dx, dy))
        }
        let enclosing = farthest * radiusMargin
        guard enclosing <= capRadius else { return nil }
        return ApparentDisk(
            center: center,
            radius: min(capRadius, max(geometricRadius, enclosing))
        )
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

    static func measure(
        pixelBuffer: CVPixelBuffer,
        previewCenter: CGPoint,
        previewRadius: CGFloat,
        previewSize: CGSize
    ) -> ApparentDisk? {
        guard previewSize.width > 1, previewSize.height > 1, previewRadius > 0 else { return nil }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard bufferWidth > 1, bufferHeight > 1 else { return nil }
        let bufferAspect = CGFloat(bufferWidth) / CGFloat(bufferHeight)
        let previewAspect = previewSize.width / previewSize.height
        guard abs(bufferAspect - previewAspect) < 0.08 else { return nil }
        let scaleX = CGFloat(bufferWidth) / previewSize.width
        let scaleY = CGFloat(bufferHeight) / previewSize.height
        let stride = max(1, max(bufferWidth, bufferHeight) / 96)
        let sampleWidth = (bufferWidth + stride - 1) / stride
        let sampleHeight = (bufferHeight + stride - 1) / stride
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard bytesPerRow >= bufferWidth * 4 else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var luminance = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        for y in 0..<sampleHeight {
            let row = min(bufferHeight - 1, y * stride)
            let rowStart = row * bytesPerRow
            for x in 0..<sampleWidth {
                let column = min(bufferWidth - 1, x * stride)
                let index = rowStart + column * 4
                let blue = Int(pixels[index])
                let green = Int(pixels[index + 1])
                let red = Int(pixels[index + 2])
                luminance[y * sampleWidth + x] = UInt8((red + green + blue) / 3)
            }
        }
        let sampleCenter = CGPoint(
            x: previewCenter.x * scaleX / CGFloat(stride),
            y: previewCenter.y * scaleY / CGFloat(stride)
        )
        let sampleRadius = previewRadius * (scaleX + scaleY) / (2 * CGFloat(stride))
        guard let disk = measure(
            luminance: luminance,
            width: sampleWidth,
            height: sampleHeight,
            geometricCenter: sampleCenter,
            geometricRadius: sampleRadius
        ) else { return nil }
        return ApparentDisk(
            center: CGPoint(
                x: disk.center.x * CGFloat(stride) / scaleX,
                y: disk.center.y * CGFloat(stride) / scaleY
            ),
            radius: disk.radius * CGFloat(stride) * 2 / (scaleX + scaleY)
        )
    }
}
