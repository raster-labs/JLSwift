import Foundation

/// Alternative storage policy for the canonical parser, confined to a synchronous
/// monochrome decode. All variable payloads remain in the caller's encoded span.
/// Two passes use the same parser: inspect final presets/selectors, then reconstruct
/// regions while gathering only the selected palette. No restart list is retained.
internal final class JPEGLSMonochromeParseStorage {
    private let widths: UnsafeMutableBufferPointer<Int>
    private let values: UnsafeMutableBufferPointer<UInt16>
    private let selectedTable: UInt8?
    private(set) var mappingCount = 0
    private(set) var hasMappingTables = false
    private(set) var restartCount = 0
    private(set) var restartOrderValid = true
    var consumeRegion: ((Range<Int>, UInt8?) throws -> Void)?

    init(widths: UnsafeMutableBufferPointer<Int>, values: UnsafeMutableBufferPointer<UInt16>,
         selectedTable: UInt8? = nil) {
        self.widths = widths; self.values = values; self.selectedTable = selectedTable
        widths.initialize(repeating: 0)
        values.initialize(repeating: 0)
    }

    func region(_ range: Range<Int>, marker: UInt8?) throws {
        if let marker {
            if marker != JPEGLSMarker.restart0.rawValue + UInt8(restartCount % 8) {
                restartOrderValid = false
            }
            restartCount += 1
        }
        try consumeRegion?(range, marker)
    }

    func validateRestarts(_ parsed: JPEGLSParseResult) throws {
        let interval = parsed.scanRestartIntervals.first ?? 0
        let height = parsed.frameHeader.height
        let expected = interval > 0 && interval < height ? (height - 1) / interval : 0
        guard restartCount == expected, restartOrderValid else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "Invalid JPEG-LS restart count or cycle")
        }
    }

    func replaceMapping(id: UInt8, width: Int, range: Range<Int>, reader: JPEGLSBitstreamReader) throws {
        guard id > 0 else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "Mapping table ID must be in range [1, 255], got 0")
        }
        hasMappingTables = true
        widths[Int(id)] = width
        if selectedTable == id {
            mappingCount = 0
            copyEntries(range, width: width, reader: reader)
        }
    }

    func continueMapping(id: UInt8, range: Range<Int>, reader: JPEGLSBitstreamReader) throws {
        let width = widths[Int(id)]
        if width == 0 { return } // Preserve unknown-table continuation behavior.
        guard range.count % width == 0 else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "Mapping table continuation has incomplete entry")
        }
        if selectedTable == id { copyEntries(range, width: width, reader: reader) }
    }

    private func copyEntries(_ range: Range<Int>, width: Int, reader: JPEGLSBitstreamReader) {
        // Samples cannot index beyond 65535. Still validate the complete segment
        // range in the parser, but never expand unreachable palette entries.
        let count = min(range.count / width, values.count - mappingCount)
        for index in 0..<count {
            let offset = range.lowerBound + index * width
            let high = UInt16(reader.byte(at: offset))
            values[mappingCount + index] = width == 1 ? high : (high << 8) | UInt16(reader.byte(at: offset + 1))
        }
        mappingCount += count
    }

    func mapped(_ sample: UInt16) -> UInt16 {
        Int(sample) < mappingCount ? values[Int(sample)] : sample
    }
}
