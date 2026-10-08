import Foundation
import simd

struct MoonState: Equatable {
    var azimuth: Double
    var altitude: Double
    var angularRadius: Double
    var illuminatedFraction: Double
    var phaseAngle: Double
    var brightLimbPositionAngle: Double
    var axisPositionAngle: Double
    var librationLongitude: Double
    var librationLatitude: Double
    var distanceKilometers: Double
    var waxing: Bool

    var isEntirelyBelowHorizon: Bool {
        altitude < -angularRadius
    }

    var phaseName: String {
        let illuminated = illuminatedFraction
        if illuminated >= 0.98 {
            return "满月"
        }
        if illuminated <= 0.02 {
            return "新月"
        }
        if waxing {
            if illuminated < 0.35 { return "峨眉月" }
            if illuminated < 0.65 { return "上弦月" }
            return "盈凸月"
        }
        if illuminated < 0.35 { return "残月" }
        if illuminated < 0.65 { return "下弦月" }
        return "亏凸月"
    }

    func corrected(azimuthOffset: Double, altitudeOffset: Double) -> MoonState {
        var copy = self
        copy.azimuth = SkyAngles.wrapPi(azimuth + azimuthOffset)
        copy.altitude = SkyAngles.clamp(altitude + altitudeOffset, -.pi / 2, .pi / 2)
        return copy
    }
}

enum MoonEphemeris {
    private static let moonRadiusKilometers = 1737.4
    private static let earthEquatorialRadiusKilometers = 6378.14
    private static let astronomicalUnitKilometers = 149_597_870.7

    static func julianDate(from date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        var year = components.year ?? 2000
        var month = components.month ?? 1
        let day = Double(components.day ?? 1)
            + (Double(components.hour ?? 0)
                + (Double(components.minute ?? 0)
                    + (Double(components.second ?? 0) + Double(components.nanosecond ?? 0) / 1e9) / 60)
                / 60)
            / 24
        if month <= 2 {
            year -= 1
            month += 12
        }
        let century = year / 100
        let gregorian = 2 - century + century / 4
        return floor(365.25 * Double(year + 4716))
            + floor(30.6001 * Double(month + 1))
            + day
            + Double(gregorian)
            - 1524.5
    }

    static func state(
        at date: Date,
        latitudeDegrees: Double,
        longitudeDegrees: Double,
        altitudeMeters: Double
    ) -> MoonState {
        let julian = julianDate(from: date)
        let centuries = (julian - 2_451_545.0) / 36_525
        let arguments = fundamentalArguments(centuries: centuries)
        let sun = sunPosition(centuries: centuries)
        let moon = moonEcliptic(centuries: centuries, arguments: arguments)
        let obliquity = meanObliquity(centuries: centuries, nodeDegrees: arguments.node)

        let moonEquatorial = equatorial(
            longitude: moon.longitude,
            latitude: moon.latitude,
            obliquity: obliquity
        )
        let sunEquatorial = equatorial(
            longitude: sun.longitude,
            latitude: 0,
            obliquity: obliquity
        )
        let sidereal = greenwichSiderealDegrees(julianDate: julian, centuries: centuries)
        let latitude = SkyAngles.radians(fromDegrees: latitudeDegrees)
        let longitude = SkyAngles.radians(fromDegrees: longitudeDegrees)
        let topocentric = topocentricEquatorial(
            rightAscension: moonEquatorial.rightAscension,
            declination: moonEquatorial.declination,
            distanceKilometers: moon.distance,
            latitude: latitude,
            longitude: longitude,
            altitudeMeters: altitudeMeters,
            greenwichSidereal: SkyAngles.radians(fromDegrees: sidereal)
        )
        let horizontal = horizontalCoordinates(
            hourAngle: topocentric.hourAngle,
            declination: topocentric.declination,
            latitude: latitude
        )
        let phase = phaseGeometry(
            sunRightAscension: sunEquatorial.rightAscension,
            sunDeclination: sunEquatorial.declination,
            sunDistanceAU: sun.distanceAU,
            moonRightAscension: topocentric.rightAscension,
            moonDeclination: topocentric.declination,
            moonDistanceKilometers: moon.distance
        )
        let orientation = lunarOrientation(
            moonLongitude: moon.longitude,
            moonLatitude: moon.latitude,
            meanLongitude: arguments.meanLongitude,
            node: SkyAngles.radians(fromDegrees: arguments.node),
            obliquity: obliquity
        )
        let elongation = SkyAngles.wrap360(
            SkyAngles.degrees(fromRadians: moon.longitude - sun.longitude)
        )
        return MoonState(
            azimuth: horizontal.azimuth,
            altitude: horizontal.altitude,
            angularRadius: asin(moonRadiusKilometers / moon.distance),
            illuminatedFraction: (1 + cos(phase.phaseAngle)) / 2,
            phaseAngle: phase.phaseAngle,
            brightLimbPositionAngle: phase.brightLimbPositionAngle,
            axisPositionAngle: orientation.axisPositionAngle,
            librationLongitude: orientation.librationLongitude,
            librationLatitude: orientation.librationLatitude,
            distanceKilometers: moon.distance,
            waxing: elongation < 180
        )
    }

    static func geocentricEcliptic(at date: Date) -> (longitude: Double, latitude: Double, distance: Double) {
        let julian = julianDate(from: date)
        let centuries = (julian - 2_451_545.0) / 36_525
        let moon = moonEcliptic(centuries: centuries, arguments: fundamentalArguments(centuries: centuries))
        return (
            SkyAngles.degrees(fromRadians: moon.longitude),
            SkyAngles.degrees(fromRadians: moon.latitude),
            moon.distance
        )
    }

    static func horizontalCoordinates(
        hourAngle: Double,
        declination: Double,
        latitude: Double
    ) -> (azimuth: Double, altitude: Double) {
        let sinAltitude = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle)
        let altitude = asin(SkyAngles.clamp(sinAltitude, -1, 1))
        let azimuthFromSouth = atan2(
            sin(hourAngle),
            cos(hourAngle) * sin(latitude) - tan(declination) * cos(latitude)
        )
        return (SkyAngles.wrapPi(azimuthFromSouth + .pi), altitude)
    }

    private struct Arguments {
        var meanLongitude: Double
        var elongation: Double
        var sunAnomaly: Double
        var moonAnomaly: Double
        var latitudeArgument: Double
        var node: Double
    }

    private static func fundamentalArguments(centuries T: Double) -> Arguments {
        let t2 = T * T
        let t3 = t2 * T
        let t4 = t3 * T
        return Arguments(
            meanLongitude: SkyAngles.radians(fromDegrees: SkyAngles.wrap360(
                218.3164477 + 481_267.88123421 * T - 0.0015786 * t2 + t3 / 538_841 - t4 / 65_194_000
            )),
            elongation: SkyAngles.radians(fromDegrees: SkyAngles.wrap360(
                297.8501921 + 445_267.1114034 * T - 0.0018819 * t2 + t3 / 545_868 - t4 / 113_065_000
            )),
            sunAnomaly: SkyAngles.radians(fromDegrees: SkyAngles.wrap360(
                357.5291092 + 35_999.0502909 * T - 0.0001536 * t2 + t3 / 24_490_000
            )),
            moonAnomaly: SkyAngles.radians(fromDegrees: SkyAngles.wrap360(
                134.9633964 + 477_198.8675055 * T + 0.0087414 * t2 + t3 / 69_699 - t4 / 14_712_000
            )),
            latitudeArgument: SkyAngles.radians(fromDegrees: SkyAngles.wrap360(
                93.2720950 + 483_202.0175233 * T - 0.0036539 * t2 - t3 / 3_526_000 + t4 / 863_310_000
            )),
            node: SkyAngles.wrap360(125.04452 - 1934.136261 * T + 0.0020708 * t2 + t3 / 450_000)
        )
    }

    private struct SunPosition {
        var longitude: Double
        var distanceAU: Double
    }

    private static func sunPosition(centuries T: Double) -> SunPosition {
        let t2 = T * T
        let meanLongitude = SkyAngles.radians(fromDegrees: SkyAngles.wrap360(
            280.46646 + 36_000.76983 * T + 0.0003032 * t2
        ))
        let anomaly = SkyAngles.radians(fromDegrees: SkyAngles.wrap360(
            357.52911 + 35_999.05029 * T - 0.0001537 * t2
        ))
        let eccentricity = 0.016708634 - 0.000042037 * T - 0.0000001267 * t2
        let equation = SkyAngles.radians(fromDegrees:
            (1.914602 - 0.004817 * T - 0.000014 * t2) * sin(anomaly)
                + (0.019993 - 0.000101 * T) * sin(2 * anomaly)
                + 0.000289 * sin(3 * anomaly)
        )
        let trueLongitude = meanLongitude + equation
        let node = SkyAngles.radians(fromDegrees: SkyAngles.wrap360(125.04 - 1934.136 * T))
        let apparent = trueLongitude
            - SkyAngles.radians(fromDegrees: 0.00569 + 0.00478 * sin(node))
        let distance = (1.000001018 * (1 - eccentricity * eccentricity))
            / (1 + eccentricity * cos(anomaly + equation))
        return SunPosition(longitude: apparent, distanceAU: distance)
    }

    private struct MoonEcliptic {
        var longitude: Double
        var latitude: Double
        var distance: Double
    }

    private static func moonEcliptic(centuries T: Double, arguments: Arguments) -> MoonEcliptic {
        let eccentricity = 1 - 0.002516 * T - 0.0000074 * T * T
        var longitudeSum = 0.0
        var latitudeSum = 0.0
        var distanceSum = 0.0
        for term in longitudeTerms {
            let angle = Double(term.0) * arguments.elongation
                + Double(term.1) * arguments.sunAnomaly
                + Double(term.2) * arguments.moonAnomaly
                + Double(term.3) * arguments.latitudeArgument
            let factor = solarEccentricityFactor(sunAnomalyMultiplier: term.1, eccentricity: eccentricity)
            longitudeSum += term.4 * factor * sin(angle)
            distanceSum += term.5 * factor * cos(angle)
        }
        for term in latitudeTerms {
            let angle = Double(term.0) * arguments.elongation
                + Double(term.1) * arguments.sunAnomaly
                + Double(term.2) * arguments.moonAnomaly
                + Double(term.3) * arguments.latitudeArgument
            let factor = solarEccentricityFactor(sunAnomalyMultiplier: term.1, eccentricity: eccentricity)
            latitudeSum += term.4 * factor * sin(angle)
        }
        let a1 = SkyAngles.radians(fromDegrees: SkyAngles.wrap360(119.75 + 131.849 * T))
        let a2 = SkyAngles.radians(fromDegrees: SkyAngles.wrap360(53.09 + 479_264.290 * T))
        let a3 = SkyAngles.radians(fromDegrees: SkyAngles.wrap360(313.45 + 481_266.484 * T))
        longitudeSum += 3958 * sin(a1)
            + 1962 * sin(arguments.meanLongitude - arguments.latitudeArgument)
            + 318 * sin(a2)
        latitudeSum += -2235 * sin(arguments.meanLongitude)
            + 382 * sin(a3)
            + 175 * sin(a1 - arguments.latitudeArgument)
            + 175 * sin(a1 + arguments.latitudeArgument)
            + 127 * sin(arguments.meanLongitude - arguments.moonAnomaly)
            - 115 * sin(arguments.meanLongitude + arguments.moonAnomaly)

        let nutation = -17.20 * sin(SkyAngles.radians(fromDegrees: arguments.node)) / 3600
        let longitude = arguments.meanLongitude
            + SkyAngles.radians(fromDegrees: longitudeSum / 1_000_000 + nutation)
        let latitude = SkyAngles.radians(fromDegrees: latitudeSum / 1_000_000)
        let distance = 385_000.56 + distanceSum / 1000
        return MoonEcliptic(longitude: longitude, latitude: latitude, distance: distance)
    }

    private static func solarEccentricityFactor(sunAnomalyMultiplier: Int, eccentricity: Double) -> Double {
        switch abs(sunAnomalyMultiplier) {
        case 1: return eccentricity
        case 2: return eccentricity * eccentricity
        default: return 1
        }
    }

    private static func meanObliquity(centuries T: Double, nodeDegrees: Double) -> Double {
        let t2 = T * T
        let t3 = t2 * T
        let mean = 23.439291111 - 0.013004166 * T - 0.00000016388 * t2 + 0.0000005036 * t3
        let nutation = 9.20 * cos(SkyAngles.radians(fromDegrees: nodeDegrees)) / 3600
        return SkyAngles.radians(fromDegrees: mean + nutation)
    }

    private static func equatorial(
        longitude: Double,
        latitude: Double,
        obliquity: Double
    ) -> (rightAscension: Double, declination: Double) {
        let rightAscension = atan2(
            sin(longitude) * cos(obliquity) - tan(latitude) * sin(obliquity),
            cos(longitude)
        )
        let declination = asin(SkyAngles.clamp(
            sin(latitude) * cos(obliquity) + cos(latitude) * sin(obliquity) * sin(longitude),
            -1,
            1
        ))
        return (SkyAngles.wrapPi(rightAscension), declination)
    }

    private static func greenwichSiderealDegrees(julianDate: Double, centuries: Double) -> Double {
        let t2 = centuries * centuries
        let t3 = t2 * centuries
        return SkyAngles.wrap360(
            280.46061837
                + 360.98564736629 * (julianDate - 2_451_545.0)
                + 0.000387933 * t2
                - t3 / 38_710_000
        )
    }

    private static func topocentricEquatorial(
        rightAscension: Double,
        declination: Double,
        distanceKilometers: Double,
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double,
        greenwichSidereal: Double
    ) -> (rightAscension: Double, declination: Double, hourAngle: Double) {
        let flattening = 0.99664719
        let radius = altitudeMeters / 1_000 / earthEquatorialRadiusKilometers
        let reducedLatitude = atan(flattening * tan(latitude))
        let rhoSin = flattening * sin(reducedLatitude) + radius * sin(latitude)
        let rhoCos = cos(reducedLatitude) + radius * cos(latitude)
        let parallax = asin(SkyAngles.clamp(earthEquatorialRadiusKilometers / distanceKilometers, -1, 1))
        let hourAngle = SkyAngles.wrapPi(greenwichSidereal + longitude - rightAscension)
        let cosDeclination = cos(declination) - rhoCos * sin(parallax) * cos(hourAngle)
        let deltaRightAscension = atan2(
            -rhoCos * sin(parallax) * sin(hourAngle),
            cosDeclination
        )
        let correctedRightAscension = SkyAngles.wrapPi(rightAscension + deltaRightAscension)
        let correctedDeclination = atan2(
            (sin(declination) - rhoSin * sin(parallax)) * cos(deltaRightAscension),
            cosDeclination
        )
        let correctedHourAngle = SkyAngles.wrapPi(greenwichSidereal + longitude - correctedRightAscension)
        return (correctedRightAscension, correctedDeclination, correctedHourAngle)
    }

    private static func phaseGeometry(
        sunRightAscension: Double,
        sunDeclination: Double,
        sunDistanceAU: Double,
        moonRightAscension: Double,
        moonDeclination: Double,
        moonDistanceKilometers: Double
    ) -> (phaseAngle: Double, brightLimbPositionAngle: Double) {
        let elongationCos = sin(sunDeclination) * sin(moonDeclination)
            + cos(sunDeclination) * cos(moonDeclination) * cos(sunRightAscension - moonRightAscension)
        let elongation = acos(SkyAngles.clamp(elongationCos, -1, 1))
        let moonDistanceAU = moonDistanceKilometers / astronomicalUnitKilometers
        let phaseAngle = atan2(
            sunDistanceAU * sin(elongation),
            moonDistanceAU - sunDistanceAU * cos(elongation)
        )
        let brightLimb = atan2(
            cos(sunDeclination) * sin(sunRightAscension - moonRightAscension),
            sin(sunDeclination) * cos(moonDeclination)
                - cos(sunDeclination) * sin(moonDeclination) * cos(sunRightAscension - moonRightAscension)
        )
        return (phaseAngle, brightLimb)
    }

    private static func lunarOrientation(
        moonLongitude: Double,
        moonLatitude: Double,
        meanLongitude: Double,
        node: Double,
        obliquity: Double
    ) -> (librationLongitude: Double, librationLatitude: Double, axisPositionAngle: Double) {
        let inclination = SkyAngles.radians(fromDegrees: 1.54242)
        let lunarNorth = simd_normalize(SIMD3<Double>(
            -sin(inclination) * sin(node),
            sin(inclination) * cos(node),
            cos(inclination)
        ))
        let moon = simd_normalize(SIMD3<Double>(
            cos(moonLatitude) * cos(moonLongitude),
            cos(moonLatitude) * sin(moonLongitude),
            sin(moonLatitude)
        ))
        let meanToEarth = SIMD3<Double>(-cos(meanLongitude), -sin(meanLongitude), 0)
        var primeMeridian = meanToEarth - lunarNorth * simd_dot(meanToEarth, lunarNorth)
        let meridianLength = simd_length(primeMeridian)
        if meridianLength < 1e-8 {
            primeMeridian = SIMD3(1, 0, 0)
        } else {
            primeMeridian /= meridianLength
        }
        let lunarEast = simd_normalize(simd_cross(lunarNorth, primeMeridian))
        let toEarth = -moon
        let librationLatitude = asin(SkyAngles.clamp(simd_dot(toEarth, lunarNorth), -1, 1))
        let librationLongitude = atan2(simd_dot(toEarth, lunarEast), simd_dot(toEarth, primeMeridian))

        let moonEquatorial = eclipticToEquatorial(moon, obliquity: obliquity)
        let poleEquatorial = eclipticToEquatorial(lunarNorth, obliquity: obliquity)
        let celestialNorth = SIMD3<Double>(0, 0, 1)
        var northOnSky = celestialNorth - moonEquatorial * simd_dot(celestialNorth, moonEquatorial)
        let northLength = simd_length(northOnSky)
        let axisPositionAngle: Double
        if northLength < 1e-8 {
            axisPositionAngle = 0
        } else {
            northOnSky /= northLength
            let eastOnSky = simd_normalize(simd_cross(moonEquatorial, northOnSky))
            var poleOnSky = poleEquatorial - moonEquatorial * simd_dot(poleEquatorial, moonEquatorial)
            let poleLength = simd_length(poleOnSky)
            if poleLength < 1e-8 {
                axisPositionAngle = 0
            } else {
                poleOnSky /= poleLength
                axisPositionAngle = atan2(simd_dot(poleOnSky, eastOnSky), simd_dot(poleOnSky, northOnSky))
            }
        }
        return (librationLongitude, librationLatitude, axisPositionAngle)
    }

    private static func eclipticToEquatorial(_ vector: SIMD3<Double>, obliquity: Double) -> SIMD3<Double> {
        let cosine = cos(obliquity)
        let sine = sin(obliquity)
        return SIMD3(vector.x, cosine * vector.y - sine * vector.z, sine * vector.y + cosine * vector.z)
    }

    // Meeus, Astronomical Algorithms, chapter 47. Coefficients are in 0.000001° and 0.001 km.
    private static let longitudeTerms: [(Int, Int, Int, Int, Double, Double)] = [
        (0, 0, 1, 0, 6_288_774, -20_905_355),
        (2, 0, -1, 0, 1_274_027, -3_699_111),
        (2, 0, 0, 0, 658_314, -2_955_968),
        (0, 0, 2, 0, 213_618, -569_925),
        (0, 1, 0, 0, -185_116, 48_888),
        (0, 0, 0, 2, -114_332, -3_149),
        (2, 0, -2, 0, 58_793, 246_158),
        (2, -1, -1, 0, 57_066, -152_138),
        (2, 0, 1, 0, 53_322, -170_733),
        (2, -1, 0, 0, 45_758, -204_586),
        (0, 1, -1, 0, -40_923, -129_620),
        (1, 0, 0, 0, -34_720, 108_743),
        (0, 1, 1, 0, -30_383, 104_755),
        (2, 0, 0, -2, 15_327, 10_321),
        (0, 0, 1, 2, -12_528, 0),
        (0, 0, 1, -2, 10_980, 79_661),
        (4, 0, -1, 0, 10_675, -34_782),
        (0, 0, 3, 0, 10_034, -23_210),
        (4, 0, -2, 0, 8_548, -21_636),
        (2, 1, -1, 0, -7_888, 24_208),
        (2, 1, 0, 0, -6_766, 30_824),
        (1, 0, -1, 0, -5_163, -8_379),
        (1, 1, 0, 0, 4_987, -16_675),
        (2, -1, 1, 0, 4_036, -12_831),
        (2, 0, 2, 0, 3_994, -10_445),
        (4, 0, 0, 0, 3_861, -11_650),
        (2, 0, -3, 0, 3_665, 14_403),
        (0, 1, -2, 0, -2_689, -7_003),
        (2, 0, -1, 2, -2_602, 0),
        (2, -1, -2, 0, 2_390, 10_056),
        (1, 0, 1, 0, -2_348, 6_322),
        (2, -2, 0, 0, 2_236, -9_884),
        (0, 1, 2, 0, -2_120, 5_751),
        (0, 2, 0, 0, -2_069, 0),
        (2, -2, -1, 0, 2_048, -4_950),
        (2, 0, 1, -2, -1_773, 4_130),
        (2, 0, 0, 2, -1_595, 0),
        (4, -1, -1, 0, 1_215, -3_958),
        (0, 0, 2, 2, -1_110, 0),
        (3, 0, -1, 0, -892, 3_258),
        (2, 1, 1, 0, -810, 2_616),
        (4, -1, -2, 0, 759, -1_897),
        (0, 2, -1, 0, -713, -2_117),
        (2, 2, -1, 0, -700, 2_354),
        (2, 1, -2, 0, 691, 0),
        (2, -1, 0, -2, 596, 0),
        (4, 0, 1, 0, 549, -1_423),
        (0, 0, 4, 0, 537, -1_117),
        (4, -1, 0, 0, 520, -1_571),
        (1, 0, -2, 0, -487, -1_739),
        (2, 1, 0, -2, -399, 0),
        (0, 0, 2, -2, -381, -4_421),
        (1, 1, 1, 0, 351, 0),
        (3, 0, -2, 0, -340, 0),
        (4, 0, -3, 0, 330, 0),
        (2, -1, 2, 0, 327, 0),
        (0, 2, 1, 0, -323, 1_165),
        (1, 1, -1, 0, 299, 0),
        (2, 0, 3, 0, 294, 0),
        (2, 0, -1, -2, 0, 8_752),
    ]

    private static let latitudeTerms: [(Int, Int, Int, Int, Double)] = [
        (0, 0, 0, 1, 5_128_122),
        (0, 0, 1, 1, 280_602),
        (0, 0, 1, -1, 277_693),
        (2, 0, 0, -1, 173_237),
        (2, 0, -1, 1, 55_413),
        (2, 0, -1, -1, 46_271),
        (2, 0, 0, 1, 32_573),
        (0, 0, 2, 1, 17_198),
        (2, 0, 1, -1, 9_266),
        (0, 0, 2, -1, 8_822),
        (2, -1, 0, -1, 8_216),
        (2, 0, -2, -1, 4_324),
        (2, 0, 1, 1, 4_200),
        (2, 1, 0, -1, -3_359),
        (2, -1, -1, 1, 2_463),
        (2, -1, 0, 1, 2_211),
        (2, -1, -1, -1, 2_065),
        (0, 1, -1, -1, -1_870),
        (4, 0, -1, -1, 1_828),
        (0, 1, 0, 1, -1_794),
        (0, 0, 0, 3, -1_749),
        (0, 1, -1, 1, -1_565),
        (1, 0, 0, 1, -1_491),
        (0, 1, 1, 1, -1_475),
        (0, 1, 1, -1, -1_410),
        (0, 1, 0, -1, -1_344),
        (1, 0, 0, -1, -1_335),
        (0, 0, 3, 1, 1_107),
        (4, 0, 0, -1, 1_021),
        (4, 0, -1, 1, 833),
        (0, 0, 1, -3, 777),
        (4, 0, -2, 1, 671),
        (2, 0, 0, -3, 607),
        (2, 0, 2, -1, 596),
        (2, -1, 1, -1, 491),
        (2, 0, -2, 1, -451),
        (0, 0, 3, -1, 439),
        (2, 0, 2, 1, 422),
        (2, 0, -3, -1, 421),
        (2, 1, -1, 1, -366),
        (2, 1, 0, 1, -351),
        (4, 0, 0, 1, 331),
        (2, -1, 1, 1, 315),
        (2, -2, 0, -1, 302),
        (0, 0, 1, 3, -283),
        (2, 1, 1, -1, -229),
        (1, 1, 0, -1, 223),
        (1, 1, 0, 1, 223),
        (0, 1, -2, -1, -220),
        (2, 1, -1, -1, -220),
        (1, 0, 1, 1, -202),
        (2, -1, -2, -1, -200),
        (0, 1, 2, 1, -199),
        (4, 0, -2, -1, 176),
    ]
}
