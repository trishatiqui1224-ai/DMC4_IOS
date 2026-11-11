import Foundation

enum GameFileError: LocalizedError {
    case invalidDisc, wrongGame, missingShaders, invalidShaders, unreadable

    var errorDescription: String? {
        switch self {
        case .invalidDisc: return "The file is not a supported Xbox 360 disc image."
        case .wrongGame: return "Select an Xbox 360 copy of Devil May Cry 4."
        case .missingShaders: return "The game data is missing nativeXenon/system/shader.arc."
        case .invalidShaders: return "The Xbox 360 shader archive is damaged or uses an unsupported format."
        case .unreadable: return "The game data is incomplete or unreadable."
        }
    }
}

struct GameFiles: Sendable {
    let url: URL
    let isDisc: Bool
    let shaderBundleCount: Int

    init(_ url: URL) throws {
        self.url = url
        isDisc = url.pathExtension.lowercased() == "iso"
        if isDisc {
            let disc = try XboxDisc(url)
            guard let executable = try disc.entry(["default.xex"]), !executable.directory else {
                throw GameFileError.wrongGame
            }
            try Self.checkExecutable { offset, count in
                guard offset <= executable.size, UInt64(count) <= executable.size - offset else {
                    throw GameFileError.unreadable
                }
                return try disc.read(executable.offset + offset, count)
            }
            guard let shader = try disc.entry(["nativeXenon", "system", "shader.arc"]),
                  !shader.directory, shader.size > 0 else { throw GameFileError.missingShaders }
            shaderBundleCount = try Self.checkShaderArchive(size: shader.size) { offset, count in
                try disc.read(shader.offset + offset, count)
            }
        } else {
            let xex = try FileHandle(forReadingFrom: url.appendingPathComponent("default.xex"))
            defer { try? xex.close() }
            try Self.checkExecutable { offset, count in
                try xex.seek(toOffset: offset)
                guard let data = try xex.read(upToCount: count), data.count == count else {
                    throw GameFileError.unreadable
                }
                return data
            }
            let shader = url.appendingPathComponent("nativeXenon/system/shader.arc")
            let info = try? shader.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard info?.isRegularFile == true, (info?.fileSize ?? 0) > 0 else {
                throw GameFileError.missingShaders
            }
            let archive = try FileHandle(forReadingFrom: shader)
            defer { try? archive.close() }
            let size = try archive.seekToEnd()
            shaderBundleCount = try Self.checkShaderArchive(size: size) { offset, count in
                try archive.seek(toOffset: offset)
                guard let data = try archive.read(upToCount: count), data.count == count else {
                    throw GameFileError.invalidShaders
                }
                return data
            }
        }
    }

    private static func checkShaderArchive(size: UInt64,
                                           read: (UInt64, Int) throws -> Data) throws -> Int {
        guard size >= 8 else { throw GameFileError.invalidShaders }
        let header = try read(0, 8)
        // Big-endian MT Framework Xbox 360 ARC, version 0x11.
        guard header.prefix(6) == Data([0, 0x43, 0x52, 0x41, 0, 0x11]) else {
            throw GameFileError.invalidShaders
        }
        let count = Int(header.be16(6))
        let tableEnd = UInt64(8 + count * 80)
        guard count > 0, tableEnd <= size else { throw GameFileError.invalidShaders }
        let entries = try read(8, count * 80)
        var bundles = 0
        for index in 0..<count {
            let entry = index * 80
            let type = entries.be32(entry + 64)
            let packedSize = UInt64(entries.be32(entry + 68))
            let unpackedSize = UInt64(entries.be32(entry + 72) >> 3)
            var offset = UInt64(entries.be32(entry + 76))
            guard offset >= tableEnd, offset <= size, packedSize <= size - offset else {
                throw GameFileError.invalidShaders
            }
            guard type == 0x4E32817C else { continue }
            let end = offset + packedSize
            var decoded: UInt64 = 0
            while offset < end {
                guard end - offset >= 2 else { throw GameFileError.invalidShaders }
                let header = try read(offset, 2)
                let extended = header[0] == 0xFF
                let headerSize: UInt64 = extended ? 5 : 2
                guard headerSize <= end - offset else { throw GameFileError.invalidShaders }
                let frame = extended ? try read(offset + 1, 4) : header
                let plain = extended ? UInt64(frame.be16(0)) : 0x8000
                let packed = UInt64(frame.be16(extended ? 2 : 0))
                offset += headerSize
                guard plain > 0, plain <= 0x8000, packed > 0, packed <= end - offset else {
                    throw GameFileError.invalidShaders
                }
                offset += packed
                decoded += plain
                guard decoded <= unpackedSize else { throw GameFileError.invalidShaders }
            }
            guard decoded > 0, decoded == unpackedSize else { throw GameFileError.invalidShaders }
            bundles += 1
        }
        guard bundles > 0 else { throw GameFileError.missingShaders }
        return bundles
    }

    private static func checkExecutable(read: (UInt64, Int) throws -> Data) throws {
        let header = try read(0, 24)
        guard header.prefix(4) == Data("XEX2".utf8), header.be32(20) <= 1024 else {
            throw GameFileError.wrongGame
        }
        let fields = Int(header.be32(20))
        guard fields > 0 else { throw GameFileError.wrongGame }
        let table = try read(24, fields * 8)
        for index in 0..<fields where table.be32(index * 8) == 0x00040006 {
            let id = try read(UInt64(table.be32(index * 8 + 4)) + 12, 4)
            guard id.be32(0) == 0x434307DF else { throw GameFileError.wrongGame }
            return
        }
        throw GameFileError.wrongGame
    }

    static func importToDocuments(_ source: URL, documents: URL) throws -> GameFiles {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        let game = try GameFiles(source)
        let target = documents.appendingPathComponent(game.isDisc ? "dmc4.iso" : "game")
        if source.standardizedFileURL == target.standardizedFileURL { return game }

        let staging = documents.appendingPathComponent(".import-\(UUID().uuidString)",
                                                        isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(target.lastPathComponent)
        try files.copyItem(at: source, to: copy)
        _ = try GameFiles(copy)
        if files.fileExists(atPath: target.path) {
            _ = try files.replaceItemAt(target, withItemAt: copy)
        } else {
            try files.moveItem(at: copy, to: target)
        }
        return try GameFiles(target)
    }
}

private final class XboxDisc {
    struct Entry {
        let offset: UInt64
        let size: UInt64
        let directory: Bool
    }

    private let file: FileHandle
    private let length: UInt64
    private var partition: UInt64 = 0
    private var root = Entry(offset: 0, size: 0, directory: true)

    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        length = try file.seekToEnd()
        let magic = Data("MICROSOFT*XBOX*MEDIA".utf8)
        // Volume descriptor offsets used by Xenia's XDVDFS reader.
        for base: UInt64 in [0, 0xFB20, 0x20600, 0x02080000, 0x0FD90000] {
            guard base + 0x10000 + 28 <= length else { continue }
            let header = try read(base + 0x10000, 28)
            guard header.prefix(20) == magic else { continue }
            partition = base
            root = try makeEntry(header.le32(20), header.le32(24), directory: true)
            return
        }
        throw GameFileError.invalidDisc
    }

    deinit { try? file.close() }

    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard offset <= length, UInt64(count) <= length - offset else {
            throw GameFileError.unreadable
        }
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: count), data.count == count else {
            throw GameFileError.unreadable
        }
        return data
    }

    private func makeEntry(_ sector: UInt32, _ size: UInt32, directory: Bool) throws -> Entry {
        let offset = partition + UInt64(sector) * 2048
        guard offset <= length, UInt64(size) <= length - offset else {
            throw GameFileError.invalidDisc
        }
        return Entry(offset: offset, size: UInt64(size), directory: directory)
    }

    func entry(_ components: [String]) throws -> Entry? {
        var current = root
        for name in components {
            guard current.directory, let child = try child(named: name, in: current) else {
                return nil
            }
            current = child
        }
        return current
    }

    private func child(named name: String, in parent: Entry) throws -> Entry? {
        guard parent.size > 0 else { return nil }
        var pending: [UInt64] = [0]
        var visited = Set<UInt64>()
        while let node = pending.popLast() {
            guard visited.insert(node).inserted, node + 14 <= parent.size else {
                throw GameFileError.invalidDisc
            }
            let header = try read(parent.offset + node, 14)
            let nameLength = Int(header[13])
            guard node + 14 + UInt64(nameLength) <= parent.size else {
                throw GameFileError.invalidDisc
            }
            let filename = try read(parent.offset + node + 14, nameLength)
            if String(decoding: filename, as: UTF8.self).lowercased() == name.lowercased() {
                return try makeEntry(header.le32(4), header.le32(8), directory: header[12] & 16 != 0)
            }
            for index in [0, 2] {
                let link = UInt64(header[index]) | (UInt64(header[index + 1]) << 8)
                if link > 0 { pending.append(link * 4) }
            }
        }
        return nil
    }
}

private extension Data {
    func be16(_ offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func be32(_ offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func le32(_ offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
