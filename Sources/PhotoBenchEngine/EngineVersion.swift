import Foundation
import MachO

/// `hello`'s `engineVersion`: `<semver>+<git commit>`.
///
/// `scripts/package-engine.sh` links the commit (plus `.dirty` for an
/// uncommitted tree) into the executable's `__TEXT,__pb_engine_ver` section
/// (`-sectcreate`); a development build without it reports `+dev`.
enum EngineVersion {
    /// 0.2.0: `renderWorkingCopy`. Adding a method keeps `protocolVersion`.
    static let semanticVersion = "0.2.0"
    static let protocolVersion = 1
    static let segmentName = "__TEXT"
    static let sectionName = "__pb_engine_ver"

    static let current: String = "\(semanticVersion)+\(embeddedBuildMetadata() ?? "dev")"

    /// The section's text when it is a valid semver build identifier
    /// (`[0-9A-Za-z-]` parts joined by dots).
    static func embeddedBuildMetadata() -> String? {
        var size: UInt = 0
        let header = #dsohandle.assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(header, segmentName, sectionName, &size), size > 0 else { return nil }
        let text = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(size)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return isValidBuildMetadata(text) ? text : nil
    }

    static func isValidBuildMetadata(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return !text.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
