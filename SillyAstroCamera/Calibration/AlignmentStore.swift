import Foundation
import Observation

@Observable
final class AlignmentStore {
    private let defaults: UserDefaults
    private let azimuthKey = "alignment.azimuthOffsetDegrees"
    private let altitudeKey = "alignment.altitudeOffsetDegrees"
    private let belowHorizonKey = "alignment.drawMoonBelowHorizon"
    private let simulatePhaseKey = "alignment.simulateMoonPhase"
    private let simulateAtmosphereKey = "alignment.simulateAtmosphere"

    var azimuthOffsetDegrees: Double {
        didSet { defaults.set(azimuthOffsetDegrees, forKey: azimuthKey) }
    }

    var altitudeOffsetDegrees: Double {
        didSet { defaults.set(altitudeOffsetDegrees, forKey: altitudeKey) }
    }

    var drawMoonBelowHorizon: Bool {
        didSet { defaults.set(drawMoonBelowHorizon, forKey: belowHorizonKey) }
    }

    var simulateMoonPhase: Bool {
        didSet { defaults.set(simulateMoonPhase, forKey: simulatePhaseKey) }
    }

    var simulateAtmosphere: Bool {
        didSet { defaults.set(simulateAtmosphere, forKey: simulateAtmosphereKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        azimuthOffsetDegrees = defaults.object(forKey: azimuthKey) as? Double ?? 0
        altitudeOffsetDegrees = defaults.object(forKey: altitudeKey) as? Double ?? 0
        drawMoonBelowHorizon = defaults.object(forKey: belowHorizonKey) as? Bool ?? false
        simulateMoonPhase = defaults.object(forKey: simulatePhaseKey) as? Bool ?? true
        simulateAtmosphere = defaults.object(forKey: simulateAtmosphereKey) as? Bool ?? true
    }

    func resetAlignment() {
        azimuthOffsetDegrees = 0
        altitudeOffsetDegrees = 0
    }

    var azimuthOffsetRadians: Double {
        SkyAngles.radians(fromDegrees: azimuthOffsetDegrees)
    }

    var altitudeOffsetRadians: Double {
        SkyAngles.radians(fromDegrees: altitudeOffsetDegrees)
    }
}
