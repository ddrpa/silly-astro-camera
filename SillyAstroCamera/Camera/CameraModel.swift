import AVFoundation
import CoreLocation
import Observation
import Photos
import UIKit

@MainActor
@Observable
final class CameraModel {
    let session = CameraSession()
    let orientationService = OrientationService()
    let alignment = AlignmentStore()

    var phaseName = "—"
    var displayZoom = 1.0
    var placement: MoonPlacement?
    var moonGuide: MoonGuide?
    var horizonMessage: String?
    var sprite: CGImage?
    var statusMessage: String?
    var exposureBias = 0.0
    var exposureRange: ClosedRange<Double> = -2...2
    var meteringPoint: CGPoint?
    var capturedImage: UIImage?
    var capturedBaseImage: UIImage?
    var showResult = false
    var isAdjustingCapture = false
    var resultReady = false
    var resultSprite: CGImage?
    var resultPlacement: MoonPlacement?
    var resultPixelSize: CGSize = .zero

    private var moon: MoonState?
    private var uncorrectedMoon: MoonState?
    private var pose: CameraPose?
    private var previewSize: CGSize = .zero
    private var screenOrientation: ScreenOrientation = .portrait
    private var attitude: DeviceAttitude?
    private var albedo: MoonAlbedo?
    private var previewKey: PreviewSpriteKey?
    private var requestedPreviewKey: PreviewSpriteKey?
    private var renderingSprite = false
    private var pendingAttitude: DeviceAttitude?
    private var attitudeRefreshScheduled = false
    private var ephemerisTimer: Timer?
    private var pinchOrigin: Double?
    private var frozen: FrozenFrame?
    private var geometricPlacement: MoonPlacement?
    private var coverCenter: CGPoint?
    private var coverRadius: CGFloat?
    private var trackPreferenceOffset: CGPoint?
    private var trackMissStarted: Date?
    private var meteringCorners: [CGPoint]?
    private var lastTrackingTargetCenter: CGPoint?
    private var lastTrackingTargetRadius: CGFloat?
    private var captureRenderGeneration = 0
    private var captureSpriteKey: CaptureSpriteKey?
    private var resultGlow: GlowCover?

    private static let previewSpriteSize = 512
    private static let captureSpriteSize = 2048

    private static var maximumDisplayFramesPerSecond: Int {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .map(\.screen.maximumFramesPerSecond)
            .max() ?? 60
    }

    func start() {
        albedo = MoonAlbedo.bundled()
        if albedo == nil {
            statusMessage = "缺少月面图片"
        }
        session.onConfigured = { [weak self] message in
            self?.statusMessage = message ?? self?.statusMessage
            self?.exposureRange = self?.session.exposureLimits().doubleRange ?? -2...2
        }
        session.onZoom = { [weak self] zoom in
            self?.displayZoom = zoom
            self?.refreshOverlay()
        }
        session.onApparentCover = { [weak self] measurement in
            self?.applyApparentCover(measurement)
        }
        orientationService.onUpdate = { [weak self] attitude in
            self?.ingest(attitude)
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted {
                    self.session.start()
                    self.orientationService.start(framesPerSecond: Self.maximumDisplayFramesPerSecond)
                } else {
                    self.statusMessage = "需要相机权限才能取景"
                }
            }
        }
        ephemerisTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMoon()
            }
        }
        session.setVideoAnalysisEnabled(alignment.visualTrackingEnabled)
        refreshMoon()
    }

    func stop() {
        ephemerisTimer?.invalidate()
        session.stop()
        orientationService.stop()
    }

    func updatePreview(size: CGSize, orientation: ScreenOrientation) {
        previewSize = size
        screenOrientation = orientation
        session.updateOrientation(orientation.interfaceOrientation)
        refreshOverlay()
    }

    func refreshDisplayedMoon() {
        if let moon {
            updateSprite(for: moon)
        }
        refreshOverlay()
    }

    func reloadMoon() {
        refreshMoon()
    }

    func setDisplayZoom(_ zoom: Double) {
        session.setDisplayZoom(zoom)
    }

    func beginPinch() {
        pinchOrigin = displayZoom
    }

    func updatePinch(_ scale: CGFloat) {
        if pinchOrigin == nil {
            pinchOrigin = displayZoom
        }
        session.setDisplayZoom((pinchOrigin ?? displayZoom) * Double(scale))
    }

    func endPinch() {
        pinchOrigin = nil
    }

    func setExposureBias(_ bias: Double) {
        exposureBias = bias
        session.setExposureBias(Float(bias))
    }

    func focus(at point: CGPoint, in view: PreviewView) {
        let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        session.focusAndExpose(atDevicePoint: devicePoint)
        meteringPoint = point
        Task {
            try? await Task.sleep(for: .seconds(1))
            if meteringPoint == point {
                meteringPoint = nil
                session.endManualMetering()
            }
        }
    }

    func setVisualTracking(_ enabled: Bool) {
        alignment.visualTrackingEnabled = enabled
        clearTrackingLock()
        trackPreferenceOffset = nil
        lastTrackingTargetCenter = nil
        lastTrackingTargetRadius = nil
        session.setVideoAnalysisEnabled(enabled)
        if !enabled {
            session.setCoverTarget(nil)
        }
        refreshOverlay()
    }

    func track(at point: CGPoint) {
        guard alignment.visualTrackingEnabled, let geometricPlacement else { return }
        trackPreferenceOffset = CGPoint(
            x: point.x - geometricPlacement.center.x,
            y: point.y - geometricPlacement.center.y
        )
        trackMissStarted = nil
        publishCoverTarget(force: true)
    }

    func resetResultAlignment() {
        alignment.resetAlignment()
        frozen?.useTrackedCenter = false
        frozen?.trackedCenter = nil
        isAdjustingCapture = false
        refreshCaptureResult(remeasureGlow: true, rerenderSprite: false)
    }

    func setResultMoonPhase(_ enabled: Bool) {
        guard alignment.simulateMoonPhase != enabled else { return }
        alignment.simulateMoonPhase = enabled
        refreshCaptureResult(remeasureGlow: false, rerenderSprite: true)
    }

    func setResultAtmosphere(_ enabled: Bool) {
        guard alignment.simulateAtmosphere != enabled else { return }
        alignment.simulateAtmosphere = enabled
        refreshCaptureResult(remeasureGlow: false, rerenderSprite: false)
    }

    func beginCaptureDrag() {
        guard resultPlacement != nil else { return }
        isAdjustingCapture = true
    }

    func updateCaptureDrag(to imagePoint: CGPoint) {
        guard isAdjustingCapture else { return }
        resultPlacement?.center = clamped(imagePoint)
    }

    func endCaptureDrag(at imagePoint: CGPoint) {
        guard isAdjustingCapture, var frame = frozen, resultPixelSize.width > 1 else {
            isAdjustingCapture = false
            return
        }
        let point = clamped(imagePoint)
        resultPlacement?.center = point
        let pose = photoPose(frozen: frame, pixelSize: resultPixelSize)
        if let sky = MoonProjection.unproject(point: point, pose: pose, imageSize: resultPixelSize) {
            let offset = MoonProjection.alignmentOffsetDegrees(
                indicatedAzimuth: sky.azimuth,
                indicatedAltitude: sky.altitude,
                uncorrectedAzimuth: frame.moon.azimuth,
                uncorrectedAltitude: frame.moon.altitude
            )
            alignment.azimuthOffsetDegrees = offset.azimuth
            alignment.altitudeOffsetDegrees = offset.altitude
            frame.useTrackedCenter = false
            frame.trackedCenter = nil
            frozen = frame
        }
        isAdjustingCapture = false
        refreshCaptureResult(remeasureGlow: true, rerenderSprite: false)
    }

    func shutter() {
        guard let pose, let moon else {
            captureWithoutMoon()
            return
        }
        let tracked = alignment.visualTrackingEnabled ? coverCenter : nil
        frozen = FrozenFrame(
            moon: moon,
            pose: pose,
            landscapeHorizontalFOV: session.optics()?.landscapeHorizontalFOV ?? pose.horizontalFOV,
            drawBelowHorizon: alignment.drawMoonBelowHorizon,
            location: attitude.flatMap { attitude in
                guard let latitude = attitude.latitudeDegrees, let longitude = attitude.longitudeDegrees else {
                    return nil
                }
                return CLLocation(latitude: latitude, longitude: longitude)
            },
            trackedCenter: tracked,
            useTrackedCenter: tracked != nil,
            previewSize: previewSize
        )
        session.capture { [weak self] image in
            self?.finishCapture(image)
        }
    }

    func saveCapturedPhoto() {
        guard let image = capturedImage else { return }
        let location = frozen?.location
        let imageData = image.jpegData(compressionQuality: 0.95)
        showResult = false
        capturedImage = nil
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor [weak self] in
                    self?.statusMessage = "没有相册权限"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if let imageData {
                    request.addResource(with: .photo, data: imageData, options: nil)
                }
                request.location = location
            } completionHandler: { [weak self] success, _ in
                Task { @MainActor [weak self] in
                    self?.statusMessage = success ? "已保存到相册" : "保存失败"
                }
            }
        }
    }

    func discardCapturedPhoto() {
        captureRenderGeneration &+= 1
        showResult = false
        capturedImage = nil
        capturedBaseImage = nil
        resultSprite = nil
        resultPlacement = nil
        resultGlow = nil
        resultReady = false
        isAdjustingCapture = false
    }

    var overlayPlacement: MoonPlacement? {
        placement
    }

    private func refreshMoon() {
        guard let attitude, let latitude = attitude.latitudeDegrees, let longitude = attitude.longitudeDegrees else {
            return
        }
        let state = MoonEphemeris.state(
            at: Date(),
            latitudeDegrees: latitude,
            longitudeDegrees: longitude,
            altitudeMeters: attitude.altitudeMeters ?? 0,
            applyAtmosphere: true
        )
        uncorrectedMoon = state
        moon = state
        phaseName = state.phaseName
        updateSprite(for: state)
        refreshOverlay()
    }

    private func refreshOverlay() {
        guard previewSize.width > 1, previewSize.height > 1 else {
            clearMoonOverlay()
            return
        }
        guard let attitude else { return }
        if attitude.locationDenied {
            statusMessage = "需要定位才能计算月亮"
            moon = nil
            clearMoonOverlay()
            return
        }
        guard let latitude = attitude.latitudeDegrees, attitude.longitudeDegrees != nil else {
            statusMessage = "正在获取定位…"
            clearMoonOverlay()
            return
        }
        if statusMessage == "正在获取定位…" || statusMessage == "需要定位才能计算月亮" {
            statusMessage = nil
        }
        if !attitude.usingTrueNorth {
            statusMessage = "当前使用磁北，可用校正对齐"
        }
        guard let optics = session.optics() else { return }
        displayZoom = optics.displayZoom
        let fields = MoonProjection.fieldOfView(
            landscapeHorizontalFOV: optics.landscapeHorizontalFOV,
            imageSize: previewSize
        )
        let pose = MoonProjection.pose(
            attitude: attitude.matrix,
            orientation: screenOrientation,
            latitude: SkyAngles.radians(fromDegrees: latitude),
            horizontalFOV: fields.horizontal,
            verticalFOV: fields.vertical
        )
        self.pose = pose
        if moon == nil {
            refreshMoon()
        }
        guard let moon else {
            clearMoonOverlay()
            return
        }
        let corrected = moon.corrected(
            azimuthOffset: activeAzimuthOffset,
            altitudeOffset: activeAltitudeOffset
        )
        guard MoonProjection.shouldDraw(
            altitude: corrected.altitude,
            angularRadius: corrected.angularRadius,
            verticalScale: corrected.verticalScale,
            drawBelowHorizon: alignment.drawMoonBelowHorizon,
            calibrating: false
        ) else {
            clearMoonOverlay(horizon: "月亮在地平线以下")
            return
        }
        horizonMessage = nil
        geometricPlacement = MoonProjection.project(
            azimuth: corrected.azimuth,
            altitude: corrected.altitude,
            angularRadius: corrected.angularRadius,
            axisPositionAngle: corrected.axisPositionAngle,
            pose: pose,
            imageSize: previewSize,
            verticalScale: corrected.verticalScale
        )
        if geometricPlacement == nil {
            coverCenter = nil
            coverRadius = nil
        }
        if let geometricPlacement {
            let next = displayed(from: geometricPlacement)
            if placement == nil || placement!.visiblyDiffers(from: next) {
                placement = next
            }
        } else if placement != nil {
            placement = nil
        }
        publishCoverTarget(force: false)
        publishSceneMetering()
        let guide = MoonProjection.offscreenGuide(
            azimuth: corrected.azimuth,
            altitude: corrected.altitude,
            angularRadius: corrected.angularRadius,
            axisPositionAngle: corrected.axisPositionAngle,
            pose: pose,
            imageSize: previewSize,
            verticalScale: corrected.verticalScale
        )
        if moonGuide != guide {
            moonGuide = guide
        }
    }

    private var activeAzimuthOffset: Double {
        alignment.azimuthOffsetRadians
    }

    private var activeAltitudeOffset: Double {
        alignment.altitudeOffsetRadians
    }

    private func clearTrackingLock() {
        trackMissStarted = nil
        coverCenter = nil
        coverRadius = nil
    }

    private func clearMoonOverlay(horizon: String? = nil) {
        if placement != nil { placement = nil }
        geometricPlacement = nil
        clearTrackingLock()
        if lastTrackingTargetCenter != nil || lastTrackingTargetRadius != nil {
            lastTrackingTargetCenter = nil
            lastTrackingTargetRadius = nil
            session.setCoverTarget(nil)
        }
        if moonGuide != nil { moonGuide = nil }
        if horizonMessage != horizon { horizonMessage = horizon }
        publishSceneMetering()
    }

    private func displayed(from geometric: MoonPlacement) -> MoonPlacement {
        var copy = geometric
        guard alignment.visualTrackingEnabled, let coverCenter else { return copy }
        copy.center = coverCenter
        return copy
    }

    private func applyApparentCover(_ measurement: CoverMeasurement?) {
        guard let measurement else { return }
        if alignment.visualTrackingEnabled, geometricPlacement != nil {
            if let disk = measurement.disk {
                trackMissStarted = nil
                let smoothed = MoonCover.smooth(
                    previous: coverCenter.flatMap { center in
                        coverRadius.map { ApparentDisk(center: center, radius: $0) }
                    },
                    measured: disk
                )
                coverCenter = smoothed?.center
                coverRadius = smoothed?.radius
            } else if coverCenter != nil {
                if trackMissStarted == nil {
                    trackMissStarted = Date()
                }
                if let trackMissStarted, Date().timeIntervalSince(trackMissStarted) >= 1 {
                    self.trackMissStarted = nil
                    coverCenter = nil
                    coverRadius = nil
                }
            }
        }
        guard let geometricPlacement else { return }
        let next = displayed(from: geometricPlacement)
        if placement == nil || placement!.visiblyDiffers(from: next) {
            placement = next
        }
    }

    private func publishCoverTarget(force: Bool) {
        guard alignment.visualTrackingEnabled, let geometricPlacement else {
            if lastTrackingTargetCenter != nil || lastTrackingTargetRadius != nil {
                lastTrackingTargetCenter = nil
                lastTrackingTargetRadius = nil
                session.setCoverTarget(nil)
            }
            return
        }
        let centerMoved = MoonCover.shouldPublishTrackingTarget(
            previous: lastTrackingTargetCenter,
            center: geometricPlacement.center
        )
        let radiusMoved = lastTrackingTargetRadius.map { abs(geometricPlacement.pixelRadius - $0) >= 1 } ?? true
        guard force || centerMoved || radiusMoved else { return }
        lastTrackingTargetCenter = geometricPlacement.center
        lastTrackingTargetRadius = geometricPlacement.pixelRadius
        let preferenceCenter = trackPreferenceOffset.map { offset in
            CGPoint(x: geometricPlacement.center.x + offset.x, y: geometricPlacement.center.y + offset.y)
        }
        let wide = pose.map {
            MoonProjection.pixels(
                forAngle: SkyAngles.radians(fromDegrees: MoonCover.trackingSearchDegrees),
                pose: $0,
                imageSize: previewSize
            )
        } ?? 0
        let searchRadius = max(geometricPlacement.pixelRadius * MoonCover.maxRadiusScale, wide)
        session.setCoverTarget(CoverTarget(
            geometricCenter: geometricPlacement.center,
            geometricRadius: geometricPlacement.pixelRadius,
            searchCenter: geometricPlacement.center,
            searchRadius: max(searchRadius, 1),
            preferenceCenter: preferenceCenter,
            previewSize: previewSize,
            acquire: true,
            sampleColor: false
        ))
    }

    private func publishSceneMetering() {
        let moonPoint: CGPoint?
        moonPoint = placement?.center ?? geometricPlacement?.center
        guard let corners = session.meteringDeviceCorners(moonLayerPoint: moonPoint) else { return }
        guard !sameCorners(corners, meteringCorners) else { return }
        meteringCorners = corners
        session.updateSceneMetering(deviceCorners: corners)
    }

    private func sameCorners(_ lhs: [CGPoint], _ rhs: [CGPoint]?) -> Bool {
        guard let rhs, lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { abs($0.x - $1.x) < 0.004 && abs($0.y - $1.y) < 0.004 }
    }

    private func updateSprite(for state: MoonState) {
        guard let albedo else { return }
        let key = PreviewSpriteKey(
            librationLongitude: state.librationLongitude,
            librationLatitude: state.librationLatitude
        )
        requestedPreviewKey = key
        guard key != previewKey, !renderingSprite else { return }
        renderingSprite = true
        let librationLongitude = state.librationLongitude
        let librationLatitude = state.librationLatitude
        let previewSize = Self.previewSpriteSize
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let preview = MoonImageRenderer.render(
                albedo: albedo,
                phaseAngle: 0,
                brightLimbPositionAngle: 0,
                axisPositionAngle: 0,
                librationLongitude: librationLongitude,
                librationLatitude: librationLatitude,
                earthshine: 0,
                size: previewSize
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.renderingSprite = false
                guard self.requestedPreviewKey == key else {
                    if let moon = self.moon {
                        self.updateSprite(for: moon)
                    }
                    return
                }
                self.sprite = preview
                self.previewKey = key
            }
        }
    }

    private func ingest(_ attitude: DeviceAttitude) {
        pendingAttitude = attitude
        guard !attitudeRefreshScheduled else { return }
        attitudeRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.attitudeRefreshScheduled = false
            guard let attitude = self.pendingAttitude else { return }
            self.pendingAttitude = nil
            self.attitude = attitude
            self.refreshOverlay()
        }
    }

    private func captureWithoutMoon() {
        frozen = nil
        session.capture { [weak self] image in
            self?.finishCapture(image)
        }
    }

    private func finishCapture(_ image: UIImage?) {
        guard let image else {
            statusMessage = "拍照失败"
            return
        }
        let upright = image.uprightImage()
        capturedBaseImage = upright
        capturedImage = upright
        if let cgImage = upright.cgImage {
            resultPixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            resultPixelSize = upright.size
        }
        resultSprite = nil
        resultGlow = nil
        resultPlacement = nil
        captureSpriteKey = nil
        isAdjustingCapture = false
        resultReady = frozen == nil
        showResult = true
        if frozen != nil {
            refreshCaptureResult(remeasureGlow: true, rerenderSprite: true)
        }
    }

    private func refreshCaptureResult(remeasureGlow: Bool, rerenderSprite: Bool) {
        guard let frozen else { return }
        guard let baseImage = capturedBaseImage, let base = baseImage.cgImage else { return }
        let pixelSize = CGSize(width: base.width, height: base.height)
        resultPixelSize = pixelSize
        let corrected = frozen.moon.corrected(
            azimuthOffset: activeAzimuthOffset,
            altitudeOffset: activeAltitudeOffset
        )
        guard MoonProjection.shouldDraw(
            altitude: corrected.altitude,
            angularRadius: corrected.angularRadius,
            verticalScale: corrected.verticalScale,
            drawBelowHorizon: frozen.drawBelowHorizon,
            calibrating: false
        ) else {
            capturedImage = baseImage
            resultPlacement = nil
            resultReady = true
            return
        }
        let pose = photoPose(frozen: frozen, pixelSize: pixelSize)
        let useColor = alignment.simulateAtmosphere
        guard var placement = MoonProjection.project(
            azimuth: corrected.azimuth,
            altitude: corrected.altitude,
            angularRadius: corrected.angularRadius,
            axisPositionAngle: corrected.axisPositionAngle,
            pose: pose,
            imageSize: pixelSize,
            verticalScale: corrected.verticalScale,
            tint: useColor ? corrected.tint : .neutral,
            redDispersion: useColor ? corrected.redDispersion : 0,
            blueDispersion: useColor ? corrected.blueDispersion : 0
        ) else {
            capturedImage = baseImage
            resultPlacement = nil
            resultReady = true
            return
        }
        if frozen.useTrackedCenter,
           let tracked = frozen.trackedCenter,
           frozen.previewSize.width > 1,
           frozen.previewSize.height > 1 {
            let scaleX = pixelSize.width / frozen.previewSize.width
            let scaleY = pixelSize.height / frozen.previewSize.height
            placement.center = CGPoint(x: tracked.x * scaleX, y: tracked.y * scaleY)
        }
        if isAdjustingCapture, let dragged = resultPlacement?.center {
            placement.center = dragged
        }
        resultPlacement = placement
        captureRenderGeneration &+= 1
        let generation = captureRenderGeneration
        let simulatePhase = alignment.simulateMoonPhase
        let spriteKey = CaptureSpriteKey(corrected, simulatePhase: simulatePhase)
        let needsSprite = rerenderSprite || resultSprite == nil || captureSpriteKey != spriteKey
        let albedo = albedo
        let existingSprite = resultSprite
        let existingGlow = resultGlow
        let center = placement.center
        let geometricRadius = placement.pixelRadius
        let captureSize = Self.captureSpriteSize
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sprite: CGImage?
            if needsSprite, let albedo {
                sprite = MoonImageRenderer.render(
                    albedo: albedo,
                    phaseAngle: simulatePhase ? corrected.phaseAngle : 0,
                    brightLimbPositionAngle: corrected.brightLimbPositionAngle,
                    axisPositionAngle: corrected.axisPositionAngle,
                    librationLongitude: corrected.librationLongitude,
                    librationLatitude: corrected.librationLatitude,
                    earthshine: simulatePhase ? corrected.earthshine : 0,
                    size: captureSize
                )
            } else {
                sprite = existingSprite
            }
            var glow = remeasureGlow ? nil : existingGlow
            if remeasureGlow, let pixels = MoonCompositor.rgbaPixels(from: base) {
                glow = MoonCover.measureGlow(
                    pixels: pixels,
                    width: base.width,
                    height: base.height,
                    center: center,
                    geometricRadius: geometricRadius
                )
            }
            let composited = sprite.flatMap { sprite in
                MoonCompositor.composite(
                    base: base,
                    sprite: sprite,
                    center: placement.center,
                    pixelRadius: placement.pixelRadius,
                    rotation: placement.rotation,
                    verticalScale: placement.verticalScale,
                    zenithRotation: placement.zenithRotation,
                    tint: placement.tint,
                    redDispersion: placement.redDispersion,
                    blueDispersion: placement.blueDispersion,
                    glow: glow
                )
            }
            let image = composited.map { UIImage(cgImage: $0, scale: baseImage.scale, orientation: .up) }
            Task { @MainActor [weak self] in
                guard let self, self.captureRenderGeneration == generation else { return }
                if let sprite {
                    self.resultSprite = sprite
                    self.captureSpriteKey = spriteKey
                }
                self.resultGlow = glow
                if let image {
                    self.capturedImage = image
                }
                self.resultReady = true
            }
        }
    }

    private func photoPose(frozen: FrozenFrame, pixelSize: CGSize) -> CameraPose {
        let fields = MoonProjection.fieldOfView(
            landscapeHorizontalFOV: frozen.landscapeHorizontalFOV,
            imageSize: pixelSize
        )
        var pose = frozen.pose
        pose.horizontalFOV = fields.horizontal
        pose.verticalFOV = fields.vertical
        return pose
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), max(resultPixelSize.width - 1, 0)),
            y: min(max(point.y, 0), max(resultPixelSize.height - 1, 0))
        )
    }
}

private struct FrozenFrame {
    var moon: MoonState
    var pose: CameraPose
    var landscapeHorizontalFOV: Double
    var drawBelowHorizon: Bool
    var location: CLLocation?
    var trackedCenter: CGPoint?
    var useTrackedCenter: Bool
    var previewSize: CGSize
}

private struct CaptureSpriteKey: Equatable {
    var phase: Int
    var limb: Int
    var axis: Int
    var librationLongitude: Int
    var librationLatitude: Int
    var earthshine: Int
    var simulatePhase: Bool

    init(_ state: MoonState, simulatePhase: Bool) {
        let phaseAngle = simulatePhase ? state.phaseAngle : 0
        phase = Int((phaseAngle * 180 / .pi) * 2)
        limb = Int((state.brightLimbPositionAngle * 180 / .pi) * 2)
        axis = Int((state.axisPositionAngle * 180 / .pi) * 2)
        librationLongitude = Int((state.librationLongitude * 180 / .pi) * 2)
        librationLatitude = Int((state.librationLatitude * 180 / .pi) * 2)
        earthshine = simulatePhase ? Int((state.earthshine * 20).rounded()) : 0
        self.simulatePhase = simulatePhase
    }
}

private extension ClosedRange where Bound == Float {
    var doubleRange: ClosedRange<Double> { Double(lowerBound)...Double(upperBound) }
}

private extension ScreenOrientation {
    var interfaceOrientation: UIInterfaceOrientation {
        switch self {
        case .portrait: return .portrait
        case .upsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        }
    }
}

private extension UIImage {
    func uprightImage() -> UIImage {
        if imageOrientation == .up { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
