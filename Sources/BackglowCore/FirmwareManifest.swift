import CryptoKit
import Foundation

/// The firmware images that ship inside the app, described by `Firmware/manifest.json`.
/// `scripts/build-firmware.sh` builds them with PlatformIO and writes the manifest.
public struct FirmwareManifest: Codable, Equatable, Sendable {
    public struct Part: Codable, Equatable, Sendable {
        public var offset: UInt32
        public var file: String
        public var sha256: String
    }

    public struct Image: Codable, Equatable, Identifiable, Sendable {
        /// PlatformIO environment, also the folder of the image files.
        public var id: String
        public var chip: ESPChip
        public var board: String
        /// GPIO of the LED data line, fixed at build time.
        public var dataPin: Int
        public var parts: [Part]
    }

    public var version: FirmwareVersion
    public var images: [Image]

    /// Reads the files of one image and checks them against the manifest. Nothing is
    /// flashed from a file whose hash does not match.
    public static func regions(for image: Image, in folder: URL) throws -> [FlashRegion] {
        try image.parts.map { part in
            let data = try Data(contentsOf: folder.appendingPathComponent(part.file))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == part.sha256.lowercased() else { throw FirmwareManifestError.hashMismatch(part.file) }
            return FlashRegion(offset: part.offset, data: data)
        }
    }
}

public enum FirmwareManifestError: Error, Equatable, Sendable {
    case hashMismatch(String)
}

public struct FirmwareVersion: Codable, Comparable, CustomStringConvertible, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads "3.4.0".
    public init?(_ text: String) {
        let numbers = text.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3, text.split(separator: ".").count == 3 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = FirmwareVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Expected major.minor.patch"))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
