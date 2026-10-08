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
    var isCalibrating = false
    var calibrationCenter: CGPoint?
    var exposureBias = 0.0
    var exposureRange: ClosedRange<Double> = -2...2
    var meteringPoint: CGPoint?
    var capturedImage: UIImage?
    var showResult = false
    var saveMessage: String?

    private var moon: MoonState?
    private var uncorrectedMoon: MoonState?
    private var pose: CameraPose?
    private var previewSize: CGSize = .zero
    private var screenOrientation: ScreenOrientation = .portrait
    private var attitude: DeviceAttitude?
    private var albedo: MoonAlbedo?
    private var spriteKey: SpriteKey?
    private var requestedSpriteKey: SpriteKey?
    private var renderingSprite = false
    private var ephemerisTimer: Timer?
    private var pinchOrigin: Double?
    private var frozen: FrozenFrame?

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
        orientationService.onUpdate = { [weak self] attitude in
            self?.attitude = attitude
            self?.refreshOverlay()
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted {
                    self.session.start()
                    self.orientationService.start()
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
        guard !isCalibrating else { return }
        let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        session.focusAndExpose(atDevicePoint: devicePoint)
        meteringPoint = point
        Task {
            try? await Task.sleep(for: .seconds(1))
            if meteringPoint == point {
                meteringPoint = nil
            }
        }
    }

    func beginCalibration() {
        isCalibrating = true
        calibrationCenter = nil
        refreshOverlay()
    }

    func dragCalibration(to point: CGPoint) {
        calibrationCenter = point
    }

    func endCalibration(at point: CGPoint) {
        calibrationCenter = point
        guard let pose, let uncorrectedMoon,
              let sky = MoonProjection.unproject(point: point, pose: pose, imageSize: previewSize) else {
            return
        }
        let offset = MoonProjection.alignmentOffsetDegrees(
            indicatedAzimuth: sky.azimuth,
            indicatedAltitude: sky.altitude,
            uncorrectedAzimuth: uncorrectedMoon.azimuth,
            uncorrectedAltitude: uncorrectedMoon.altitude
        )
        alignment.azimuthOffsetDegrees = offset.azimuth
        alignment.altitudeOffsetDegrees = offset.altitude
        refreshOverlay()
    }

    func finishCalibration() {
        isCalibrating = false
        calibrationCenter = nil
        refreshOverlay()
    }

    func resetAlignment() {
        alignment.resetAlignment()
        calibrationCenter = nil
        refreshOverlay()
    }

    func shutter() {
        guard let pose, let moon else {
            captureWithoutMoon()
            return
        }
        let corrected = moon.corrected(
            azimuthOffset: alignment.azimuthOffsetRadians,
            altitudeOffset: alignment.altitudeOffsetRadians
        )
        frozen = FrozenFrame(
            moon: corrected,
            pose: pose,
            landscapeHorizontalFOV: session.optics()?.landscapeHorizontalFOV ?? pose.horizontalFOV,
            drawBelowHorizon: alignment.drawMoonBelowHorizon,
            calibrating: isCalibrating,
            sprite: sprite,
            location: attitude.flatMap { attitude in
                guard let latitude = attitude.latitudeDegrees, let longitude = attitude.longitudeDegrees else {
                    return nil
                }
                return CLLocation(latitude: latitude, longitude: longitude)
            }
        )
        session.capture { [weak self] image in
            self?.finishCapture(image)
        }
    }

    func saveCapturedPhoto() {
        guard let capturedImage else { return }
        let location = frozen?.location
        let imageData = capturedImage.jpegData(compressionQuality: 0.95)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor [weak self] in
                    self?.saveMessage = "没有相册权限"
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
                    self?.saveMessage = success ? "已保存到相册" : "保存失败"
                }
            }
        }
    }

    func retake() {
        showResult = false
        capturedImage = nil
        saveMessage = nil
    }

    var overlayPlacement: MoonPlacement? {
        guard var placement else {
            guard isCalibrating, previewSize.width > 0 else { return nil }
            return MoonPlacement(
                center: calibrationCenter ?? CGPoint(x: previewSize.width / 2, y: previewSize.height / 2),
                pixelRadius: fallbackRadius,
                rotation: pose.map { MoonProjection.spriteRotation(pose: $0, axisPositionAngle: moon?.axisPositionAngle ?? 0) } ?? 0
            )
        }
        if isCalibrating, let calibrationCenter {
            placement.center = calibrationCenter
        }
        return placement
    }

    var calibrationReadout: String {
        String(format: "方位 %+.1f°　高度 %+.1f°", alignment.azimuthOffsetDegrees, alignment.altitudeOffsetDegrees)
    }

    private func refreshMoon() {
        guard let attitude, let latitude = attitude.latitudeDegrees, let longitude = attitude.longitudeDegrees else {
            return
        }
        let state = MoonEphemeris.state(
            at: Date(),
            latitudeDegrees: latitude,
            longitudeDegrees: longitude,
            altitudeMeters: attitude.altitudeMeters ?? 0
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
            azimuthOffset: alignment.azimuthOffsetRadians,
            altitudeOffset: alignment.altitudeOffsetRadians
        )
        guard MoonProjection.shouldDraw(
            altitude: corrected.altitude,
            angularRadius: corrected.angularRadius,
            drawBelowHorizon: alignment.drawMoonBelowHorizon,
            calibrating: isCalibrating
        ) else {
            clearMoonOverlay(horizon: "月亮在地平线以下")
            return
        }
        horizonMessage = nil
        placement = MoonProjection.project(
            azimuth: corrected.azimuth,
            altitude: corrected.altitude,
            angularRadius: corrected.angularRadius,
            axisPositionAngle: corrected.axisPositionAngle,
            pose: pose,
            imageSize: previewSize
        )
        if isCalibrating {
            moonGuide = nil
        } else {
            moonGuide = MoonProjection.offscreenGuide(
                azimuth: corrected.azimuth,
                altitude: corrected.altitude,
                angularRadius: corrected.angularRadius,
                axisPositionAngle: corrected.axisPositionAngle,
                pose: pose,
                imageSize: previewSize
            )
        }
    }

    private func clearMoonOverlay(horizon: String? = nil) {
        placement = nil
        moonGuide = nil
        horizonMessage = horizon
    }

    private var fallbackRadius: CGFloat {
        let angular = moon?.angularRadius ?? SkyAngles.radians(fromDegrees: 0.25)
        let fov = pose?.horizontalFOV ?? SkyAngles.radians(fromDegrees: 60)
        guard fov > 0, previewSize.width > 0 else { return 12 }
        return tan(angular) / tan(fov / 2) * previewSize.width / 2
    }

    private func updateSprite(for state: MoonState) {
        let simulatePhase = alignment.simulateMoonPhase
        let key = SpriteKey(state, simulatePhase: simulatePhase)
        requestedSpriteKey = key
        guard key != spriteKey, !renderingSprite, let albedo else { return }
        renderingSprite = true
        let phaseAngle = simulatePhase ? state.phaseAngle : 0
        let brightLimb = state.brightLimbPositionAngle
        let axis = state.axisPositionAngle
        let librationLongitude = state.librationLongitude
        let librationLatitude = state.librationLatitude
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = MoonImageRenderer.render(
                albedo: albedo,
                phaseAngle: phaseAngle,
                brightLimbPositionAngle: brightLimb,
                axisPositionAngle: axis,
                librationLongitude: librationLongitude,
                librationLatitude: librationLatitude,
                size: 2048
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.renderingSprite = false
                if self.requestedSpriteKey == key {
                    self.sprite = image
                    self.spriteKey = key
                }
                if let moon = self.moon {
                    self.updateSprite(for: moon)
                }
            }
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
        capturedImage = composite(image) ?? image
        showResult = true
    }

    private func composite(_ image: UIImage) -> UIImage? {
        guard let frozen, let sprite = frozen.sprite ?? sprite else { return image }
        let upright = image.uprightImage()
        guard let base = upright.cgImage else { return image }
        let pixelSize = CGSize(width: base.width, height: base.height)
        let fields = MoonProjection.fieldOfView(
            landscapeHorizontalFOV: frozen.landscapeHorizontalFOV,
            imageSize: pixelSize
        )
        var pose = frozen.pose
        pose.horizontalFOV = fields.horizontal
        pose.verticalFOV = fields.vertical
        guard MoonProjection.shouldDraw(
            altitude: frozen.moon.altitude,
            angularRadius: frozen.moon.angularRadius,
            drawBelowHorizon: frozen.drawBelowHorizon,
            calibrating: frozen.calibrating
        ) else { return upright }
        guard let placement = MoonProjection.project(
            azimuth: frozen.moon.azimuth,
            altitude: frozen.moon.altitude,
            angularRadius: frozen.moon.angularRadius,
            axisPositionAngle: frozen.moon.axisPositionAngle,
            pose: pose,
            imageSize: pixelSize
        ), let composited = MoonCompositor.composite(
            base: base,
            sprite: sprite,
            center: placement.center,
            pixelRadius: placement.pixelRadius,
            rotation: placement.rotation
        ) else { return upright }
        return UIImage(cgImage: composited, scale: upright.scale, orientation: .up)
    }
}

private struct FrozenFrame {
    var moon: MoonState
    var pose: CameraPose
    var landscapeHorizontalFOV: Double
    var drawBelowHorizon: Bool
    var calibrating: Bool
    var sprite: CGImage?
    var location: CLLocation?
}

private struct SpriteKey: Equatable {
    var phase: Int
    var limb: Int
    var axis: Int
    var librationLongitude: Int
    var librationLatitude: Int
    var simulatePhase: Bool

    init(_ state: MoonState, simulatePhase: Bool) {
        let phaseAngle = simulatePhase ? state.phaseAngle : 0
        phase = Int((phaseAngle * 180 / .pi) * 2)
        limb = Int((state.brightLimbPositionAngle * 180 / .pi) * 2)
        axis = Int((state.axisPositionAngle * 180 / .pi) * 2)
        librationLongitude = Int((state.librationLongitude * 180 / .pi) * 2)
        librationLatitude = Int((state.librationLatitude * 180 / .pi) * 2)
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
