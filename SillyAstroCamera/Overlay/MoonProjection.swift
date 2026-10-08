import Foundation
import simd

struct AttitudeMatrix: Equatable, Sendable {
    var m11: Double
    var m12: Double
    var m13: Double
    var m21: Double
    var m22: Double
    var m23: Double
    var m31: Double
    var m32: Double
    var m33: Double
}

enum ScreenOrientation: Equatable {
    case portrait
    case upsideDown
    case landscapeLeft
    case landscapeRight

    var isPortrait: Bool {
        self == .portrait || self == .upsideDown
    }
}

struct CameraPose: Equatable {
    var forward: SIMD3<Double>
    var right: SIMD3<Double>
    var up: SIMD3<Double>
    var latitude: Double
    var horizontalFOV: Double
    var verticalFOV: Double
}

struct MoonPlacement: Equatable {
    var center: CGPoint
    var pixelRadius: CGFloat
    var rotation: CGFloat
    var verticalScale: CGFloat
    var zenithRotation: CGFloat
    var tint: MoonTint
    var redDispersion: CGFloat
    var blueDispersion: CGFloat

    func zenithOffset(_ pixelsTowardZenith: CGFloat) -> CGSize {
        CGSize(
            width: sin(zenithRotation) * pixelsTowardZenith,
            height: -cos(zenithRotation) * pixelsTowardZenith
        )
    }
}

struct MoonGuide: Equatable {
    var anchor: CGPoint
    var rotation: CGFloat
    var separationDegrees: Double
}

enum MoonProjection {
    static func direction(azimuth: Double, altitude: Double) -> SIMD3<Double> {
        let cosineAltitude = cos(altitude)
        return SIMD3(
            cosineAltitude * cos(azimuth),
            -cosineAltitude * sin(azimuth),
            sin(altitude)
        )
    }

    static func horizontal(of vector: SIMD3<Double>) -> (azimuth: Double, altitude: Double) {
        let unit = simd_normalize(vector)
        let altitude = asin(SkyAngles.clamp(unit.z, -1, 1))
        let azimuth = atan2(-unit.y, unit.x)
        return (SkyAngles.wrapPi(azimuth), altitude)
    }

    static func fieldOfView(landscapeHorizontalFOV: Double, imageSize: CGSize) -> (horizontal: Double, vertical: Double) {
        let longSide = landscapeHorizontalFOV
        let shortSide = 2 * atan(tan(longSide / 2) * 3 / 4)
        if imageSize.width >= imageSize.height {
            return (longSide, shortSide)
        }
        return (shortSide, longSide)
    }

    static func zoomedFieldOfView(baseLandscapeHorizontalFOV: Double, zoom: Double) -> Double {
        let safeZoom = max(zoom, 0.01)
        return 2 * atan(tan(baseLandscapeHorizontalFOV / 2) / safeZoom)
    }

    static func pose(
        attitude: AttitudeMatrix,
        orientation: ScreenOrientation,
        latitude: Double,
        horizontalFOV: Double,
        verticalFOV: Double
    ) -> CameraPose {
        let axes = screenAxes(orientation)
        return CameraPose(
            forward: worldVector(SIMD3(0, 0, -1), attitude: attitude),
            right: worldVector(axes.right, attitude: attitude),
            up: worldVector(axes.up, attitude: attitude),
            latitude: latitude,
            horizontalFOV: horizontalFOV,
            verticalFOV: verticalFOV
        )
    }

    static func project(
        azimuth: Double,
        altitude: Double,
        angularRadius: Double,
        axisPositionAngle: Double,
        pose: CameraPose,
        imageSize: CGSize,
        verticalScale: Double = 1,
        tint: MoonTint = .neutral,
        redDispersion: Double = 0,
        blueDispersion: Double = 0
    ) -> MoonPlacement? {
        let moon = direction(azimuth: azimuth, altitude: altitude)
        let depth = simd_dot(moon, pose.forward)
        guard depth > 0.02 else { return nil }
        let x = simd_dot(moon, pose.right) / depth
        let y = simd_dot(moon, pose.up) / depth
        let halfWidth = tan(pose.horizontalFOV / 2)
        let halfHeight = tan(pose.verticalFOV / 2)
        guard halfWidth > 0, halfHeight > 0 else { return nil }
        let normalizedX = x / halfWidth
        let normalizedY = y / halfHeight
        let center = CGPoint(
            x: (normalizedX + 1) / 2 * imageSize.width,
            y: (1 - normalizedY) / 2 * imageSize.height
        )
        let pixelRadius = tan(angularRadius) / halfWidth * imageSize.width / 2
        guard pixelRadius.isFinite, pixelRadius > 0 else { return nil }
        let scale = CGFloat(verticalScale.isFinite && verticalScale > 0 ? verticalScale : 1)
        let margin = max(pixelRadius, pixelRadius * scale)
        if center.x < -margin || center.y < -margin
            || center.x > imageSize.width + margin || center.y > imageSize.height + margin {
            return nil
        }
        return MoonPlacement(
            center: center,
            pixelRadius: pixelRadius,
            rotation: spriteRotation(pose: pose, axisPositionAngle: axisPositionAngle),
            verticalScale: scale,
            zenithRotation: zenithRotation(pose: pose),
            tint: tint,
            redDispersion: pixels(forAngle: redDispersion, pose: pose, imageSize: imageSize),
            blueDispersion: pixels(forAngle: blueDispersion, pose: pose, imageSize: imageSize)
        )
    }

    static func offscreenGuide(
        azimuth: Double,
        altitude: Double,
        angularRadius: Double,
        axisPositionAngle: Double,
        pose: CameraPose,
        imageSize: CGSize,
        verticalScale: Double = 1,
        tint: MoonTint = .neutral,
        redDispersion: Double = 0,
        blueDispersion: Double = 0
    ) -> MoonGuide? {
        guard imageSize.width > 1, imageSize.height > 1 else { return nil }
        if project(
            azimuth: azimuth,
            altitude: altitude,
            angularRadius: angularRadius,
            axisPositionAngle: axisPositionAngle,
            pose: pose,
            imageSize: imageSize,
            verticalScale: verticalScale,
            tint: tint,
            redDispersion: redDispersion,
            blueDispersion: blueDispersion
        ) != nil {
            return nil
        }
        let moon = direction(azimuth: azimuth, altitude: altitude)
        let depth = simd_dot(moon, pose.forward)
        let right = simd_dot(moon, pose.right)
        let up = simd_dot(moon, pose.up)
        let halfWidth = tan(pose.horizontalFOV / 2)
        let halfHeight = tan(pose.verticalFOV / 2)
        guard halfWidth > 0, halfHeight > 0 else { return nil }

        let ndcX: Double
        let ndcY: Double
        if depth > 0.02 {
            ndcX = (right / depth) / halfWidth
            ndcY = (up / depth) / halfHeight
        } else {
            ndcX = right / halfWidth
            ndcY = up / halfHeight
        }
        var screenX = ndcX
        var screenY = -ndcY
        if hypot(screenX, screenY) < 1e-6 {
            screenX = 0
            screenY = 1
        }
        guard let anchor = guideAnchor(screenX: screenX, screenY: screenY, imageSize: imageSize) else {
            return nil
        }
        let separation = acos(SkyAngles.clamp(depth, -1, 1))
        return MoonGuide(
            anchor: anchor,
            rotation: CGFloat(atan2(screenX, -screenY)),
            separationDegrees: SkyAngles.degrees(fromRadians: separation)
        )
    }

    private static let guideInsetLeft: CGFloat = 40
    private static let guideInsetRight: CGFloat = 40
    private static let guideInsetTop: CGFloat = 48
    private static let guideInsetBottom: CGFloat = 72

    private static func guideAnchor(screenX: Double, screenY: Double, imageSize: CGSize) -> CGPoint? {
        let minX = Double(guideInsetLeft)
        let maxX = Double(imageSize.width) - Double(guideInsetRight)
        let minY = Double(guideInsetTop)
        let maxY = Double(imageSize.height) - Double(guideInsetBottom)
        guard maxX > minX, maxY > minY else { return nil }
        let centerX = Double(imageSize.width) / 2
        let centerY = Double(imageSize.height) / 2
        var scale = Double.infinity
        if screenX > 1e-8 {
            scale = min(scale, (maxX - centerX) / screenX)
        } else if screenX < -1e-8 {
            scale = min(scale, (minX - centerX) / screenX)
        }
        if screenY > 1e-8 {
            scale = min(scale, (maxY - centerY) / screenY)
        } else if screenY < -1e-8 {
            scale = min(scale, (minY - centerY) / screenY)
        }
        guard scale.isFinite, scale > 0 else { return nil }
        return CGPoint(x: centerX + scale * screenX, y: centerY + scale * screenY)
    }

    static func unproject(point: CGPoint, pose: CameraPose, imageSize: CGSize) -> (azimuth: Double, altitude: Double)? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let normalizedX = point.x / imageSize.width * 2 - 1
        let normalizedY = 1 - point.y / imageSize.height * 2
        let vector = pose.forward
            + pose.right * (normalizedX * tan(pose.horizontalFOV / 2))
            + pose.up * (normalizedY * tan(pose.verticalFOV / 2))
        guard simd_length(vector) > 1e-8 else { return nil }
        return horizontal(of: vector)
    }

    static func spriteRotation(pose: CameraPose, axisPositionAngle: Double) -> CGFloat {
        let northPole = direction(azimuth: 0, altitude: pose.latitude)
        var north = northPole - pose.forward * simd_dot(northPole, pose.forward)
        let length = simd_length(north)
        if length < 1e-6 {
            return CGFloat(-axisPositionAngle)
        }
        north /= length
        let clockwiseFromUp = atan2(simd_dot(north, pose.right), simd_dot(north, pose.up))
        return CGFloat(clockwiseFromUp - axisPositionAngle)
    }

    static func alignmentOffsetDegrees(
        indicatedAzimuth: Double,
        indicatedAltitude: Double,
        uncorrectedAzimuth: Double,
        uncorrectedAltitude: Double
    ) -> (azimuth: Double, altitude: Double) {
        (
            SkyAngles.wrapSigned180(SkyAngles.degrees(fromRadians: indicatedAzimuth - uncorrectedAzimuth)),
            SkyAngles.degrees(fromRadians: indicatedAltitude - uncorrectedAltitude)
        )
    }

    static func shouldDraw(
        altitude: Double,
        angularRadius: Double,
        verticalScale: Double = 1,
        drawBelowHorizon: Bool,
        calibrating: Bool
    ) -> Bool {
        if calibrating {
            return true
        }
        let scale = verticalScale.isFinite && verticalScale > 0 ? verticalScale : 1
        if altitude < -angularRadius * scale && !drawBelowHorizon {
            return false
        }
        return true
    }

    static func zenithRotation(pose: CameraPose) -> CGFloat {
        let zenith = SIMD3<Double>(0, 0, 1)
        var projected = zenith - pose.forward * simd_dot(zenith, pose.forward)
        let length = simd_length(projected)
        if length < 1e-6 {
            return 0
        }
        projected /= length
        return CGFloat(atan2(simd_dot(projected, pose.right), simd_dot(projected, pose.up)))
    }

    static func pixels(forAngle angle: Double, pose: CameraPose, imageSize: CGSize) -> CGFloat {
        let halfWidth = tan(pose.horizontalFOV / 2)
        guard halfWidth > 0, imageSize.width > 0, angle.isFinite else { return 0 }
        return CGFloat(tan(angle) / halfWidth * imageSize.width / 2)
    }

    static func looking(
        at azimuth: Double,
        altitude: Double,
        latitude: Double,
        horizontalFOV: Double,
        verticalFOV: Double
    ) -> CameraPose {
        let forward = direction(azimuth: azimuth, altitude: altitude)
        let worldUp = SIMD3<Double>(0, 0, 1)
        var up = worldUp - forward * simd_dot(worldUp, forward)
        if simd_length(up) < 1e-6 {
            up = SIMD3(0, -1, 0)
        }
        up = simd_normalize(up)
        let right = simd_normalize(simd_cross(forward, up))
        return CameraPose(
            forward: forward,
            right: right,
            up: up,
            latitude: latitude,
            horizontalFOV: horizontalFOV,
            verticalFOV: verticalFOV
        )
    }

    private static func screenAxes(_ orientation: ScreenOrientation) -> (right: SIMD3<Double>, up: SIMD3<Double>) {
        switch orientation {
        case .portrait:
            return (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        case .upsideDown:
            return (SIMD3(-1, 0, 0), SIMD3(0, -1, 0))
        case .landscapeLeft:
            return (SIMD3(0, -1, 0), SIMD3(1, 0, 0))
        case .landscapeRight:
            return (SIMD3(0, 1, 0), SIMD3(-1, 0, 0))
        }
    }

    private static func worldVector(_ device: SIMD3<Double>, attitude: AttitudeMatrix) -> SIMD3<Double> {
        SIMD3(
            attitude.m11 * device.x + attitude.m21 * device.y + attitude.m31 * device.z,
            attitude.m12 * device.x + attitude.m22 * device.y + attitude.m32 * device.z,
            attitude.m13 * device.x + attitude.m23 * device.y + attitude.m33 * device.z
        )
    }
}
