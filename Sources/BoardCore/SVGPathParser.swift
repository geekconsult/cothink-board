import Foundation

public enum NoteIconCommand: Equatable, Sendable {
    case moveTo(x: Double, y: Double)
    case lineTo(x: Double, y: Double)
    case curve(x1: Double, y1: Double, x2: Double, y2: Double, x: Double, y: Double)
    case quad(x1: Double, y1: Double, x: Double, y: Double)
    case close
}

/// Minimal SVG path data parser (M/L/H/V/C/S/Q/T/A/Z, absolute and relative) used for note icon geometry.
struct SVGPathParser {
    private let characters: [Character]
    private var position = 0
    private var current: (x: Double, y: Double) = (0, 0)
    private var subpathStart: (x: Double, y: Double) = (0, 0)
    private var lastControl: (x: Double, y: Double)?
    private var previousCommand: Character = " "
    private var commands: [NoteIconCommand] = []

    init(_ source: String) {
        characters = Array(source)
    }

    mutating func parseCommands() -> [NoteIconCommand] {
        while position < characters.count {
            skipSeparators()
            guard position < characters.count else { break }
            let command = characters[position]
            guard "MmLlHhVvCcSsQqTtAaZz".contains(command) else { break }
            position += 1
            previousCommand = command
            switch command {
            case "M", "m":
                guard let (px, py) = readPoint() else { break }
                if command == "m" { current.x += px; current.y += py } else { current = (px, py) }
                subpathStart = current
                commands.append(.moveTo(x: current.x, y: current.y))
                while peekIsNumber {
                    guard let (nx, ny) = readPoint() else { break }
                    if command == "m" { current.x += nx; current.y += ny } else { current = (nx, ny) }
                    commands.append(.lineTo(x: current.x, y: current.y))
                }
            case "L", "l":
                while peekIsNumber {
                    guard let (nx, ny) = readPoint() else { break }
                    if command == "l" { current.x += nx; current.y += ny } else { current = (nx, ny) }
                    commands.append(.lineTo(x: current.x, y: current.y))
                }
                previousCommand = "L"
            case "H", "h", "V", "v":
                while peekIsNumber {
                    guard let value = readNumber() else { break }
                    if command == "H" || command == "h" {
                        current.x = command == "H" ? value : current.x + value
                    } else {
                        current.y = command == "V" ? value : current.y + value
                    }
                    commands.append(.lineTo(x: current.x, y: current.y))
                }
                previousCommand = "L"
            case "C", "c":
                while peekIsNumber {
                    guard let (a, b, c, d, e, f) = readCurveArguments() else { break }
                    let dx = command == "c" ? current.x : 0
                    let dy = command == "c" ? current.y : 0
                    lastControl = (c + dx, d + dy)
                    current = (e + dx, f + dy)
                    commands.append(.curve(x1: a + dx, y1: b + dy, x2: c + dx, y2: d + dy, x: current.x, y: current.y))
                }
            case "S", "s":
                while peekIsNumber {
                    guard let (x2, y2, x, y) = readFour() else { break }
                    let dx = command == "s" ? current.x : 0
                    let dy = command == "s" ? current.y : 0
                    let reflect = previousCommand == "C" || previousCommand == "S"
                    let c1x = reflect ? 2 * current.x - (lastControl?.x ?? current.x) : current.x
                    let c1y = reflect ? 2 * current.y - (lastControl?.y ?? current.y) : current.y
                    lastControl = (x2 + dx, y2 + dy)
                    current = (x + dx, y + dy)
                    commands.append(.curve(x1: c1x, y1: c1y, x2: x2 + dx, y2: y2 + dy, x: current.x, y: current.y))
                }
            case "Q", "q":
                while peekIsNumber {
                    guard let (x1, y1, x, y) = readFour() else { break }
                    let dx = command == "q" ? current.x : 0
                    let dy = command == "q" ? current.y : 0
                    lastControl = (x1 + dx, y1 + dy)
                    current = (x + dx, y + dy)
                    commands.append(.quad(x1: x1 + dx, y1: y1 + dy, x: current.x, y: current.y))
                }
            case "T", "t":
                while peekIsNumber {
                    guard let (nx, ny) = readPoint() else { break }
                    let dx = command == "t" ? current.x : 0
                    let dy = command == "t" ? current.y : 0
                    let reflect = previousCommand == "Q" || previousCommand == "T"
                    let c1x = reflect ? 2 * current.x - (lastControl?.x ?? current.x) : current.x
                    let c1y = reflect ? 2 * current.y - (lastControl?.y ?? current.y) : current.y
                    lastControl = (c1x, c1y)
                    current = (nx + dx, ny + dy)
                    commands.append(.quad(x1: c1x, y1: c1y, x: current.x, y: current.y))
                }
            case "A", "a":
                while peekIsNumber {
                    guard let rx = readNumber(), let ry = readNumber(), let rotation = readNumber(),
                          let largeArc = readFlag(), let sweep = readFlag(), let (ex, ey) = readPoint() else { break }
                    let end = command == "a" ? (x: current.x + ex, y: current.y + ey) : (x: ex, y: ey)
                    appendArc(end: end, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc, sweep: sweep)
                    current = end
                }
            case "Z", "z":
                commands.append(.close)
                current = subpathStart
            default: break
            }
        }
        return commands
    }

    // Arc to cubic conversion, following the SVG specification endpoint parameterization appendix.
    private mutating func appendArc(end: (x: Double, y: Double), rx: Double, ry: Double, rotation: Double, largeArc: Bool, sweep: Bool) {
        let x1 = current.x
        let y1 = current.y
        guard x1 != end.x || y1 != end.y else { return }
        let rxa = abs(rx)
        let rya = abs(ry)
        guard rxa > 0, rya > 0 else {
            commands.append(.lineTo(x: end.x, y: end.y))
            current = end
            return
        }
        let phi = rotation * Double.pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx2 = (x1 - end.x) / 2
        let dy2 = (y1 - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2
        var rsx = rxa
        var rsy = rya
        let lambda = x1p * x1p / (rxa * rxa) + y1p * y1p / (rya * rya)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rsx = rxa * scale
            rsy = rya * scale
        }
        let num = rsx * rsx * rsy * rsy - rsx * rsx * y1p * y1p - rsy * rsy * x1p * x1p
        let den = rsx * rsx * y1p * y1p + rsy * rsy * x1p * x1p
        let factor = den > 0 ? sqrt(max(0, num) / den) : 0
        let sign = largeArc != sweep ? 1.0 : -1.0
        let cxp = sign * factor * rsx * y1p / rsy
        let cyp = -sign * factor * rsy * x1p / rsx
        let offsetX = (x1 + end.x) / 2
        let offsetY = (y1 + end.y) / 2
        let centerX = cxp * cosPhi - cyp * sinPhi + offsetX
        let centerY = cxp * sinPhi + cyp * cosPhi + offsetY
        func angle(_ u: (x: Double, y: Double), _ v: (x: Double, y: Double)) -> Double {
            let dot = u.x * v.x + u.y * v.y
            let cross = u.x * v.y - u.y * v.x
            let lengths = sqrt((u.x * u.x + u.y * u.y) * (v.x * v.x + v.y * v.y))
            let theta = acos(max(-1, min(1, dot / lengths)))
            return cross < 0 ? -theta : theta
        }
        let v0x = (x1p - cxp) / rsx
        let v0y = (y1p - cyp) / rsy
        let v1x = (-x1p - cxp) / rsx
        let v1y = (-y1p - cyp) / rsy
        var sweepTheta = angle((v0x, v0y), (v1x, v1y))
        if !sweep && sweepTheta > 0 { sweepTheta -= 2 * Double.pi }
        if sweep && sweepTheta < 0 { sweepTheta += 2 * Double.pi }
        let segments = max(1, Int(ceil(abs(sweepTheta) / (Double.pi / 2))))
        let step = sweepTheta / Double(segments)
        let mag0 = sqrt(v0x * v0x + v0y * v0y)
        var fromTheta = mag0 > 0 ? acos(max(-1, min(1, v0x / mag0))) : 0
        for _ in 0..<segments {
            let toTheta = fromTheta + step
            let alpha = 4.0 / 3.0 * tan(step / 4)
            let s0 = sin(fromTheta)
            let c0 = cos(fromTheta)
            let s1 = sin(toTheta)
            let c1 = cos(toTheta)
            let p0x = centerX + rsx * c0
            let p0y = centerY + rsy * s0
            let p1x = centerX + rsx * c1
            let p1y = centerY + rsy * s1
            let q1x = p0x - alpha * rsx * s0
            let q1y = p0y + alpha * rsy * c0
            let q2x = p1x + alpha * rsx * s1
            let q2y = p1y - alpha * rsy * c1
            commands.append(.curve(x1: q1x, y1: q1y, x2: q2x, y2: q2y, x: p1x, y: p1y))
            fromTheta = toTheta
        }
    }

    // MARK: token reading

    private mutating func skipSeparators() {
        while position < characters.count {
            let character = characters[position]
            guard character.isWhitespace || character == "," else { break }
            position += 1
        }
    }

    private var peekIsNumber: Bool {
        guard position < characters.count else { return false }
        let character = characters[position]
        return character.isNumber || character == "-" || character == "+" || character == "."
    }

    private mutating func readNumber() -> Double? {
        skipSeparators()
        guard position < characters.count else { return nil }
        let start = position
        if characters[position] == "-" || characters[position] == "+" { position += 1 }
        var seenDigit = false
        var seenDot = false
        while position < characters.count {
            let character = characters[position]
            if character.isNumber {
                seenDigit = true
                position += 1
            } else if character == "." && !seenDot {
                seenDot = true
                position += 1
            } else {
                break
            }
        }
        guard seenDigit else { position = start; return nil }
        return Double(String(characters[start..<position]))
    }

    private mutating func readFlag() -> Bool? {
        skipSeparators()
        guard position < characters.count else { return nil }
        let digit = characters[position].wholeNumberValue
        guard digit == 0 || digit == 1 else { return nil }
        position += 1
        return digit == 1
    }

    private mutating func readPoint() -> (x: Double, y: Double)? {
        guard let x = readNumber(), let y = readNumber() else { return nil }
        return (x, y)
    }

    private mutating func readCurveArguments() -> (Double, Double, Double, Double, Double, Double)? {
        guard let a = readNumber(), let b = readNumber(), let c = readNumber(),
              let d = readNumber(), let e = readNumber(), let f = readNumber() else { return nil }
        return (a, b, c, d, e, f)
    }

    private mutating func readFour() -> (Double, Double, Double, Double)? {
        guard let a = readNumber(), let b = readNumber(), let c = readNumber(), let d = readNumber() else { return nil }
        return (a, b, c, d)
    }
}
