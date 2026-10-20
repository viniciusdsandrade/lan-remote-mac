import Foundation
import ImageIO
import Vision

/// What OCR (Vision) reads on a screenshot: of the PS5, from a Remote Play session, or of the TV,
/// from its screen_image query.
struct ScreenText {
    let lines: [String]   // lowercased

    init(lines: [String]) {
        self.lines = lines
    }

    init(image: URL) {
        self.init(source: CGImageSourceCreateWithURL(image as CFURL, nil))
    }

    init(data: Data) {
        self.init(source: CGImageSourceCreateWithData(data as CFData, nil))
    }

    private init(source: CGImageSource?) {
        guard let source, let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            self.lines = []
            return
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["pt-BR", "en-US"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: picture).perform([request])
        self.lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string.lowercased() }
    }

    /// Some line is exactly one of `words` (a focused icon's caption sits alone on its line).
    func hasLine(_ words: [String]) -> Bool {
        lines.contains { line in words.contains(line.trimmingCharacters(in: .whitespaces)) }
    }

    func contains(_ fragments: [String]) -> Bool {
        let text = lines.joined(separator: " ")
        return fragments.contains { text.contains($0) }
    }

    /// Possible readings of the 6-character hexadecimal codes on screen (the TV Box pairing code),
    /// with the usual OCR mix-ups as alternatives. The code's own check digit picks the right one.
    func hexCodes() -> [String] {
        let mixUps: [Character: [Character]] = ["O": ["0", "D"], "0": ["D"], "D": ["0"], "8": ["B"], "B": ["8"],
                                                "I": ["1"], "L": ["1"], "S": ["5"], "G": ["6"], "Z": ["2"]]
        var codes: [String] = []
        for line in lines {
            let compact = line.uppercased().filter { !$0.isWhitespace }
            guard compact.count == 6 else { continue }
            var readings = [""]
            for character in compact {
                let options = [character] + (mixUps[character] ?? [])
                readings = readings.flatMap { prefix in options.map { prefix + String($0) } }
            }
            for reading in readings where reading.allSatisfy(\.isHexDigit) && !codes.contains(reading) {
                codes.append(reading)
            }
        }
        return codes
    }
}
