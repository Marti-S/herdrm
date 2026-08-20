import Foundation

struct LightTerminalANSIAdapter {
    private var pending: [UInt8] = []

    mutating func transform(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        pending.append(contentsOf: bytes)
        var output: [UInt8] = []
        var index = 0

        while index < pending.count {
            guard pending[index] == 0x1B else {
                output.append(pending[index])
                index += 1
                continue
            }
            guard index + 1 < pending.count else { break }
            guard pending[index + 1] == 0x5B else {
                output.append(pending[index])
                index += 1
                continue
            }

            var end = index + 2
            while end < pending.count, !(0x40...0x7E).contains(pending[end]) {
                end += 1
            }
            guard end < pending.count else { break }

            let sequence = Array(pending[index...end])
            output.append(contentsOf: pending[end] == 0x6D ? transformSGR(sequence) : sequence)
            index = end + 1
        }

        if index > 0 {
            pending.removeFirst(index)
        }
        return output
    }

    /// WCAG contrast ratio of an sRGB color against a white background.
    static func contrastOnWhite(red: Int, green: Int, blue: Int) -> Double {
        func linear(_ value: Int) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return 1.05 / (luminance + 0.05)
    }

    static func lightRGB(red: Int, green: Int, blue: Int) -> (red: Int, green: Int, blue: Int) {
        let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
        let offset = 255 - 2 * luminance
        return (
            clamp(Double(red) + offset),
            clamp(Double(green) + offset),
            clamp(Double(blue) + offset)
        )
    }

    /// Adapts one color for the light theme. Backgrounds always flip (a dark box
    /// must become light); foregrounds keep whichever variant reads better on
    /// white — same rule as the ANSI palette, so an already-dark foreground
    /// (diff red, syntax blue) doesn't wash out to a pastel.
    static func adapt(red: Int, green: Int, blue: Int, isBackground: Bool) -> (red: Int, green: Int, blue: Int) {
        let flipped = lightRGB(red: red, green: green, blue: blue)
        if isBackground { return flipped }
        let originalContrast = contrastOnWhite(red: red, green: green, blue: blue)
        let flippedContrast = contrastOnWhite(red: flipped.red, green: flipped.green, blue: flipped.blue)
        return originalContrast >= flippedContrast ? (red, green, blue) : flipped
    }

    /// The standard xterm 256-color palette above the 16 ANSI entries:
    /// 16–231 form a 6×6×6 cube, 232–255 a grayscale ramp.
    static func xterm256RGB(_ index: Int) -> (red: Int, green: Int, blue: Int) {
        if index >= 232 {
            let gray = 8 + 10 * (index - 232)
            return (gray, gray, gray)
        }
        let levels = [0, 95, 135, 175, 215, 255]
        let value = index - 16
        return (levels[value / 36], levels[(value / 6) % 6], levels[value % 6])
    }

    private func transformSGR(_ sequence: [UInt8]) -> [UInt8] {
        guard sequence.count >= 3 else { return sequence }
        let parameters = sequence[2..<(sequence.count - 1)]
        let values = String(decoding: parameters, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        var output: [String] = []
        var index = 0

        while index < values.count {
            let isColor = values[index] == "38" || values[index] == "48"
            let isBackground = values[index] == "48"
            if isColor, index + 4 < values.count, values[index + 1] == "2",
               let red = Int(values[index + 2]),
               let green = Int(values[index + 3]),
               let blue = Int(values[index + 4]),
               (0...255).contains(red), (0...255).contains(green), (0...255).contains(blue) {
                let light = Self.adapt(red: red, green: green, blue: blue, isBackground: isBackground)
                output += [values[index], "2", String(light.red), String(light.green), String(light.blue)]
                index += 5
            } else if isColor, index + 2 < values.count, values[index + 1] == "5",
                      let paletteIndex = Int(values[index + 2]),
                      // 0–15 resolve through the installed ANSI palette, which is
                      // already themed; rewriting them here would flip them twice.
                      (16...255).contains(paletteIndex) {
                let base = Self.xterm256RGB(paletteIndex)
                let light = Self.adapt(red: base.red, green: base.green, blue: base.blue, isBackground: isBackground)
                output += [values[index], "2", String(light.red), String(light.green), String(light.blue)]
                index += 3
            } else {
                output.append(values[index])
                index += 1
            }
        }

        return [0x1B, 0x5B] + Array(output.joined(separator: ";").utf8) + [0x6D]
    }

    private static func clamp(_ value: Double) -> Int {
        min(255, max(0, Int(value.rounded())))
    }
}
