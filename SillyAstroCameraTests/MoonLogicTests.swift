import Foundation
import CoreGraphics

#if canImport(SillyAstroCamera)
@testable import SillyAstroCamera
#endif

enum MoonLogicTests {
    static func runAll() throws {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                failures.append(message)
            }
        }

        let utc = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = utc
        components.year = 1992
        components.month = 4
        components.day = 12
        let meeusDate = components.date!
        let julian = MoonEphemeris.julianDate(from: meeusDate)
        expect(abs(julian - 2_448_724.5) < 1e-6, "儒略日 \(julian)，期望 2448724.5")

        let ecliptic = MoonEphemeris.geocentricEcliptic(at: meeusDate)
        expect(
            abs(SkyAngles.wrapSigned180(ecliptic.longitude - 133.162655)) < 0.2,
            "黄经 \(ecliptic.longitude)，期望约 133.16°"
        )
        expect(abs(ecliptic.latitude - (-3.229126)) < 0.2, "黄纬 \(ecliptic.latitude)，期望约 -3.23°")
        expect(abs(ecliptic.distance - 368_409.7) < 500, "月距 \(ecliptic.distance)，期望约 368410 km")

        let paris = MoonEphemeris.state(
            at: meeusDate,
            latitudeDegrees: 48.836,
            longitudeDegrees: 2.337,
            altitudeMeters: 0
        )
        expect(paris.angularRadius > SkyAngles.radians(fromDegrees: 0.24), "角半径过小")
        expect(paris.angularRadius < SkyAngles.radians(fromDegrees: 0.30), "角半径过大")
        expect(abs(paris.librationLongitude) < SkyAngles.radians(fromDegrees: 12), "天平动经度 \(paris.librationLongitude)")
        expect(abs(paris.librationLatitude) < SkyAngles.radians(fromDegrees: 12), "天平动纬度 \(paris.librationLatitude)")
        expect(paris.axisPositionAngle.isFinite, "月轴方位角无效")
        expect(paris.illuminatedFraction >= 0 && paris.illuminatedFraction <= 1, "亮面比例越界")

        components.year = 2026
        components.month = 1
        components.day = 3
        components.hour = 10
        let fullMoon = MoonEphemeris.state(
            at: components.date!,
            latitudeDegrees: 31.2,
            longitudeDegrees: 121.5,
            altitudeMeters: 10
        )
        expect(fullMoon.illuminatedFraction > 0.97, "2026-01-03 满月亮面比例 \(fullMoon.illuminatedFraction)")
        expect(fullMoon.phaseName == "满月", "月相名 \(fullMoon.phaseName)")

        let meridian = MoonEphemeris.horizontalCoordinates(
            hourAngle: 0,
            declination: 0,
            latitude: SkyAngles.radians(fromDegrees: 45)
        )
        expect(abs(meridian.altitude - .pi / 4) < 1e-9, "中天高度 \(meridian.altitude)")
        expect(abs(SkyAngles.wrapSigned180(SkyAngles.degrees(fromRadians: meridian.azimuth) - 180)) < 1e-6, "中天方位应朝南")

        let eastern = MoonEphemeris.horizontalCoordinates(
            hourAngle: -.pi / 2,
            declination: 0,
            latitude: 0
        )
        expect(abs(eastern.altitude) < 1e-9, "东方地平高度")
        expect(abs(SkyAngles.degrees(fromRadians: eastern.azimuth) - 90) < 1e-6, "东方方位")

        let latitude = SkyAngles.radians(fromDegrees: 45)
        let pose = MoonProjection.looking(
            at: .pi,
            altitude: 0,
            latitude: latitude,
            horizontalFOV: SkyAngles.radians(fromDegrees: 60),
            verticalFOV: SkyAngles.radians(fromDegrees: 45)
        )
        let size = CGSize(width: 1000, height: 750)
        let centered = MoonProjection.project(
            azimuth: .pi,
            altitude: 0,
            angularRadius: SkyAngles.radians(fromDegrees: 0.25),
            axisPositionAngle: 0,
            pose: pose,
            imageSize: size
        )
        expect(centered != nil, "正对月亮时应有落点")
        if let centered {
            expect(abs(centered.center.x - 500) < 0.5, "中心 x \(centered.center.x)")
            expect(abs(centered.center.y - 375) < 0.5, "中心 y \(centered.center.y)")
            expect(abs(centered.rotation) < 0.03, "朝南且月轴方位角为 0 时旋转应为 0，实际 \(centered.rotation)")
        }

        let wide = MoonProjection.zoomedFieldOfView(
            baseLandscapeHorizontalFOV: SkyAngles.radians(fromDegrees: 70),
            zoom: 1
        )
        let tele = MoonProjection.zoomedFieldOfView(
            baseLandscapeHorizontalFOV: SkyAngles.radians(fromDegrees: 70),
            zoom: 2
        )
        let widePose = MoonProjection.looking(at: 0, altitude: 0.4, latitude: latitude, horizontalFOV: wide, verticalFOV: wide * 0.75)
        let telePose = MoonProjection.looking(at: 0, altitude: 0.4, latitude: latitude, horizontalFOV: tele, verticalFOV: tele * 0.75)
        let widePlacement = MoonProjection.project(
            azimuth: 0, altitude: 0.4, angularRadius: 0.0045, axisPositionAngle: 0, pose: widePose, imageSize: size
        )
        let telePlacement = MoonProjection.project(
            azimuth: 0, altitude: 0.4, angularRadius: 0.0045, axisPositionAngle: 0, pose: telePose, imageSize: size
        )
        if let widePlacement, let telePlacement {
            let ratio = telePlacement.pixelRadius / widePlacement.pixelRadius
            expect(abs(ratio - 2) < 0.02, "变焦加倍后直径比 \(ratio)")
        } else {
            failures.append("变焦投影失败")
        }

        let shiftedPose = pose
        let indicated = MoonProjection.unproject(point: CGPoint(x: 600, y: 375), pose: shiftedPose, imageSize: size)
        expect(indicated != nil, "反投影失败")
        if let indicated {
            let rawAzimuth = Double.pi
            let offset = MoonProjection.alignmentOffsetDegrees(
                indicatedAzimuth: indicated.azimuth,
                indicatedAltitude: indicated.altitude,
                uncorrectedAzimuth: rawAzimuth,
                uncorrectedAltitude: 0
            )
            let corrected = MoonProjection.project(
                azimuth: SkyAngles.wrapPi(rawAzimuth + SkyAngles.radians(fromDegrees: offset.azimuth)),
                altitude: SkyAngles.radians(fromDegrees: offset.altitude),
                angularRadius: 0.004,
                axisPositionAngle: 0,
                pose: pose,
                imageSize: size
            )
            expect(corrected != nil, "校正后没有落点")
            if let corrected {
                expect(abs(corrected.center.x - 600) < 1, "校正后 x \(corrected.center.x)")
                expect(abs(corrected.center.y - 375) < 1, "校正后 y \(corrected.center.y)")
            }
            let replaced = MoonProjection.alignmentOffsetDegrees(
                indicatedAzimuth: indicated.azimuth,
                indicatedAltitude: indicated.altitude,
                uncorrectedAzimuth: rawAzimuth,
                uncorrectedAltitude: 0
            )
            expect(abs(replaced.azimuth - offset.azimuth) < 1e-6, "偏移应相对未校正方向写成绝对值")
        }

        let below = -SkyAngles.radians(fromDegrees: 2)
        let radius = SkyAngles.radians(fromDegrees: 0.25)
        expect(!MoonProjection.shouldDraw(altitude: below, angularRadius: radius, drawBelowHorizon: false, calibrating: false), "地平线下默认不画")
        expect(MoonProjection.shouldDraw(altitude: below, angularRadius: radius, drawBelowHorizon: true, calibrating: false), "开关打开时应画")
        expect(MoonProjection.shouldDraw(altitude: below, angularRadius: radius, drawBelowHorizon: false, calibrating: true), "校正中仍可拖")
        let partial = -radius / 2
        expect(MoonProjection.shouldDraw(altitude: partial, angularRadius: radius, drawBelowHorizon: false, calibrating: false), "露出一部分时始终绘制")
        expect(MoonProjection.shouldDraw(altitude: partial, angularRadius: radius, drawBelowHorizon: true, calibrating: false), "露出一部分时开关打开也绘制")

        let pointingDown = MoonProjection.looking(
            at: 0,
            altitude: below,
            latitude: latitude,
            horizontalFOV: SkyAngles.radians(fromDegrees: 50),
            verticalFOV: SkyAngles.radians(fromDegrees: 40)
        )
        let hidden = MoonProjection.project(
            azimuth: 0, altitude: below, angularRadius: radius, axisPositionAngle: 0, pose: pointingDown, imageSize: size
        )
        expect(hidden != nil, "镜头朝向地平线下的月亮时应能投影")
        expect(
            hidden == nil || !MoonProjection.shouldDraw(altitude: below, angularRadius: radius, drawBelowHorizon: false, calibrating: false),
            "开关关闭时不采用该落点"
        )

        let guidePose = MoonProjection.looking(
            at: .pi,
            altitude: 0,
            latitude: latitude,
            horizontalFOV: SkyAngles.radians(fromDegrees: 60),
            verticalFOV: SkyAngles.radians(fromDegrees: 45)
        )
        let centeredGuide = MoonProjection.offscreenGuide(
            azimuth: .pi,
            altitude: 0,
            angularRadius: radius,
            axisPositionAngle: 0,
            pose: guidePose,
            imageSize: size
        )
        expect(centeredGuide == nil, "正对月亮时不应有引导")

        let rightGuide = MoonProjection.offscreenGuide(
            azimuth: .pi + 0.8,
            altitude: 0,
            angularRadius: radius,
            axisPositionAngle: 0,
            pose: guidePose,
            imageSize: size
        )
        expect(rightGuide != nil, "偏出右侧应有引导")
        if let rightGuide {
            expect(abs(rightGuide.anchor.x - 960) < 1, "右边缘锚点 x \(rightGuide.anchor.x)")
            expect(abs(rightGuide.anchor.y - 375) < 1, "右边缘锚点 y \(rightGuide.anchor.y)")
            expect(abs(rightGuide.rotation - .pi / 2) < 0.05, "右边缘旋转 \(rightGuide.rotation)")
        }

        let upGuide = MoonProjection.offscreenGuide(
            azimuth: .pi,
            altitude: 0.8,
            angularRadius: radius,
            axisPositionAngle: 0,
            pose: guidePose,
            imageSize: size
        )
        expect(upGuide != nil, "偏出上侧应有引导")
        if let upGuide {
            expect(abs(upGuide.anchor.x - 500) < 1, "上边缘锚点 x \(upGuide.anchor.x)")
            expect(abs(upGuide.anchor.y - 48) < 1, "上边缘锚点 y \(upGuide.anchor.y)")
            expect(abs(upGuide.rotation) < 0.05, "上边缘旋转 \(upGuide.rotation)")
        }

        let northPose = MoonProjection.looking(
            at: 0,
            altitude: 0,
            latitude: latitude,
            horizontalFOV: SkyAngles.radians(fromDegrees: 60),
            verticalFOV: SkyAngles.radians(fromDegrees: 45)
        )
        let behindLeft = MoonProjection.offscreenGuide(
            azimuth: .pi + 0.4,
            altitude: 0,
            angularRadius: radius,
            axisPositionAngle: 0,
            pose: northPose,
            imageSize: size
        )
        expect(behindLeft != nil, "背后偏左应有引导")
        if let behindLeft {
            expect(abs(behindLeft.anchor.x - 40) < 1, "背后偏左应贴左内边，实际 \(behindLeft.anchor.x)")
            expect(behindLeft.anchor.x < size.width / 2, "背后偏左不应出现在右侧")
        }

        let grazingPoint = CGPoint(x: size.width + 1, y: size.height / 2)
        if let grazingSky = MoonProjection.unproject(point: grazingPoint, pose: guidePose, imageSize: size) {
            let grazingPlacement = MoonProjection.project(
                azimuth: grazingSky.azimuth,
                altitude: grazingSky.altitude,
                angularRadius: radius,
                axisPositionAngle: 0,
                pose: guidePose,
                imageSize: size
            )
            let grazingGuide = MoonProjection.offscreenGuide(
                azimuth: grazingSky.azimuth,
                altitude: grazingSky.altitude,
                angularRadius: radius,
                axisPositionAngle: 0,
                pose: guidePose,
                imageSize: size
            )
            expect(grazingPlacement != nil, "月盘擦到画面边缘时应能投影")
            expect(grazingGuide == nil, "月盘擦到画面时不应出现箭头")
        } else {
            failures.append("擦边反投影失败")
        }

        let suiteName = "SillyAstroCameraTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = AlignmentStore(defaults: defaults)
        expect(store.simulateMoonPhase, "月相模拟默认开启")
        store.azimuthOffsetDegrees = 3
        store.altitudeOffsetDegrees = -1
        store.drawMoonBelowHorizon = true
        store.simulateMoonPhase = false
        let reloaded = AlignmentStore(defaults: defaults)
        expect(abs(reloaded.azimuthOffsetDegrees - 3) < 1e-9, "方位偏移未保存")
        expect(abs(reloaded.altitudeOffsetDegrees - (-1)) < 1e-9, "高度偏移未保存")
        expect(reloaded.drawMoonBelowHorizon, "地平线开关未保存")
        expect(!reloaded.simulateMoonPhase, "月相模拟开关未保存")
        reloaded.resetAlignment()
        expect(reloaded.azimuthOffsetDegrees == 0 && reloaded.altitudeOffsetDegrees == 0, "重置后偏移应为 0")
        expect(reloaded.drawMoonBelowHorizon, "重置不应关掉地平线开关")
        expect(!reloaded.simulateMoonPhase, "重置不应改月相模拟开关")
        defaults.removePersistentDomain(forName: suiteName)

        let facingNorth = AttitudeMatrix(
            m11: 0, m12: -1, m13: 0,
            m21: 0, m22: 0, m23: 1,
            m31: -1, m32: 0, m33: 0
        )
        let devicePose = MoonProjection.pose(
            attitude: facingNorth,
            orientation: .portrait,
            latitude: latitude,
            horizontalFOV: 1,
            verticalFOV: 0.8
        )
        let facing = MoonProjection.horizontal(of: devicePose.forward)
        expect(abs(facing.azimuth) < 1e-6, "机背朝北时方位 \(facing.azimuth)")
        expect(abs(facing.altitude) < 1e-6, "竖直握持时高度 \(facing.altitude)")

        let rolled = MoonProjection.looking(
            at: .pi,
            altitude: 0,
            latitude: latitude,
            horizontalFOV: 1,
            verticalFOV: 0.8
        )
        var eastUp = rolled
        eastUp.up = SIMD3(0, -1, 0)
        eastUp.right = SIMD3(0, 0, 1)
        let rolledRotation = MoonProjection.spriteRotation(pose: eastUp, axisPositionAngle: 0)
        expect(abs(rolledRotation - .pi / 2) < 0.05, "屏幕朝东时天北极应顺时针 90°，实际 \(rolledRotation)")

        try expectMoonImage(expect)
        try expectComposite(expect)

        if !failures.isEmpty {
            throw TestFailure(message: failures.joined(separator: "\n"))
        }
    }

    private static func expectMoonImage(_ expect: (Bool, String) -> Void) throws {
        var pixels = [UInt8](repeating: 0, count: 16 * 8 * 4)
        for y in 0..<8 {
            for x in 0..<16 {
                let index = (y * 16 + x) * 4
                let shade = UInt8(80 + (x * 10) % 120)
                pixels[index] = shade
                pixels[index + 1] = shade
                pixels[index + 2] = shade
                pixels[index + 3] = 255
            }
        }
        let albedo = MoonAlbedo(width: 16, height: 8, pixels: pixels)
        guard let full = MoonImageRenderer.render(
            albedo: albedo,
            phaseAngle: 0,
            brightLimbPositionAngle: 0,
            axisPositionAngle: 0,
            librationLongitude: 0,
            librationLatitude: 0,
            size: 24
        ), let newMoon = MoonImageRenderer.render(
            albedo: albedo,
            phaseAngle: .pi,
            brightLimbPositionAngle: 0,
            axisPositionAngle: 0,
            librationLongitude: 0,
            librationLatitude: 0,
            size: 24
        ) else {
            expect(false, "月盘渲染失败")
            return
        }
        let fullCenter = brightness(full, x: 12, y: 12)
        let newCenter = brightness(newMoon, x: 12, y: 12)
        expect(fullCenter > 100, "满月中心亮度 \(fullCenter)")
        expect(newCenter < 20, "新月中心亮度 \(newCenter)")
    }

    private static func expectComposite(_ expect: (Bool, String) -> Void) throws {
        guard let base = solidImage(width: 21, height: 21, red: 0, green: 0, blue: 0, alpha: 255),
              let sprite = markerSprite() else {
            expect(false, "合成测试图创建失败")
            return
        }
        guard let upright = MoonCompositor.composite(
            base: base,
            sprite: sprite,
            center: CGPoint(x: 10, y: 10),
            pixelRadius: 2.5,
            rotation: 0
        ), let turned = MoonCompositor.composite(
            base: base,
            sprite: sprite,
            center: CGPoint(x: 10, y: 10),
            pixelRadius: 2.5,
            rotation: .pi / 2
        ) else {
            expect(false, "合成失败")
            return
        }
        let uprightPeak = peak(upright)
        let turnedPeak = peak(turned)
        expect(uprightPeak.y < 10 && abs(uprightPeak.x - 10) <= 1, "未旋转时亮点应在中心上方，实际 \(uprightPeak)")
        expect(turnedPeak.x > 10 && abs(turnedPeak.y - 10) <= 1, "顺时针 90° 后亮点应在中心右侧，实际 \(turnedPeak)")
    }

    private static func brightness(_ image: CGImage, x: Int, y: Int) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
        let index = y * image.bytesPerRow + x * 4
        return Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])
    }

    private static func solidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = red
            pixels[index + 1] = green
            pixels[index + 2] = blue
            pixels[index + 3] = alpha
        }
        return image(pixels: pixels, width: width, height: height)
    }

    private static func peak(_ image: CGImage) -> (x: Int, y: Int) {
        var best = (x: 0, y: 0, value: -1)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let value = brightness(image, x: x, y: y)
                if value > best.value {
                    best = (x, y, value)
                }
            }
        }
        return (best.x, best.y)
    }

    private static func markerSprite() -> CGImage? {
        let size = 5
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let topCenter = (0 * size + 2) * 4
        pixels[topCenter] = 255
        pixels[topCenter + 1] = 255
        pixels[topCenter + 2] = 255
        pixels[topCenter + 3] = 255
        return image(pixels: pixels, width: size, height: size)
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

struct TestFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}
