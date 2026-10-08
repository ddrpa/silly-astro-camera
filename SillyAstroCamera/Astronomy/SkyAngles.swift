import Foundation

enum SkyAngles {
    static func radians(fromDegrees degrees: Double) -> Double {
        degrees * .pi / 180
    }

    static func degrees(fromRadians radians: Double) -> Double {
        radians * 180 / .pi
    }

    static func wrap360(_ degrees: Double) -> Double {
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    static func wrapSigned180(_ degrees: Double) -> Double {
        var value = wrap360(degrees)
        if value > 180 {
            value -= 360
        }
        return value
    }

    static func wrapPi(_ radians: Double) -> Double {
        var value = radians.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi {
            value -= 2 * .pi
        } else if value < -.pi {
            value += 2 * .pi
        }
        return value
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
