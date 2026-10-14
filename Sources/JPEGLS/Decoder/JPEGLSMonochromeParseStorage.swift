import Foundation

/// Alternative storage policy for the canonical parser, confined to a synchronous
/// monochrome decode. All variable payloads remain in the caller's encoded span.
/// Two passes use the same parser: inspect final presets/selectors, then reconstruct
/// regions while gathering only the selected palette. No restart list is retained.
internal struct JPEGLSMonochromeParseStorage: JPEGLSParseStorage {
    static let monochrome = true
    private let widths: UnsafeMutableBufferPointer<Int>
    private let values: UnsafeMutableBufferPointer<UInt16>
    private let selectedTable: UInt8?
    private(set) var mappingCount = 0
    private(set) var hasMappingTables = false
    private(set) var restartCount = 0
    private(set) var restartOrderValid = true
    var consumer: JPEGLSMonochromeRegionConsumer?

    init(widths: UnsafeMutableBufferPointer<Int>, values: UnsafeMutableBufferPointer<UInt16>,
         selectedTable: UInt8? = nil, consumer: JPEGLSMonochromeRegionConsumer? = nil) {
        self.consumer = consumer
        self.widths = widths; self.values = values; self.selectedTable = selectedTable
        widths.initialize(repeating: 0)
        values.initialize(repeating: 0)
    }

    mutating func region(_ range: Range<Int>, marker: UInt8?) -> JPEGLSManagedFailure? {
        if let marker {
            if marker != JPEGLSMarker.restart0.rawValue + UInt8(restartCount % 8) {
                restartOrderValid = false
            }
            restartCount += 1
        }
        return consumer?.consume(range, marker: marker)
    }

    func validateRestarts(_ parsed: JPEGLSParseState) -> JPEGLSManagedFailure? {
        let interval = parsed.scanRestartInterval
        let height = parsed.frameHeader.height
        let expected = interval > 0 && interval < height ? (height - 1) / interval : 0
        guard restartCount == expected, restartOrderValid else {
            return JPEGLSManagedFailure(.restartCycle)
        }
        return nil
    }

    mutating func replaceMapping(id: UInt8, width: Int, range: Range<Int>, reader: JPEGLSBitstreamCursor) -> JPEGLSManagedFailure? {
        guard id > 0 else {
            return JPEGLSManagedFailure(.mappingID)
        }
        hasMappingTables = true
        widths[Int(id)] = width
        if selectedTable == id {
            mappingCount = 0
            copyEntries(range, width: width, reader: reader)
        }
        return nil
    }

    // Borrowed mode historically validates the complete encoded span first.
    func preflightContinuation(id: UInt8, byteCount: Int) -> JPEGLSManagedFailure? { nil }

    mutating func continueMapping(id: UInt8, range: Range<Int>, reader: JPEGLSBitstreamCursor) -> JPEGLSManagedFailure? {
        let width = widths[Int(id)]
        if width == 0 { return nil } // Preserve unknown-table continuation behavior.
        guard range.count % width == 0 else {
            return JPEGLSManagedFailure(.mappingContinuation)
        }
        if selectedTable == id { copyEntries(range, width: width, reader: reader) }
        return nil
    }

    private mutating func copyEntries(_ range: Range<Int>, width: Int, reader: JPEGLSBitstreamCursor) {
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

    mutating func scan(_ header: JPEGLSScanFields, interval: Int) {}
    mutating func scanRange(_ range: Range<Int>) {}
    mutating func application(_ marker: JPEGLSMarker, range: Range<Int>, reader: JPEGLSBitstreamCursor) {}
    mutating func comment(_ range: Range<Int>, reader: JPEGLSBitstreamCursor) {}

    func mapped(_ sample: UInt16) -> UInt16 {
        Int(sample) < mappingCount ? values[Int(sample)] : sample
    }
}
