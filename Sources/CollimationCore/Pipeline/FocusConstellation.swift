import Foundation

public struct FocusConstellationProgress: Equatable, Sendable {
    public var star = 0
    public var stars = 0
    public var focusIndex = 0
    public var focusCount = 0
    public var focusPosition: Int?
    public var recordedImages = 0
    public init() {}
}

public struct FocusConstellationSettings: Equatable, Sendable {
    public static let defaultRange = 4000
    public static let defaultStep = 250
    // 35 stars × 57 float crops, including TIFF overhead, fit the reader's 512 MiB limit.
    public static let maximumCount = 57
    public let range: Int
    public let step: Int
    public var centerIndex: Int { range / step }
    public var count: Int { centerIndex * 2 + 1 }

    public init(range: Int = Self.defaultRange, step: Int = Self.defaultStep) throws {
        guard range > 0, step > 0, range % step == 0 else {
            throw CameraError.unsupported("Sweep range and step size must be positive, and range must be a multiple of step size.")
        }
        guard range / step <= (Self.maximumCount - 1) / 2 else {
            throw CameraError.unsupported("Use a larger sweep step size or smaller range: at most \(Self.maximumCount) focus positions fit in one recording.")
        }
        self.range = range; self.step = step
    }
}

public struct FocusConstellationPlan: Equatable, Sendable {
    public let settings: FocusConstellationSettings
    public let bestFocus: Int
    public let takeUp: Int
    public let positions: [Int]

    public init(bestFocus: Int, maximum: Int, takeUp: Int,
                settings: FocusConstellationSettings = try! FocusConstellationSettings()) throws {
        let range = settings.range
        guard takeUp > 0, maximum >= range, bestFocus >= range,
              takeUp <= bestFocus - range, bestFocus <= maximum - range else {
            throw CameraError.unsupported("The full focus sweep and backlash take-up must fit within focuser travel: best focus −\(range) − take-up through best focus +\(range) steps.")
        }
        self.settings = settings
        self.bestFocus = bestFocus; self.takeUp = takeUp
        // Offset from centre to avoid overflowing when valid positions are near Int.max.
        positions = (-settings.centerIndex...settings.centerIndex).map { bestFocus + $0 * settings.step }
    }

    public func moves(for index: Int) -> [Int] {
        index == 0 ? [positions[0] - takeUp, positions[0]] : [positions[index]]
    }
}

public struct FocusConstellationTarget: Codable, Equatable, Sendable {
    public let label: String
    public let row: Int
    public let column: Int
    public let x: Double
    public let y: Double
    public init(_ position: ConstellationPosition) {
        label = position.label; row = position.row; column = position.column
        x = position.sensorPoint.x; y = position.sensorPoint.y
    }
}

/// One shared absolute focus scale, referenced to autofocus at the sensor centre.
public struct FocusConstellationMetadata: Codable, Equatable, Sendable {
    public let kind: String
    public let schemaVersion: Int
    public let layout: ConstellationLayout
    public let bestFocus: Int
    public let positions: [Int]
    public let takeUp: Int
    public let maximum: Int
    public let sensorWidth: Int
    public let sensorHeight: Int
    public let frameCount: Int
    public let exposureMicroseconds: Int
    public let gain: Int
    public let targets: [FocusConstellationTarget]
    public let autofocus: AutofocusResult?

    public init(plan: FocusConstellationPlan, maximum: Int, layout: ConstellationLayout,
                sensorWidth: Int, sensorHeight: Int, frameCount: Int, exposureMicroseconds: Int,
                gain: Int, autofocus: AutofocusResult? = nil) {
        kind = "collimation-focus-constellation"; schemaVersion = 1
        self.layout = layout; bestFocus = plan.bestFocus; positions = plan.positions
        takeUp = plan.takeUp; self.maximum = maximum
        self.sensorWidth = sensorWidth; self.sensorHeight = sensorHeight
        self.frameCount = frameCount; self.exposureMicroseconds = exposureMicroseconds; self.gain = gain
        targets = ConstellationCapture.positions(sensorWidth: sensorWidth, sensorHeight: sensorHeight, layout: layout)
            .map(FocusConstellationTarget.init)
        self.autofocus = autofocus
    }

    public func validate() throws {
        guard positions.count >= 3, positions.count <= FocusConstellationSettings.maximumCount,
              positions.count % 2 == 1, let first = positions.first, let last = positions.last,
              first >= 0, first < bestFocus, positions[1] > first, bestFocus < last, last <= maximum else {
            throw CameraError.unsupported("Invalid focus constellation metadata.")
        }
        let settings = try FocusConstellationSettings(range: bestFocus - first, step: positions[1] - first)
        let plan = try FocusConstellationPlan(bestFocus: bestFocus, maximum: maximum, takeUp: takeUp, settings: settings)
        guard kind == "collimation-focus-constellation", schemaVersion == 1, positions == plan.positions,
              sensorWidth > 0, sensorWidth <= 100000, sensorHeight > 0, sensorHeight <= 100000,
              frameCount > 0, exposureMicroseconds > 0,
              targets == ConstellationCapture.positions(sensorWidth: sensorWidth, sensorHeight: sensorHeight, layout: layout)
                .map(FocusConstellationTarget.init), autofocus == nil || autofocus?.position == bestFocus else {
            throw CameraError.unsupported("Invalid focus constellation metadata.")
        }
    }
}

/// Immutable TIFF index. Loading a focus layer reads only its 9 or 35 star crops.
public final class FocusConstellationRecording: Sendable {
    public let id = UUID()
    public let metadata: FocusConstellationMetadata
    public let url: URL
    private let strips: [UInt64]
    private static let pixelBytes = 256 * 256 * 4
    private static let fileLimit = 512 * 1024 * 1024

    private init(metadata: FocusConstellationMetadata, url: URL, strips: [UInt64]) {
        self.metadata = metadata; self.url = url; self.strips = strips
    }

    public static func openIfSupported(from url: URL) throws -> FocusConstellationRecording? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 8 else { return nil }
        let header = try read(file, at: 0, count: 8, size: size)
        guard header[0] == 73, header[1] == 73, u16(header, 2) == 42 else { return nil }
        var offset = UInt64(u32(header, 4))
        var visited: Set<UInt64> = [], strips: [UInt64] = []
        var regions: [Range<UInt64>] = [0..<8]
        var metadata: FocusConstellationMetadata?
        let invalid = CameraError.unsupported("Invalid or incomplete focus constellation TIFF.")
        while offset != 0 {
            try Task.checkCancellation()
            guard offset >= 8, visited.insert(offset).inserted,
                  strips.count < (metadata.map { $0.targets.count * $0.positions.count } ?? 35 * FocusConstellationSettings.maximumCount) else { throw invalid }
            let count = Int(u16(try read(file, at: offset, count: 2, size: size), 0))
            guard count <= 64 else { throw invalid }
            let directory = try read(file, at: offset + 2, count: count * 12 + 4, size: size)
            regions.append(offset..<(offset + UInt64(2 + directory.count)))
            var tags: [UInt16: UInt32] = [:]
            var description: Data?
            for index in 0..<count {
                let at = index * 12, tag = u16(directory, at), type = u16(directory, at + 2)
                let length = Int(u32(directory, at + 4)), value = u32(directory, at + 8)
                if tag == 270 && strips.isEmpty {
                    guard description == nil, type == 2, length > 0, length <= 2 * 1024 * 1024 else { throw invalid }
                    description = length <= 4 ? directory.subdata(in: (at + 8)..<(at + 8 + length))
                        : try read(file, at: UInt64(value), count: length, size: size)
                    if length > 4 { regions.append(UInt64(value)..<(UInt64(value) + UInt64(length))) }
                } else if [256, 257, 258, 259, 262, 273, 274, 277, 278, 279, 284, 339].contains(tag) {
                    guard tags[tag] == nil, length == 1, type == 3 || type == 4 else { throw invalid }
                    tags[tag] = type == 3 ? UInt32(u16(directory, at + 8)) : value
                }
            }
            if strips.isEmpty {
                guard tags[256] == 256, tags[257] == 256 else { return nil }
                guard let description, description.last == 0 else { return nil }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                // A single ordinary 256 crop is not a constellation recording.
                let json = description.dropLast()
                guard let object = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any],
                      object["kind"] as? String == "collimation-focus-constellation" else { return nil }
                guard size <= UInt64(Self.fileLimit) else { throw invalid }
                metadata = try decoder.decode(FocusConstellationMetadata.self, from: Data(json))
                try metadata!.validate()
            }
            guard tags[256] == 256, tags[257] == 256, tags[258] == 32, tags[259] == 1,
                  tags[262] == 1, tags[339] == 3, (tags[277] ?? 1) == 1,
                  (tags[274] ?? 1) == 1, (tags[284] ?? 1) == 1,
                  tags[278] == 256, tags[279] == UInt32(Self.pixelBytes), let strip = tags[273],
                  UInt64(strip) >= 8, UInt64(strip) + UInt64(Self.pixelBytes) <= size,
                  UInt64(strip) + UInt64(Self.pixelBytes) <= offset || UInt64(strip) >= offset + UInt64(2 + directory.count) else { throw invalid }
            strips.append(UInt64(strip))
            regions.append(UInt64(strip)..<(UInt64(strip) + UInt64(Self.pixelBytes)))
            offset = UInt64(u32(directory, count * 12))
        }
        guard let metadata else { return nil }
        guard strips.count == metadata.targets.count * metadata.positions.count, Set(strips).count == strips.count else { throw invalid }
        regions.sort { $0.lowerBound < $1.lowerBound }
        for i in 1..<regions.count where regions[i - 1].upperBound > regions[i].lowerBound { throw invalid }
        return FocusConstellationRecording(metadata: metadata, url: url, strips: strips)
    }

    public func loadLayer(index: Int) throws -> ConstellationResult {
        guard metadata.positions.indices.contains(index) else { throw CameraError.unsupported("Invalid recorded focus index.") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        var tiles: [ConstellationTile] = []
        for (star, target) in metadata.targets.enumerated() {
            try Task.checkCancellation()
            let data = try Self.read(file, at: strips[star * metadata.positions.count + index], count: Self.pixelBytes, size: size)
            var pixels = [Float](repeating: 0, count: 256 * 256)
            // Copy the contiguous float strip without four Foundation Data subscripts per pixel.
            // Raw-byte copying does not require the file buffer to be aligned as Float.
            pixels.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in destination.copyMemory(from: source) }
            }
            if UInt32(littleEndian: 1) != 1 {
                for pixel in pixels.indices { pixels[pixel] = Float(bitPattern: UInt32(littleEndian: pixels[pixel].bitPattern)) }
            }
            guard pixels.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw CameraError.unsupported("Focus constellation TIFF contains invalid pixels.")
            }
            tiles.append(ConstellationTile(row: target.row, column: target.column,
                image: StackedImage(width: 256, height: 256, pixels: pixels, roi: ROI(x: 0, y: 0, width: 256, height: 256))))
        }
        return try ConstellationResult(tiles: tiles, sourceURL: url, layout: metadata.layout, focusRecording: self, focusIndex: index)
    }

    private static func read(_ file: FileHandle, at offset: UInt64, count: Int, size: UInt64) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
            throw CameraError.unsupported("Truncated focus constellation TIFF.")
        }
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: count), data.count == count else {
            throw CameraError.unsupported("Truncated focus constellation TIFF.")
        }
        return data
    }
    private static func u16(_ data: Data, _ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
    }
}

/// Calls are sequential and awaited off the engine actor. No complete sweep is held in memory.
public final class FocusConstellationWriter: @unchecked Sendable {
    private let destination: URL
    private let temporary: URL
    private let metadata: FocusConstellationMetadata
    private let file: FileHandle
    private var previousLink: UInt64 = 4
    private var count = 0
    private var committed = false

    public init(to destination: URL, metadata: FocusConstellationMetadata) throws {
        try metadata.validate()
        self.destination = destination; self.metadata = metadata
        temporary = destination.deletingLastPathComponent().appendingPathComponent(".focus-\(UUID()).tif")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CameraError.unsupported("Could not create the focus constellation TIFF.")
        }
        file = try FileHandle(forWritingTo: temporary)
        try file.write(contentsOf: Data([73, 73, 42, 0, 0, 0, 0, 0]))
    }
    deinit {
        try? file.close()
        if !committed { try? FileManager.default.removeItem(at: temporary) }
    }

    public func append(_ image: StackedImage) throws {
        guard !committed, count < metadata.targets.count * metadata.positions.count,
              image.width == 256, image.height == 256, image.pixels.count == 256 * 256,
              image.pixels.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw CameraError.unsupported("Invalid focus constellation capture tile.")
        }
        var description: Data?
        if count == 0 {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            description = try encoder.encode(metadata)
        }
        // Reuse the ordinary TIFF encoder, rebasing its offsets into this page's location.
        var page = try MonoTIFF.encode(floats: image.pixels, width: 256, height: 256, imageDescription: description)
        let base = try file.seekToEnd()
        let directory = 8 + 256 * 256 * 4
        let entryCount = description == nil ? 10 : 11
        let pageIFD = UInt32(base) + UInt32(directory)
        for entry in 0..<entryCount {
            let at = directory + 2 + entry * 12
            let tag = UInt16(page[at]) | UInt16(page[at + 1]) << 8
            if tag == 273 { Self.put(UInt32(base) + 8, in: &page, at: at + 8) }
            if tag == 270 { Self.put(UInt32(base) + UInt32(directory + 2 + entryCount * 12 + 4), in: &page, at: at + 8) }
        }
        // Each embedded page's redundant eight-byte header is harmless padding.
        page.append(contentsOf: repeatElement(UInt8(0), count: (4 - page.count % 4) % 4))
        try file.write(contentsOf: page)
        try file.seek(toOffset: previousLink)
        var link = Data(repeating: 0, count: 4); Self.put(pageIFD, in: &link, at: 0)
        try file.write(contentsOf: link)
        previousLink = UInt64(pageIFD) + UInt64(2 + entryCount * 12)
        count += 1
    }

    public func finish() throws {
        guard !committed, count == metadata.targets.count * metadata.positions.count else {
            throw CameraError.unsupported("Focus constellation capture is incomplete.")
        }
        try file.synchronize(); try file.close()
        try AtomicFile.commit(temporary, to: destination)
        committed = true
    }
    private static func put(_ value: UInt32, in data: inout Data, at offset: Int) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
}
