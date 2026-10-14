import Foundation

/// Storage events emitted by the single canonical marker grammar. Generic value
/// dispatch keeps the qualified policy concrete; no existential or escaping sink.
internal protocol JPEGLSParseStorage {
    static var monochrome: Bool { get }
    mutating func scan(_ header: JPEGLSScanFields, interval: Int)
    mutating func scanRange(_ range: Range<Int>)
    mutating func region(_ range: Range<Int>, marker: UInt8?) -> JPEGLSManagedFailure?
    mutating func application(_ marker: JPEGLSMarker, range: Range<Int>, reader: JPEGLSBitstreamCursor)
    mutating func comment(_ range: Range<Int>, reader: JPEGLSBitstreamCursor)
    mutating func replaceMapping(id: UInt8, width: Int, range: Range<Int>, reader: JPEGLSBitstreamCursor) -> JPEGLSManagedFailure?
    func preflightContinuation(id: UInt8, byteCount: Int) -> JPEGLSManagedFailure?
    mutating func continueMapping(id: UInt8, range: Range<Int>, reader: JPEGLSBitstreamCursor) -> JPEGLSManagedFailure?
}

internal struct JPEGLSLegacyParseStorage: JPEGLSParseStorage {
    static let monochrome = false
    var scanHeaders: [JPEGLSScanHeader] = []
    var scanRestartIntervals: [Int] = []
    var scanDataRanges: [Range<Int>] = []
    var applicationMarkers: [(marker: JPEGLSMarker, data: Data)] = []
    var comments: [Data] = []
    var mappingTables: [UInt8: JPEGLSMappingTable] = [:]
    mutating func scan(_ header: JPEGLSScanFields, interval: Int) {
        scanHeaders.append(JPEGLSScanHeader(validated: header)); scanRestartIntervals.append(interval)
    }
    mutating func scanRange(_ range: Range<Int>) { scanDataRanges.append(range) }
    mutating func region(_ range: Range<Int>, marker: UInt8?) -> JPEGLSManagedFailure? { nil }
    mutating func application(_ marker: JPEGLSMarker, range: Range<Int>, reader: JPEGLSBitstreamCursor) {
        applicationMarkers.append((marker, reader.copy(range)))
    }
    mutating func comment(_ range: Range<Int>, reader: JPEGLSBitstreamCursor) { comments.append(reader.copy(range)) }
    mutating func replaceMapping(id: UInt8, width: Int, range: Range<Int>, reader: JPEGLSBitstreamCursor) -> JPEGLSManagedFailure? {
        guard id > 0 else { return JPEGLSManagedFailure(.mappingID) }
        mappingTables[id] = JPEGLSMappingTable(validatedID: id, entryWidth: width,
            entries: entries(range, width: width, reader: reader))
        return nil
    }
    func preflightContinuation(id: UInt8, byteCount: Int) -> JPEGLSManagedFailure? {
        if let table = mappingTables[id], byteCount % table.entryWidth != 0 {
            return JPEGLSManagedFailure(.continuationRemainder, byteCount, table.entryWidth)
        }
        return nil
    }
    mutating func continueMapping(id: UInt8, range: Range<Int>, reader: JPEGLSBitstreamCursor) -> JPEGLSManagedFailure? {
        guard let table = mappingTables[id] else { return nil }
        guard range.count % table.entryWidth == 0 else {
            return JPEGLSManagedFailure(.continuationRemainder, range.count, table.entryWidth)
        }
        mappingTables[id] = JPEGLSMappingTable(validatedID: id, entryWidth: table.entryWidth,
            entries: table.entries + entries(range, width: table.entryWidth, reader: reader))
        return nil
    }
    private func entries(_ range: Range<Int>, width: Int, reader: JPEGLSBitstreamCursor) -> [Int] {
        (0..<(range.count / width)).map { index in
            let offset = range.lowerBound + index * width
            let high = Int(reader.byte(at: offset))
            return width == 1 ? high : (high << 8) | Int(reader.byte(at: offset + 1))
        }
    }
}
