import Foundation

struct MoonTint: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let neutral = MoonTint(red: 1, green: 1, blue: 1)
}

struct AtmosphericAppearance: Equatable {
    var apparentAltitude: Double
    var verticalScale: Double
    var tint: MoonTint
    var redDispersion: Double
    var blueDispersion: Double
}

enum Atmosphere {
    static let clearAerosolOpticalDepth = 0.12

    private static let temperatureCelsius = 10.0
    private static let scaleHeightMeters = 8500.0
    private static let redNanometers = 650.0
    private static let greenNanometers = 550.0
    private static let blueNanometers = 450.0

    static func aerosolOpticalDepth(visibilityKilometers: Double) -> Double {
        guard visibilityKilometers.isFinite, visibilityKilometers > 0 else {
            return clearAerosolOpticalDepth
        }
        return min(max(4.8 / visibilityKilometers, 0.05), 2.5)
    }

    static func refractionRadians(trueAltitude: Double, altitudeMeters: Double) -> Double {
        let degrees = min(max(SkyAngles.degrees(fromRadians: trueAltitude), -1), 89.5)
        let argument = degrees + 10.3 / (degrees + 5.11)
        let arcminutes = 1.02 / tan(SkyAngles.radians(fromDegrees: argument))
        let pressure = pressureHectopascals(altitudeMeters: altitudeMeters)
        let scaled = arcminutes * (pressure / 1010) * (283 / (273 + temperatureCelsius))
        return SkyAngles.radians(fromDegrees: scaled / 60)
    }

    static func appearance(
        trueAltitude: Double,
        angularRadius: Double,
        altitudeMeters: Double,
        aerosolOpticalDepth: Double = clearAerosolOpticalDepth
    ) -> AtmosphericAppearance {
        let upper = trueAltitude + angularRadius + refractionRadians(
            trueAltitude: trueAltitude + angularRadius,
            altitudeMeters: altitudeMeters
        )
        let lower = trueAltitude - angularRadius + refractionRadians(
            trueAltitude: trueAltitude - angularRadius,
            altitudeMeters: altitudeMeters
        )
        let verticalRadius = abs(upper - lower) / 2
        let scale = angularRadius > 1e-8 && verticalRadius.isFinite ? verticalRadius / angularRadius : 1
        let reference = refractionRadians(trueAltitude: trueAltitude, altitudeMeters: altitudeMeters)
        let greenExcess = refractiveExcess(wavelengthNanometers: greenNanometers)
        return AtmosphericAppearance(
            apparentAltitude: SkyAngles.clamp((upper + lower) / 2, -.pi / 2, .pi / 2),
            verticalScale: scale,
            tint: tint(
                apparentAltitude: (upper + lower) / 2,
                altitudeMeters: altitudeMeters,
                aerosolOpticalDepth: aerosolOpticalDepth
            ),
            redDispersion: reference * (refractiveExcess(wavelengthNanometers: redNanometers) / greenExcess - 1),
            blueDispersion: reference * (refractiveExcess(wavelengthNanometers: blueNanometers) / greenExcess - 1)
        )
    }

    private static func pressureHectopascals(altitudeMeters: Double) -> Double {
        1013.25 * exp(-altitudeMeters / scaleHeightMeters)
    }

    private static func refractiveExcess(wavelengthNanometers: Double) -> Double {
        let sigma = 1000 / wavelengthNanometers
        let sigmaSquared = sigma * sigma
        return 8342.13 + 2_406_030 / (130 - sigmaSquared) + 15_997 / (38.9 - sigmaSquared)
    }

    private static func tint(
        apparentAltitude: Double,
        altitudeMeters: Double,
        aerosolOpticalDepth: Double
    ) -> MoonTint {
        let mass = airmass(apparentAltitude: apparentAltitude)
        let pressure = pressureHectopascals(altitudeMeters: altitudeMeters)
        let aerosol = resolvedAerosol(aerosolOpticalDepth)
        let green = transmission(
            wavelengthNanometers: greenNanometers,
            airmass: mass,
            pressure: pressure,
            aerosolOpticalDepth: aerosol
        )
        guard green > 0 else { return .neutral }
        return MoonTint(
            red: transmission(
                wavelengthNanometers: redNanometers,
                airmass: mass,
                pressure: pressure,
                aerosolOpticalDepth: aerosol
            ) / green,
            green: 1,
            blue: transmission(
                wavelengthNanometers: blueNanometers,
                airmass: mass,
                pressure: pressure,
                aerosolOpticalDepth: aerosol
            ) / green
        )
    }

    private static func resolvedAerosol(_ aerosolOpticalDepth: Double) -> Double {
        guard aerosolOpticalDepth.isFinite, aerosolOpticalDepth >= 0 else {
            return clearAerosolOpticalDepth
        }
        return aerosolOpticalDepth
    }

    private static func airmass(apparentAltitude: Double) -> Double {
        let degrees = min(max(SkyAngles.degrees(fromRadians: apparentAltitude), 0), 90)
        let denominator = sin(SkyAngles.radians(fromDegrees: degrees))
            + 0.50572 * pow(degrees + 6.07995, -1.6364)
        guard denominator > 1e-4 else { return 40 }
        return 1 / denominator
    }

    private static func transmission(
        wavelengthNanometers: Double,
        airmass: Double,
        pressure: Double,
        aerosolOpticalDepth: Double
    ) -> Double {
        let lambda = wavelengthNanometers / 1000
        let lambda2 = lambda * lambda
        let lambda4 = lambda2 * lambda2
        let rayleigh = 0.008569 / lambda4 * (1 + 0.0113 / lambda2 + 0.00013 / lambda4) * pressure / 1013.25
        let aerosol = aerosolOpticalDepth * pow(lambda / 0.55, -1.3)
        return exp(-(rayleigh + aerosol) * airmass)
    }
}
