import CoreLocation
import CoreMotion
import Foundation

struct DeviceAttitude: Sendable {
    var matrix: AttitudeMatrix
    var latitudeDegrees: Double?
    var longitudeDegrees: Double?
    var altitudeMeters: Double?
    var locationDenied: Bool
    var usingTrueNorth: Bool
}

final class OrientationService: NSObject, CLLocationManagerDelegate {
    var onUpdate: (@MainActor (DeviceAttitude) -> Void)?

    private let motion = CMMotionManager()
    private let location = CLLocationManager()
    private var latestLocation: CLLocation?
    private var locationDenied = false
    private var usingTrueNorth = false
    private let queue = OperationQueue()

    override init() {
        super.init()
        queue.name = "silly-astro-camera.motion"
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            location.startUpdatingLocation()
        case .denied, .restricted:
            locationDenied = true
            publish(matrix: nil)
        default:
            break
        }
        startMotion()
    }

    func stop() {
        location.stopUpdatingLocation()
        motion.stopDeviceMotionUpdates()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationDenied = false
            location.startUpdatingLocation()
            startMotion()
        case .denied, .restricted:
            locationDenied = true
            latestLocation = nil
            publish(matrix: nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latestLocation = locations.last
        publish(matrix: motion.deviceMotion?.attitude.rotationMatrix)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        publish(matrix: motion.deviceMotion?.attitude.rotationMatrix)
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        let available = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame
        if available.contains(.xTrueNorthZVertical) {
            frame = .xTrueNorthZVertical
            usingTrueNorth = true
        } else if available.contains(.xMagneticNorthZVertical) {
            frame = .xMagneticNorthZVertical
            usingTrueNorth = false
        } else {
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
            guard let self, let rotation = motion?.attitude.rotationMatrix else { return }
            self.publish(matrix: rotation)
        }
    }

    private func publish(matrix: CMRotationMatrix?) {
        let attitude = DeviceAttitude(
            matrix: matrix.map(Self.matrix) ?? AttitudeMatrix(
                m11: 1, m12: 0, m13: 0,
                m21: 0, m22: 1, m23: 0,
                m31: 0, m32: 0, m33: 1
            ),
            latitudeDegrees: latestLocation?.coordinate.latitude,
            longitudeDegrees: latestLocation?.coordinate.longitude,
            altitudeMeters: latestLocation?.altitude,
            locationDenied: locationDenied,
            usingTrueNorth: usingTrueNorth
        )
        let callback = onUpdate
        Task { @MainActor in
            callback?(attitude)
        }
    }

    private static func matrix(_ rotation: CMRotationMatrix) -> AttitudeMatrix {
        AttitudeMatrix(
            m11: rotation.m11, m12: rotation.m12, m13: rotation.m13,
            m21: rotation.m21, m22: rotation.m22, m23: rotation.m23,
            m31: rotation.m31, m32: rotation.m32, m33: rotation.m33
        )
    }
}
