import AVFoundation
import CoreMedia
import UIKit

final class CameraSession: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "silly-astro-camera.capture")
    private let videoQueue = DispatchQueue(label: "silly-astro-camera.frames")
    private var device: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var photoHandler: (@MainActor (UIImage?) -> Void)?
    private var configured = false
    private var exposureBias: Float = 0
    private var interfaceOrientation: UIInterfaceOrientation = .portrait
    private var sceneMeterCorners: [CGPoint]?
    private var appliedMeterRect: CGRect?
    private var manualMetering = false
    private var coverTarget: CoverTarget?
    private var lastAnalysisSeconds = -1.0
    private var sentEmptyCover = true

    var onConfigured: (@MainActor (String?) -> Void)?
    var onZoom: (@MainActor (Double) -> Void)?
    var onApparentCover: (@MainActor (ApparentDisk?) -> Void)?

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        previewLayer.videoGravity = .resizeAspect
        previewLayer.session = session
        updateOrientation(interfaceOrientation)
    }

    func updateOrientation(_ orientation: UIInterfaceOrientation) {
        interfaceOrientation = orientation
        sessionQueue.async { [weak self] in
            self?.applyOrientation(orientation)
        }
    }

    func setDisplayZoom(_ zoom: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            let multiplier = Double(device.displayVideoZoomFactorMultiplier)
            guard multiplier > 0 else { return }
            let minimum = Double(device.minAvailableVideoZoomFactor)
            let maximum = Double(device.maxAvailableVideoZoomFactor)
            let deviceZoom = min(max(zoom / multiplier, minimum), maximum)
            self.configure(device) {
                device.videoZoomFactor = deviceZoom
            }
            self.appliedMeterRect = nil
            self.applyAutomaticExposure(on: device)
            self.publishZoom(device)
        }
    }

    func setExposureBias(_ bias: Float) {
        exposureBias = bias
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.applyAutomaticExposure(on: device)
        }
    }

    func exposureLimits() -> ClosedRange<Float> {
        guard let device else { return -2...2 }
        return device.minExposureTargetBias...device.maxExposureTargetBias
    }

    func focusAndExpose(atDevicePoint point: CGPoint) {
        let clamped = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.manualMetering = true
            self.appliedMeterRect = nil
            self.configure(device) {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = clamped
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = clamped
                }
            }
            self.applyAutomaticExposure(on: device)
        }
    }

    func endManualMetering() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.manualMetering = false
            self.appliedMeterRect = nil
            guard let device = self.device else { return }
            self.applyAutomaticExposure(on: device)
        }
    }

    func meteringDeviceCorners(moonLayerPoint: CGPoint?) -> [CGPoint]? {
        guard let layer = previewLayer, layer.bounds.width > 1, layer.bounds.height > 1 else { return nil }
        let rect = SceneMetering.previewRectangle(moonCenter: moonLayerPoint, previewSize: layer.bounds.size)
        return [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ].map { layer.captureDevicePointConverted(fromLayerPoint: $0) }
    }

    func updateSceneMetering(deviceCorners: [CGPoint]) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.sceneMeterCorners = deviceCorners
            guard !self.manualMetering, let device = self.device else { return }
            self.applyAutomaticExposure(on: device)
        }
    }

    func setCoverTarget(center: CGPoint?, radius: CGFloat, previewSize: CGSize) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            guard let center, radius > 0, previewSize.width > 1, previewSize.height > 1 else {
                self.coverTarget = nil
                self.publishCover(nil)
                return
            }
            self.coverTarget = CoverTarget(center: center, radius: radius, previewSize: previewSize)
        }
    }

    func optics() -> (landscapeHorizontalFOV: Double, displayZoom: Double)? {
        guard let device else { return nil }
        let zoom = max(Double(device.videoZoomFactor), 0.01)
        let format = device.activeFormat
        var base = Double(format.videoFieldOfView(for: .ratio4x3, geometricDistortionCorrected: true))
        if base < 1 {
            base = Double(format.geometricDistortionCorrectedVideoFieldOfView)
        }
        if base < 1 {
            base = Double(format.videoFieldOfView)
        }
        guard base > 1 else { return nil }
        let field = MoonProjection.zoomedFieldOfView(
            baseLandscapeHorizontalFOV: base * .pi / 180,
            zoom: zoom
        )
        let display = zoom * Double(device.displayVideoZoomFactorMultiplier)
        return (field, display)
    }

    func capture(completion: @escaping @MainActor (UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.device != nil else {
                Task { @MainActor in
                    completion(nil)
                }
                return
            }
            self.photoHandler = completion
            let settings = AVCapturePhotoSettings()
            if self.photoOutput.supportedFlashModes.contains(.off) {
                settings.flashMode = .off
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        let handler = photoHandler
        photoHandler = nil
        Task { @MainActor in
            handler?(image)
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let device = Self.backCamera(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            let callback = onConfigured
            Task { @MainActor in
                callback?("此设备没有可用的后置相机")
            }
            return
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        self.device = device
        configure(device) {
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = true
            }
        }
        selectPhotoDimensions(on: device)
        applyAutomaticExposure(on: device)
        session.commitConfiguration()
        applyOrientation(interfaceOrientation)
        publishZoom(device)
        let callback = onConfigured
        Task { @MainActor in
            callback?(nil)
        }
    }

    private func applyOrientation(_ orientation: UIInterfaceOrientation) {
        let angle = videoAngle(for: orientation)
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        guard let device else { return }
        let aspect: AVCaptureDevice.AspectRatio = orientation.isPortrait ? .ratio3x4 : .ratio4x3
        guard device.activeFormat.supportedDynamicAspectRatios.contains(aspect) else { return }
        configure(device) {
            device.setDynamicAspectRatio(aspect) { [weak self] _, _ in
                self?.sessionQueue.async {
                    guard let self, let device = self.device else { return }
                    self.appliedMeterRect = nil
                    self.applyAutomaticExposure(on: device)
                }
            }
        }
    }

    private func applyAutomaticExposure(on device: AVCaptureDevice) {
        configure(device) {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            if !self.manualMetering, device.isExposureRectOfInterestSupported, let corners = self.sceneMeterCorners {
                let rect = SceneMetering.clampedDeviceRect(
                    from: corners,
                    minimumSize: device.minExposureRectOfInterestSize
                )
                if self.appliedMeterRect != rect {
                    device.exposureRectOfInterest = rect
                    self.appliedMeterRect = rect
                }
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            let bias = min(max(self.exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(bias, completionHandler: nil)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if seconds.isFinite, lastAnalysisSeconds >= 0, seconds - lastAnalysisSeconds < 0.12 { return }
        if seconds.isFinite { lastAnalysisSeconds = seconds }
        guard let target = coverTarget else {
            publishCover(nil)
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let disk = MoonCover.measure(
            pixelBuffer: buffer,
            previewCenter: target.center,
            previewRadius: target.radius,
            previewSize: target.previewSize
        )
        publishCover(disk)
    }

    private func publishCover(_ disk: ApparentDisk?) {
        if disk == nil {
            guard !sentEmptyCover else { return }
            sentEmptyCover = true
        } else {
            sentEmptyCover = false
        }
        let callback = onApparentCover
        Task { @MainActor in
            callback?(disk)
        }
    }

    private func selectPhotoDimensions(on device: AVCaptureDevice) {
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions
        let best = dimensions.max { lhs, rhs in
            let leftScore = photoScore(lhs)
            let rightScore = photoScore(rhs)
            if leftScore == rightScore {
                return lhs.width * lhs.height < rhs.width * rhs.height
            }
            return leftScore < rightScore
        }
        if let best {
            photoOutput.maxPhotoDimensions = best
        }
    }

    private func photoScore(_ dimensions: CMVideoDimensions) -> Int {
        let longSide = max(dimensions.width, dimensions.height)
        let shortSide = min(dimensions.width, dimensions.height)
        guard shortSide > 0 else { return 0 }
        let aspect = Double(longSide) / Double(shortSide)
        return abs(aspect - 4.0 / 3.0) < 0.03 ? 1 : 0
    }

    private func configure(_ device: AVCaptureDevice, _ body: () -> Void) {
        do {
            try device.lockForConfiguration()
            body()
            device.unlockForConfiguration()
        } catch {
            return
        }
    }

    private func publishZoom(_ device: AVCaptureDevice) {
        let display = Double(device.videoZoomFactor * device.displayVideoZoomFactorMultiplier)
        let callback = onZoom
        Task { @MainActor in
            callback?(display)
        }
    }

    private func videoAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .landscapeRight:
            return 0
        case .portrait:
            return 90
        case .landscapeLeft:
            return 180
        case .portraitUpsideDown:
            return 270
        default:
            return 90
        }
    }

    private struct CoverTarget {
        var center: CGPoint
        var radius: CGFloat
        var previewSize: CGSize
    }

    private static func backCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera,
        ]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return nil
    }
}
