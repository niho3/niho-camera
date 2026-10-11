import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import NihoCameraCutout

@main
struct NihoCameraCutoutCommand {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let started = ContinuousClock.now
            let detector = CutoutDetector()
            let result = try await detector.detect(url: options.input)
            let selection: CutoutSubjectSelection
            switch options.selection {
            case .largest: selection = result.largestSelection
            case .all: selection = .all
            case let .instance(id): selection = .instance(id)
            }
            guard let mask = result.masks.first(where: { $0.selection == selection }) else {
                throw CLIError.unknownSubject(selection.storageKey)
            }
            guard let source = CGImageSourceCreateWithURL(options.input as CFURL, nil),
                  let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw CutoutError.unreadableInput(options.input) }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
            let normalized = CIImage(cgImage: sourceImage).oriented(orientation)
            let composer = CutoutComposer()
            let size = try composer.export(
                image: normalized,
                maskPNGData: mask.pngData,
                background: options.background,
                destination: options.output,
                format: try .inferred(from: options.output, jpegQuality: options.jpegQuality),
                protectedSourceURLs: [options.input]
            )
            let elapsed = started.duration(to: .now)
            let components = elapsed.components
            let milliseconds = Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
            print("\(Int(size.width))x\(Int(size.height)) subject=\(selection.storageKey) \(String(format: "%.0f", milliseconds))ms -> \(options.output.path)")
        } catch {
            FileHandle.standardError.write(Data("niho-camera-cutout: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}

private struct Options {
    enum Selection { case largest, all, instance(Int) }
    let input: URL
    let output: URL
    let selection: Selection
    let background: CutoutBackground
    let jpegQuality: Double

    init(arguments: [String]) throws {
        var input: String?
        var output: String?
        var selection: Selection = .largest
        var background: CutoutBackground = .transparent
        var jpegQuality = 0.92
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else { throw CLIError.usage }
            let value = arguments[index + 1]
            switch flag {
            case "--input", "-i": input = value
            case "--output", "-o": output = value
            case "--subject":
                if value == "largest" { selection = .largest }
                else if value == "all" { selection = .all }
                else if let id = Int(value), id > 0 { selection = .instance(id) }
                else { throw CLIError.invalidSubject(value) }
            case "--background": background = try Self.parseBackground(value)
            case "--jpeg-quality":
                guard let parsed = Double(value), (0...1).contains(parsed) else {
                    throw CLIError.invalidQuality(value)
                }
                jpegQuality = parsed
            default: throw CLIError.unknownOption(flag)
            }
            index += 2
        }
        guard let input, let output else { throw CLIError.usage }
        self.input = URL(fileURLWithPath: input)
        self.output = URL(fileURLWithPath: output)
        self.selection = selection
        self.background = background
        self.jpegQuality = jpegQuality
    }

    private static func parseBackground(_ value: String) throws -> CutoutBackground {
        if value == "transparent" { return .transparent }
        if value == "white" { return .color(.white) }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, let raw = UInt32(hex, radix: 16) else {
            throw CLIError.invalidBackground(value)
        }
        return .color(CutoutRGBA(
            red: Double((raw >> 16) & 0xff) / 255,
            green: Double((raw >> 8) & 0xff) / 255,
            blue: Double(raw & 0xff) / 255
        ))
    }
}

private enum CLIError: LocalizedError {
    case usage
    case unknownOption(String)
    case invalidSubject(String)
    case unknownSubject(String)
    case invalidBackground(String)
    case invalidQuality(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "usage: niho-camera-cutout --input PATH --output PATH [--subject largest|all|ID] [--background transparent|white|#RRGGBB] [--jpeg-quality 0...1]"
        case let .unknownOption(value): "不明なオプションです: \(value)"
        case let .invalidSubject(value): "被写体指定が不正です: \(value)"
        case let .unknownSubject(value): "被写体が見つかりません: \(value)"
        case let .invalidBackground(value): "背景色が不正です: \(value)"
        case let .invalidQuality(value): "JPEG品質が不正です: \(value)"
        }
    }
}
