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
        let geometric = MoonEphemeris.state(
            at: meeusDate,
            latitudeDegrees: 48.836,
            longitudeDegrees: 2.337,
            altitudeMeters: 0,
            applyAtmosphere: false
        )
        expect(geometric.azimuth == paris.azimuth, "关闭大气不应改方位")
        expect(geometric.altitude <= paris.altitude + 1e-12, "几何高度不应高于视高度")
        expect(geometric.verticalScale == 1, "关闭大气时竖直缩放应为 1")
        expect(geometric.tint == .neutral, "关闭大气时颜色应为中性")
        expect(geometric.redDispersion == 0 && geometric.blueDispersion == 0, "关闭大气时不应有色散")

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
        expect(store.simulateAtmosphere, "大气模拟默认开启")
        store.azimuthOffsetDegrees = 3
        store.altitudeOffsetDegrees = -1
        store.drawMoonBelowHorizon = true
        store.simulateMoonPhase = false
        store.simulateAtmosphere = false
        let reloaded = AlignmentStore(defaults: defaults)
        expect(abs(reloaded.azimuthOffsetDegrees - 3) < 1e-9, "方位偏移未保存")
        expect(abs(reloaded.altitudeOffsetDegrees - (-1)) < 1e-9, "高度偏移未保存")
        expect(reloaded.drawMoonBelowHorizon, "地平线开关未保存")
        expect(!reloaded.simulateMoonPhase, "月相模拟开关未保存")
        expect(!reloaded.simulateAtmosphere, "大气模拟开关未保存")
        reloaded.resetAlignment()
        expect(reloaded.azimuthOffsetDegrees == 0 && reloaded.altitudeOffsetDegrees == 0, "重置后偏移应为 0")
        expect(reloaded.drawMoonBelowHorizon, "重置不应关掉地平线开关")
        expect(!reloaded.simulateMoonPhase, "重置不应改月相模拟开关")
        expect(!reloaded.simulateAtmosphere, "重置不应改大气模拟开关")
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

        let horizonPose = MoonProjection.looking(
            at: 0,
            altitude: 0,
            latitude: latitude,
            horizontalFOV: 1,
            verticalFOV: 0.75
        )
        let flattened = MoonProjection.project(
            azimuth: 0,
            altitude: 0,
            angularRadius: 0.005,
            axisPositionAngle: 0,
            pose: horizonPose,
            imageSize: size,
            verticalScale: 0.8,
            redDispersion: -0.001,
            blueDispersion: 0.002
        )
        expect(flattened != nil, "地平方向应能投影")
        if let flattened {
            expect(abs(flattened.verticalScale - 0.8) < 1e-6, "竖直缩放 \(flattened.verticalScale)")
            expect(abs(flattened.zenithRotation) < 0.05, "朝地平时天顶应在画面上方，实际 \(flattened.zenithRotation)")
            expect(flattened.redDispersion < 0, "红色散应朝地平")
            expect(flattened.blueDispersion > 0, "蓝色散应朝天顶")
        }

        let shifted = paris.corrected(azimuthOffset: 0, altitudeOffset: 0.01)
        expect(shifted.verticalScale == paris.verticalScale, "校正不应重算压扁")
        expect(shifted.tint == paris.tint, "校正不应重算消光")
        expect(shifted.redDispersion == paris.redDispersion && shifted.blueDispersion == paris.blueDispersion, "校正不应重算色散")
        expect(shifted.earthshine == paris.earthshine, "校正不应重算地照")

        expectAtmosphere(expect)
        try expectMoonImage(expect)
        try expectComposite(expect)
        expectMetering(expect)
        expectCover(expect)
        expectGlow(expect)
        expectPreviewSprite(expect)
        expectTrackingModes(expect)

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

        let quarterArguments = (
            phaseAngle: Double.pi / 2,
            brightLimbPositionAngle: 0.0,
            axisPositionAngle: 0.0,
            librationLongitude: 0.0,
            librationLatitude: 0.0,
            size: 24
        )
        guard let dayQuarter = MoonImageRenderer.render(
            albedo: albedo,
            phaseAngle: quarterArguments.phaseAngle,
            brightLimbPositionAngle: quarterArguments.brightLimbPositionAngle,
            axisPositionAngle: quarterArguments.axisPositionAngle,
            librationLongitude: quarterArguments.librationLongitude,
            librationLatitude: quarterArguments.librationLatitude,
            earthshine: 0,
            size: quarterArguments.size
        ), let nightQuarter = MoonImageRenderer.render(
            albedo: albedo,
            phaseAngle: quarterArguments.phaseAngle,
            brightLimbPositionAngle: quarterArguments.brightLimbPositionAngle,
            axisPositionAngle: quarterArguments.axisPositionAngle,
            librationLongitude: quarterArguments.librationLongitude,
            librationLatitude: quarterArguments.librationLatitude,
            earthshine: 0.5,
            size: quarterArguments.size
        ) else {
            expect(false, "上弦月渲染失败")
            return
        }
        let lit = (x: 12, y: 3)
        let dark = (x: 12, y: 20)
        let dayLitAlpha = alpha(dayQuarter, x: lit.x, y: lit.y)
        let dayDarkAlpha = alpha(dayQuarter, x: dark.x, y: dark.y)
        expect(dayLitAlpha > 250, "白昼阳面应不透明，实际 \(dayLitAlpha)")
        expect(dayDarkAlpha < 5, "白昼暗面应接近透明，实际 \(dayDarkAlpha)")
        let nightLit = brightness(nightQuarter, x: lit.x, y: lit.y)
        let nightDark = brightness(nightQuarter, x: dark.x, y: dark.y)
        let nightDarkAlpha = alpha(nightQuarter, x: dark.x, y: dark.y)
        expect(nightDarkAlpha > 0, "夜间暗面应有灰光")
        expect(nightDark * 4 < nightLit, "灰光应明显暗于阳面，暗 \(nightDark)，亮 \(nightLit)")

        expect(MoonEphemeris.nightSkyWeight(sunAltitude: SkyAngles.radians(fromDegrees: 10)) == 0, "太阳高于 6° 时没有夜天权重")
        expect(MoonEphemeris.nightSkyWeight(sunAltitude: SkyAngles.radians(fromDegrees: -20)) == 1, "太阳低于 -8° 时夜天权重为 1")
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

        guard let tinted = MoonCompositor.composite(
            base: base,
            sprite: sprite,
            center: CGPoint(x: 10, y: 10),
            pixelRadius: 2.5,
            rotation: .pi / 2,
            verticalScale: 1,
            zenithRotation: 0,
            tint: MoonTint(red: 1, green: 1, blue: 0)
        ) else {
            expect(false, "偏色合成失败")
            return
        }
        let tintedPeak = peak(tinted)
        let tintedPixel = pixel(tinted, x: tintedPeak.x, y: tintedPeak.y)
        expect(tintedPeak.x > 10 && abs(tintedPeak.y - 10) <= 1, "偏色后亮点仍应在右侧，实际 \(tintedPeak)")
        expect(tintedPixel.blue == 0 && tintedPixel.red > 200, "蓝色应被消掉，实际 \(tintedPixel)")

        guard let source = solidImage(width: 1, height: 1, red: 200, green: 100, blue: 50, alpha: 180),
              let channels = MoonCompositor.channelImages(
                sprite: source,
                tint: MoonTint(red: 2, green: 1, blue: 0)
              ) else {
            expect(false, "通道图创建失败")
            return
        }
        let redChannel = pixel(channels.red, x: 0, y: 0)
        let greenChannel = pixel(channels.green, x: 0, y: 0)
        let blueChannel = pixel(channels.blue, x: 0, y: 0)
        expect(redChannel.red == 180 && redChannel.green == 0 && redChannel.blue == 0, "红增益应截断到 alpha，实际 \(redChannel)")
        expect(greenChannel.green == 100 && greenChannel.red == 0 && greenChannel.blue == 0, "绿通道应只保留绿色，实际 \(greenChannel)")
        expect(blueChannel.blue == 0 && blueChannel.red == 0 && blueChannel.green == 0, "蓝增益为 0 时应清空蓝色，实际 \(blueChannel)")
        expect(alpha(channels.red, x: 0, y: 0) == 180, "通道图应保留原来的 alpha")

        guard let flat = solidImage(width: 21, height: 21, red: 20, green: 40, blue: 90, alpha: 255) else {
            expect(false, "纯色底图创建失败")
            return
        }
        expect(
            MoonCover.measureGlow(
                pixels: rgba(flat),
                width: 21,
                height: 21,
                center: CGPoint(x: 10, y: 10),
                geometricRadius: 3
            ) == nil,
            "没有高出背景的辉光时不应生成遮罩"
        )
        guard let untouched = MoonCompositor.composite(
            base: flat,
            sprite: sprite,
            center: CGPoint(x: 10, y: 10),
            pixelRadius: 2.5,
            rotation: 0
        ) else {
            expect(false, "无辉光合成失败")
            return
        }
        let skyPixel = pixel(untouched, x: 0, y: 0)
        expect(skyPixel.red == 20 && skyPixel.green == 40 && skyPixel.blue == 90, "没有辉光时景物应保持原色，实际 \(skyPixel)")

        var markedPixels = [UInt8](repeating: 255, count: 21 * 21 * 4)
        let markedIndex = (6 * 21 + 10) * 4
        markedPixels[markedIndex] = 255
        markedPixels[markedIndex + 1] = 0
        markedPixels[markedIndex + 2] = 0
        markedPixels[markedIndex + 3] = 255
        guard let marked = image(pixels: markedPixels, width: 21, height: 21),
              let passed = MoonCompositor.composite(
                base: marked,
                sprite: sprite,
                center: CGPoint(x: 10, y: 10),
                pixelRadius: 1,
                rotation: 0,
                glow: GlowCover(fill: CoverFill(red: 0, green: 1, blue: 0), outerRadius: 6, feather: 1)
              ) else {
            expect(false, "辉光坐标合成失败")
            return
        }
        let above = pixel(passed, x: 10, y: 6)
        let below = pixel(passed, x: 10, y: 18)
        expect(above.green > 200 && above.red < 40, "中心上方应被辉光遮罩盖住，实际 \(above)")
        expect(below.red == 255 && below.green == 255, "中心下方遮罩外应保持原色，实际 \(below)")
    }

    private static func expectMetering(_ expect: (Bool, String) -> Void) {
        let size = CGSize(width: 100, height: 200)
        let upper = SceneMetering.previewRectangle(moonCenter: CGPoint(x: 50, y: 40), previewSize: size)
        let lower = SceneMetering.previewRectangle(moonCenter: CGPoint(x: 50, y: 160), previewSize: size)
        let missing = SceneMetering.previewRectangle(moonCenter: nil, previewSize: size)
        expect(upper.minY > 100, "月亮在上半幅时测光应在下沿，实际 \(upper)")
        expect(lower.maxY < 100, "月亮在下半幅时测光应在上沿，实际 \(lower)")
        expect(missing.width == 100 && missing.height == 200, "月亮出画应全幅测光")

        let grown = SceneMetering.clampedDeviceRect(
            from: [
                CGPoint(x: 0.4, y: 0.4),
                CGPoint(x: 0.42, y: 0.4),
                CGPoint(x: 0.42, y: 0.42),
                CGPoint(x: 0.4, y: 0.42),
            ],
            minimumSize: CGSize(width: 0.2, height: 0.2)
        )
        expect(grown.width >= 0.2 && grown.height >= 0.2, "测光矩形应达到最小尺寸，实际 \(grown)")
        expect(grown.minX >= 0 && grown.maxX <= 1 && grown.minY >= 0 && grown.maxY <= 1, "测光矩形应留在画面内")
    }

    private static func expectCover(_ expect: (Bool, String) -> Void) {
        let width = 40
        let height = 40
        var sky = [UInt8](repeating: 8, count: width * height)
        fillDisk(&sky, width: width, centerX: 20, centerY: 20, radius: 6, value: 250)
        let aligned = MoonCover.measure(
            luminance: sky,
            width: width,
            height: height,
            geometricCenter: CGPoint(x: 20, y: 20),
            geometricRadius: 3
        ).disk
        expect(aligned != nil, "与几何圆重叠的亮块应给出视圆")
        if let aligned {
            expect(aligned.radius > 6 && aligned.radius <= 12, "视半径应包住光晕并限制在 4 倍内，实际 \(aligned.radius)")
            expect(hypot(aligned.center.x - 20, aligned.center.y - 20) < 1, "圆心应留在几何中心附近，实际 \(aligned.center)")
        }

        var offset = [UInt8](repeating: 8, count: width * height)
        fillDisk(&offset, width: width, centerX: 34, centerY: 20, radius: 4, value: 250)
        let missed = MoonCover.measure(
            luminance: offset,
            width: width,
            height: height,
            geometricCenter: CGPoint(x: 12, y: 20),
            geometricRadius: 3
        ).disk
        expect(missed == nil, "窄搜索窗外的亮块应退回几何半径")

        let acquired = MoonCover.measure(
            luminance: offset,
            width: width,
            height: height,
            geometricCenter: CGPoint(x: 12, y: 20),
            geometricRadius: 3,
            searchCenter: CGPoint(x: 12, y: 20),
            searchRadius: 30
        ).disk
        expect(acquired != nil, "宽搜索应锁定不与几何圆重叠的亮块")
        if let acquired {
            expect(hypot(acquired.center.x - 34, acquired.center.y - 20) < 1.5, "锁定圆心应落在亮块上，实际 \(acquired.center)")
        }

        var crowded = [UInt8](repeating: 8, count: width * height)
        fillDisk(&crowded, width: width, centerX: 8, centerY: 20, radius: 3, value: 250)
        fillDisk(&crowded, width: width, centerX: 34, centerY: 20, radius: 3, value: 250)
        let nearer = MoonCover.measure(
            luminance: crowded,
            width: width,
            height: height,
            geometricCenter: CGPoint(x: 20, y: 20),
            geometricRadius: 3,
            searchCenter: CGPoint(x: 20, y: 20),
            searchRadius: 30
        ).disk
        expect(nearer != nil && hypot(nearer!.center.x - 8, nearer!.center.y - 20) < 1.5, "多个亮块时应选择更靠近搜索中心的一个，实际 \(String(describing: nearer))")
        let tapped = MoonCover.measure(
            luminance: crowded,
            width: width,
            height: height,
            geometricCenter: CGPoint(x: 20, y: 20),
            geometricRadius: 3,
            searchCenter: CGPoint(x: 20, y: 20),
            searchRadius: 30,
            preferenceCenter: CGPoint(x: 30, y: 21)
        ).disk
        expect(tapped != nil && hypot(tapped!.center.x - 34, tapped!.center.y - 20) < 1.5, "点选应提高离点击更近的候选项权重，实际 \(String(describing: tapped))")
        expect(
            MoonCover.candidateWeight(distance: 4, geometricRadius: 3)
                > MoonCover.candidateWeight(distance: 22, geometricRadius: 3),
            "候选项离点击越近权重越高"
        )

        var oversized = [UInt8](repeating: 8, count: width * height)
        fillDisk(&oversized, width: width, centerX: 20, centerY: 20, radius: 16, value: 250)
        let tooBig = MoonCover.measure(
            luminance: oversized,
            width: width,
            height: height,
            geometricCenter: CGPoint(x: 20, y: 20),
            geometricRadius: 3,
            searchRadius: 30
        ).disk
        expect(tooBig == nil, "大于 4 倍几何半径的亮块应丢弃")

        let sea = [UInt8](repeating: 250, count: width * height)
        let flooded = MoonCover.measure(
            luminance: sea,
            width: width,
            height: height,
            geometricCenter: CGPoint(x: 20, y: 20),
            geometricRadius: 3
        ).disk
        expect(flooded == nil, "整片灯海应退回几何半径")

        let colorWidth = 48
        let colorCount = colorWidth * colorWidth
        var red = [UInt8](repeating: 20, count: colorCount)
        var green = [UInt8](repeating: 40, count: colorCount)
        var blue = [UInt8](repeating: 90, count: colorCount)
        var colorLuminance = [UInt8](repeating: 50, count: colorCount)
        fillColorDisk(&red, &green, &blue, &colorLuminance, width: colorWidth, centerX: 24, centerY: 24, radius: 5, red: 250, green: 250, blue: 250, luminance: 250)
        for index in [colorWidth * 12 + 24, colorWidth * 36 + 24, colorWidth * 24 + 12] {
            red[index] = 255
            green[index] = 255
            blue[index] = 255
            colorLuminance[index] = 255
        }
        let colored = MoonCover.measure(
            luminance: colorLuminance,
            width: colorWidth,
            height: colorWidth,
            geometricCenter: CGPoint(x: 24, y: 24),
            geometricRadius: 4,
            red: red,
            green: green,
            blue: blue
        )
        expect(colored.fill.blue > colored.fill.green && colored.fill.green > colored.fill.red, "暗蓝天空的遮罩应偏蓝，实际 \(colored.fill)")
        expect(colored.fill.blue > 0.25 && colored.fill.red < 0.15, "遮罩应取暗部天空而不是纯黑或白色，实际 \(colored.fill)")
        let sampledOnly = MoonCover.measure(
            luminance: colorLuminance,
            width: colorWidth,
            height: colorWidth,
            geometricCenter: CGPoint(x: 24, y: 24),
            geometricRadius: 4,
            red: red,
            green: green,
            blue: blue,
            acquire: false
        )
        expect(sampledOnly.disk == nil, "关闭追踪时不应挪动视圆")
        expect(sampledOnly.fill.blue > sampledOnly.fill.red && sampledOnly.fill.blue > 0.25, "关闭追踪时遮罩仍应取周围天空色，实际 \(sampledOnly.fill)")

        let smoothed = MoonCover.smooth(
            previous: ApparentDisk(center: CGPoint(x: 0, y: 0), radius: 4),
            measured: ApparentDisk(center: CGPoint(x: 10, y: 0), radius: 8)
        )
        expect(smoothed != nil && smoothed!.center.x > 0 && smoothed!.center.x < 10, "视圆应做指数平滑，实际 \(String(describing: smoothed))")
        expect(MoonCover.smooth(previous: smoothed, measured: nil) == nil, "测量失败应立刻退回几何半径")
    }

    private static func expectGlow(_ expect: (Bool, String) -> Void) {
        let width = 81
        let height = 81
        let center = CGPoint(x: 40, y: 40)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let distance = hypot(CGFloat(x) - center.x, CGFloat(y) - center.y)
                let glow = max(0, min(1, 1 - distance / 20))
                let red = UInt8((20 + glow * 230).rounded())
                let green = UInt8((40 + glow * 210).rounded())
                let blue = UInt8((90 + glow * 160).rounded())
                pixels[index] = red
                pixels[index + 1] = green
                pixels[index + 2] = blue
                pixels[index + 3] = 255
            }
        }
        let marker = (40 + 30) * 4 + 40 * width * 4
        pixels[marker] = 0
        pixels[marker + 1] = 255
        pixels[marker + 2] = 0
        pixels[marker + 3] = 255
        guard let glow = MoonCover.measureGlow(
            pixels: pixels,
            width: width,
            height: height,
            center: center,
            geometricRadius: 4
        ) else {
            expect(false, "渐暗辉光应测出遮罩")
            return
        }
        expect(glow.outerRadius > 8, "辉光外沿应超出几何半径，实际 \(glow.outerRadius)")
        expect(glow.outerRadius < 4 * MoonCover.glowRadiusCap, "辉光外沿不应顶到搜索上限，实际 \(glow.outerRadius)")
        expect(glow.feather > 1, "羽化应跟着辉光下落，实际 \(glow.feather)")
        expect(glow.fill.blue > glow.fill.green && glow.fill.green > glow.fill.red, "遮罩颜色应取外圈暗天空，实际 \(glow.fill)")
        var covered = pixels
        MoonCover.apply(glow, to: &covered, width: width, height: height, center: center)
        let core = rgbaPixel(covered, width: width, x: 40, y: 40)
        let halo = rgbaPixel(covered, width: width, x: 52, y: 40)
        let outside = rgbaPixel(covered, width: width, x: 70, y: 40)
        let haloBefore = rgbaPixel(pixels, width: width, x: 52, y: 40)
        expect(core.blue > core.green && core.red < 40, "辉光中心应盖成天空色，实际 \(core)")
        expect(halo.blue < haloBefore.blue - 40, "几何圆盖不住的渐暗环应向天空色收回，实际 \(halo) 原 \(haloBefore)")
        expect(outside.green == 255 && outside.red == 0, "辉光外的景物应保持不变，实际 \(outside)")

        var wide = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let distance = hypot(CGFloat(x) - center.x, CGFloat(y) - center.y)
                let glowAmount = max(0, min(1, 1 - distance / 50))
                wide[index] = UInt8((20 + glowAmount * 230).rounded())
                wide[index + 1] = UInt8((40 + glowAmount * 210).rounded())
                wide[index + 2] = UInt8((90 + glowAmount * 160).rounded())
                wide[index + 3] = 255
            }
        }
        guard let capped = MoonCover.measureGlow(
            pixels: wide,
            width: width,
            height: height,
            center: center,
            geometricRadius: 2
        ) else {
            expect(false, "超出搜索半径的辉光仍应在上限内测到")
            return
        }
        expect(capped.outerRadius <= 2 * MoonCover.glowRadiusCap + 1, "外沿应停在 16 倍几何半径，实际 \(capped.outerRadius)")
        var cappedPixels = wide
        MoonCover.apply(capped, to: &cappedPixels, width: width, height: height, center: center)
        let insideCap = rgbaPixel(cappedPixels, width: width, x: 48, y: 40)
        let beyondCap = rgbaPixel(cappedPixels, width: width, x: 76, y: 40)
        let beyondBefore = rgbaPixel(wide, width: width, x: 76, y: 40)
        expect(insideCap.blue > insideCap.red, "上限内的辉光应被盖住，实际 \(insideCap)")
        expect(beyondCap == beyondBefore, "上限外的辉光应保留，实际 \(beyondCap)")
    }

    private static func expectPreviewSprite(_ expect: (Bool, String) -> Void) {
        let full = PreviewSpriteKey(librationLongitude: 0.1, librationLatitude: -0.2)
        let turned = PreviewSpriteKey(librationLongitude: 0.1, librationLatitude: -0.2)
        expect(full == turned, "相同天平动应共用预览精灵")
        let shifted = PreviewSpriteKey(
            librationLongitude: 0.1 + SkyAngles.radians(fromDegrees: 0.6),
            librationLatitude: -0.2
        )
        expect(full != shifted, "天平动超过半度应重画预览精灵")
        expect(
            !MoonCover.shouldPublishTrackingTarget(previous: CGPoint(x: 10, y: 10), center: CGPoint(x: 10.4, y: 10.2)),
            "月心移动不足 1 像素时不应推动追踪目标"
        )
        expect(
            MoonCover.shouldPublishTrackingTarget(previous: CGPoint(x: 10, y: 10), center: CGPoint(x: 11.2, y: 10)),
            "月心移动达到 1 像素时应推动追踪目标"
        )
        expect(
            MoonCover.shouldPublishTrackingTarget(previous: nil, center: CGPoint(x: 10, y: 10)),
            "第一次追踪目标应推动"
        )
    }

    private static func expectTrackingModes(_ expect: (Bool, String) -> Void) {
        let suite = "silly-astro-camera.tracking-modes"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = AlignmentStore(defaults: defaults)
        expect(store.visualTrackingEnabled, "默认应打开自动追踪")
        store.azimuthOffsetDegrees = 4.5
        store.visualTrackingEnabled = false
        expect(!store.visualTrackingEnabled, "可以关闭自动追踪")
        expect(abs(store.azimuthOffsetDegrees - 4.5) < 1e-9, "关闭自动追踪应保留已保存的偏差")
        store.visualTrackingEnabled = true
        expect(store.visualTrackingEnabled, "可以重新打开自动追踪")
        expect(abs(store.azimuthOffsetDegrees - 4.5) < 1e-9, "自动追踪不应清掉已保存的偏差")
        defaults.removePersistentDomain(forName: suite)
    }

    private static func fillColorDisk(
        _ red: inout [UInt8],
        _ green: inout [UInt8],
        _ blue: inout [UInt8],
        _ luminance: inout [UInt8],
        width: Int,
        centerX: Int,
        centerY: Int,
        radius: Int,
        red redValue: UInt8,
        green greenValue: UInt8,
        blue blueValue: UInt8,
        luminance luminanceValue: UInt8
    ) {
        let limit = radius * radius
        for y in 0..<width {
            for x in 0..<width where (x - centerX) * (x - centerX) + (y - centerY) * (y - centerY) <= limit {
                let index = y * width + x
                red[index] = redValue
                green[index] = greenValue
                blue[index] = blueValue
                luminance[index] = luminanceValue
            }
        }
    }

    private static func fillDisk(_ pixels: inout [UInt8], width: Int, centerX: Int, centerY: Int, radius: Int, value: UInt8) {
        for y in 0..<pixels.count / width {
            for x in 0..<width where (x - centerX) * (x - centerX) + (y - centerY) * (y - centerY) <= radius * radius {
                pixels[y * width + x] = value
            }
        }
    }

    private static func expectAtmosphere(_ expect: (Bool, String) -> Void) {
        let seaLevel = Atmosphere.refractionRadians(trueAltitude: 0, altitudeMeters: 0)
        let seaLevelArcminutes = SkyAngles.degrees(fromRadians: seaLevel) * 60
        expect(seaLevelArcminutes > 28.5 && seaLevelArcminutes < 29.5, "地平折射 \(seaLevelArcminutes)′")

        let mid = Atmosphere.refractionRadians(
            trueAltitude: SkyAngles.radians(fromDegrees: 45),
            altitudeMeters: 0
        )
        let midArcminutes = SkyAngles.degrees(fromRadians: mid) * 60
        expect(midArcminutes > 0.9 && midArcminutes < 1.15, "45° 折射 \(midArcminutes)′")

        let zenith = Atmosphere.refractionRadians(
            trueAltitude: .pi / 2,
            altitudeMeters: 0
        )
        expect(SkyAngles.degrees(fromRadians: zenith) * 60 < 0.05, "天顶折射应接近 0")

        let high = Atmosphere.refractionRadians(trueAltitude: 0, altitudeMeters: 8500)
        expect(abs(high / seaLevel - exp(-1)) < 0.02, "一个标高处折射应按气压缩小")

        let radius = SkyAngles.radians(fromDegrees: 0.25)
        let horizon = Atmosphere.appearance(trueAltitude: 0, angularRadius: radius, altitudeMeters: 0)
        expect(horizon.verticalScale < 0.95 && horizon.verticalScale > 0.7, "地平竖直缩放 \(horizon.verticalScale)")
        expect(horizon.redDispersion < 0 && horizon.blueDispersion > 0, "地平色散方向")
        expect(horizon.tint.green == 1, "绿通道应保持 1")
        expect(horizon.tint.blue < horizon.tint.red, "地平蓝色透过率应低于红色")

        let highMoon = Atmosphere.appearance(
            trueAltitude: SkyAngles.radians(fromDegrees: 70),
            angularRadius: radius,
            altitudeMeters: 0
        )
        expect(highMoon.verticalScale > 0.98, "高空竖直缩放 \(highMoon.verticalScale)")
        expect(
            highMoon.tint.red > 0.9 && highMoon.tint.red < 1.3
                && highMoon.tint.blue > 0.7 && highMoon.tint.blue < 1.05,
            "高空颜色应接近白色 \(highMoon.tint)"
        )
        let clearRatio = highMoon.tint.blue / highMoon.tint.red
        expect(clearRatio > 0.7, "晴空高空蓝/红应接近 1，实际 \(clearRatio)")

        let hazyDepth = Atmosphere.aerosolOpticalDepth(visibilityKilometers: 5)
        expect(abs(hazyDepth - 0.96) < 1e-9, "5 km 能见度光学厚度 \(hazyDepth)")
        expect(abs(Atmosphere.aerosolOpticalDepth(visibilityKilometers: 40) - 0.12) < 1e-9, "40 km 能见度应为晴空光学厚度")
        expect(Atmosphere.aerosolOpticalDepth(visibilityKilometers: 0.2) == 2.5, "浓雾应顶到光学厚度上限")
        let hazyHorizon = Atmosphere.appearance(
            trueAltitude: 0,
            angularRadius: radius,
            altitudeMeters: 0,
            aerosolOpticalDepth: hazyDepth
        )
        expect(hazyHorizon.tint.green == 1, "霾天绿通道仍为 1")
        let hazyRatio = hazyHorizon.tint.blue / hazyHorizon.tint.red
        expect(hazyRatio < clearRatio * 0.5, "霾天低空蓝/红 \(hazyRatio) 应明显小于晴空高空 \(clearRatio)")

        let lifted = Atmosphere.appearance(
            trueAltitude: SkyAngles.radians(fromDegrees: -0.4),
            angularRadius: radius,
            altitudeMeters: 0
        )
        let upperLimb = lifted.apparentAltitude + lifted.verticalScale * radius
        expect(upperLimb > 0, "几何 -0.4° 时视上边缘应在地平线上")
        expect(
            MoonProjection.shouldDraw(
                altitude: lifted.apparentAltitude,
                angularRadius: radius,
                verticalScale: lifted.verticalScale,
                drawBelowHorizon: false,
                calibrating: false
            ),
            "视上边缘露出时应绘制"
        )
    }

    private static func alpha(_ image: CGImage, x: Int, y: Int) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
        let index = y * image.bytesPerRow + x * 4
        return Int(bytes[index + 3])
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

    private static func rgba(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data else { return [] }
        return [UInt8](data as Data)
    }

    private static func rgbaPixel(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        let index = (y * width + x) * 4
        guard pixels.count >= index + 3 else { return (-1, -1, -1) }
        return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return (-1, -1, -1)
        }
        let index = y * image.bytesPerRow + x * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
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
