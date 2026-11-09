import Foundation

enum DetectedAudioContainer: Equatable {
    case m4a
    case adtsAac
    case amr
    case mp3
    case unknown

    var preferredExtension: String? {
        switch self {
        case .m4a: return "m4a"
        case .adtsAac: return "aac"
        case .amr: return "amr"
        case .mp3: return "mp3"
        case .unknown: return nil
        }
    }
}

enum AudioContainerDetector {
    static func detect(_ data: Data) -> DetectedAudioContainer {
        guard data.count >= 3 else { return .unknown }
        let bytes = [UInt8](data.prefix(12))

        if bytes.count >= 8,
           bytes[4] == 0x66, bytes[5] == 0x74,
           bytes[6] == 0x79, bytes[7] == 0x70 {
            return .m4a
        }
        if bytes[0] == 0xFF, bytes.count >= 2, (bytes[1] & 0xF6) == 0xF0 {
            return .adtsAac
        }
        if bytes.count >= 6,
           bytes[0] == 0x23, bytes[1] == 0x21,
           bytes[2] == 0x41, bytes[3] == 0x4D,
           bytes[4] == 0x52, bytes[5] == 0x0A {
            return .amr
        }
        if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            return .mp3
        }
        if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 {
            return .mp3
        }
        return .unknown
    }

    static func headHex(_ data: Data, limit: Int = 16) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined()
    }

    static func isCompleteMP4(_ data: Data) -> Bool {
        guard data.count >= 32 else { return false }
        var offset = 0
        var sawFtyp = false
        var sawMdat = false
        var sawMoov = false
        while offset + 8 <= data.count {
            let size32 = readUInt32(data, at: offset)
            guard let type = ascii(data, at: offset + 4, count: 4) else { return false }
            var header = 8
            var boxSize = Int(size32)
            if size32 == 1 {
                guard offset + 16 <= data.count else { return false }
                let largeSize = readUInt64(data, at: offset + 8)
                guard largeSize <= UInt64(Int.max) else { return false }
                boxSize = Int(largeSize)
                header = 16
            } else if size32 == 0 {
                return false
            }
            guard boxSize >= header, offset + boxSize <= data.count else { return false }
            if type == "ftyp" { sawFtyp = true }
            if type == "mdat" { sawMdat = true }
            if type == "moov" { sawMoov = true }
            offset += boxSize
        }
        return sawFtyp && sawMdat && sawMoov
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<offset + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func ascii(_ data: Data, at offset: Int, count: Int) -> String? {
        guard offset + count <= data.count else { return nil }
        return String(data: data[offset..<offset + count], encoding: .ascii)
    }
}
