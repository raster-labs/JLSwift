/// JPEG-LS bitstream parser per ISO/IEC 14495-1:1999 / ITU-T.87
///
/// Parses JPEG-LS encoded data streams, extracting frame headers, scan headers,
/// preset parameters, and locating compressed image data.
///
/// ## Entropy stuffing and unknown markers
///
/// Within scan data, an `0xFF` byte followed by a byte whose most-significant
/// bit is zero is treated as stuffed entropy data per ITU-T.87 §9.1. Outside a
/// scan, the parser also tolerates low-valued standalone continuation codes in
/// the `0x60...0x7F` range and skips unknown length-prefixed marker segments.

import Foundation

/// Result of parsing a JPEG-LS bitstream
///
/// Contains all metadata needed for decoding the image data.
public struct JPEGLSParseResult: Sendable {
    /// Frame header describing image dimensions and components
    public let frameHeader: JPEGLSFrameHeader
    
    /// Scan headers for each scan in the image
    public let scanHeaders: [JPEGLSScanHeader]
    
    /// Preset parameters (if custom parameters were specified via LSE marker)
    public let presetParameters: JPEGLSPresetParameters?
    
    /// Restart interval in MCUs (if a DRI marker was present, otherwise nil)
    public let restartInterval: Int?
    
    /// Mapping tables keyed by table ID (parsed from LSE type 2/3 markers).
    ///
    /// When a scan component references a table ID > 0, decoded raw sample
    /// values are used as indices into the corresponding mapping table.
    public let mappingTables: [UInt8: JPEGLSMappingTable]
    
    /// Application marker data (APP0-APP15)
    public let applicationMarkers: [(marker: JPEGLSMarker, data: Data)]
    
    /// Comment marker data
    public let comments: [Data]
    
    /// Colour transformation signalled by an APP8 "mrfx" marker (default: .none).
    ///
    /// The encoder writes an APP8 segment with the four-byte identifier "mrfx"
    /// followed by a single byte containing the transform ID.  The decoder reads
    /// this marker and applies the corresponding inverse transform after decoding.
    public let colorTransformation: JPEGLSColorTransformation

    /// Byte ranges of each scan's entropy-coded body within the parsed data,
    /// one per scan header, in scan order.  The parser already walks every
    /// scan body to find the terminating marker; recording the offsets here
    /// lets the decoder slice the original data directly instead of doing a
    /// second full-file marker walk.  Empty when the result was constructed
    /// without parsing (the decoder then falls back to its own walk).
    public let scanDataRanges: [Range<Int>]

    /// The restart interval (DRI value) in effect at each scan's SOS marker,
    /// one per scan header, in scan order (0 = none).  Per T.81 B.2.4.4 a
    /// DRI segment between scans applies to following scans only, so a
    /// single file-global value cannot represent multi-scan streams that
    /// (re)define it.  Empty when the result was constructed without parsing.
    public let scanRestartIntervals: [Int]

    /// Initialize parse result
    ///
    /// - Parameters:
    ///   - frameHeader: Frame header
    ///   - scanHeaders: Scan headers
    ///   - presetParameters: Optional custom preset parameters
    ///   - restartInterval: Optional restart interval from DRI marker
    ///   - mappingTables: Mapping tables keyed by table ID
    ///   - applicationMarkers: Application markers
    ///   - comments: Comment data
    ///   - colorTransformation: Colour transform from APP8 "mrfx" marker (default: .none)
    ///   - scanDataRanges: Byte ranges of each scan body (default: empty)
    ///   - scanRestartIntervals: Restart interval in effect at each SOS (default: empty)
    public init(
        frameHeader: JPEGLSFrameHeader,
        scanHeaders: [JPEGLSScanHeader],
        presetParameters: JPEGLSPresetParameters? = nil,
        restartInterval: Int? = nil,
        mappingTables: [UInt8: JPEGLSMappingTable] = [:],
        applicationMarkers: [(marker: JPEGLSMarker, data: Data)] = [],
        comments: [Data] = [],
        colorTransformation: JPEGLSColorTransformation = .none,
        scanDataRanges: [Range<Int>] = [],
        scanRestartIntervals: [Int] = []
    ) {
        self.frameHeader = frameHeader
        self.scanHeaders = scanHeaders
        self.presetParameters = presetParameters
        self.restartInterval = restartInterval
        self.mappingTables = mappingTables
        self.applicationMarkers = applicationMarkers
        self.comments = comments
        self.colorTransformation = colorTransformation
        self.scanDataRanges = scanDataRanges
        self.scanRestartIntervals = scanRestartIntervals
    }
}

/// JPEG-LS bitstream parser
///
/// Parses JPEG-LS file format according to ITU-T.87 standard.
/// Validates marker sequence and extracts all necessary metadata for decoding.
public final class JPEGLSParser {
    private var core: JPEGLSParserCore
    private var storage = JPEGLSLegacyParseStorage()
    public init(data: Data) {
        core = JPEGLSParserCore(reader: JPEGLSBitstreamCursor(data: data))
    }
    public func parse() throws -> JPEGLSParseResult {
        // Results are per invocation even when a caller retries from the current
        // cursor after an error, matching the original parser's local storage.
        storage = JPEGLSLegacyParseStorage()
        switch core.parse(storage: &storage) {
        case .success(let state):
            return JPEGLSParseResult(frameHeader: JPEGLSFrameHeader(validated: state.frameHeader),
                scanHeaders: storage.scanHeaders, presetParameters: state.presetParameters,
                restartInterval: state.restartInterval, mappingTables: storage.mappingTables,
                applicationMarkers: storage.applicationMarkers, comments: storage.comments,
                colorTransformation: state.colorTransformation, scanDataRanges: storage.scanDataRanges,
                scanRestartIntervals: storage.scanRestartIntervals)
        case .failure(let failure):
            throw failure.legacyError
        }
    }
}

internal struct JPEGLSParseState {
    let frameHeader: JPEGLSFrameFields
    let firstScan: JPEGLSScanFields
    let scanCount: Int
    let presetParameters: JPEGLSPresetParameters?
    let restartInterval: Int?
    let scanRestartInterval: Int
    let colorTransformation: JPEGLSColorTransformation
}

/// One grammar; storage policy selects legacy owned collections or caller borrows.
internal struct JPEGLSParserCore {
    var reader: JPEGLSBitstreamCursor
    /// Parse the JPEG-LS bitstream
    ///
    /// Validates the structure and extracts all metadata.
    ///
    /// The parser handles JPEG-LS marker segments and stuffed entropy data.
    /// Unknown length-prefixed markers and defensive low-valued continuation
    /// codes in the `0x60...0x7F` range are skipped.
    ///
    /// - Returns: Parsed frame, scan and preset facts, or a scalar failure without
    ///   invoking Swift's throwing runtime.
    mutating func parse<Storage: JPEGLSParseStorage>(storage: inout Storage) -> JPEGLSManagedOutcome<JPEGLSParseState> {
        // Parse SOI marker
        if let failure = expectMarker(.startOfImage) { return .failure(failure) }
        
        var frameHeader: JPEGLSFrameFields?
        var scanCount = 0
        var firstScan: JPEGLSScanFields?
        var firstScanRestartInterval = 0
        var presetParameters: JPEGLSPresetParameters?
        var restartInterval: Int?
        var extendedWidth: Int?
        var extendedHeight: Int?
        var colorTransformation: JPEGLSColorTransformation = .none

        // Parse marker segments until EOI
        while !reader.isAtEnd {
            if let failure = reader.cancellation.checkpoint() { return .failure(failure) }
            // Read marker bytes manually to handle unknown markers
            let byte1: UInt8
            switch reader.readByte() {
            case .success(let value): byte1 = value
            case .failure(let failure): return .failure(failure)
            }
            guard byte1 == JPEGLSMarker.markerPrefix else {
                return .failure(JPEGLSManagedFailure(.expectedPrefix, Int(byte1)))
            }
            
            var byte2: UInt8
            switch reader.readByte() {
            case .success(let value): byte2 = value
            case .failure(let failure): return .failure(failure)
            }

            // ITU-T T.81 B.1.1.2 (inherited by T.87): any marker may be preceded
            // by any number of 0xFF fill bytes. Encoders such as CharLS emit one
            // before EOI when the entropy coder's last byte is 0xFF, so skip fill
            // bytes before interpreting the marker code.
            while byte2 == JPEGLSMarker.markerPrefix {
                switch reader.readByte() {
                case .success(let value): byte2 = value
                case .failure(let failure): return .failure(failure)
                }
            }

            // Try to parse as known marker
            guard let marker = JPEGLSMarker(rawValue: byte2) else {
                // Unknown marker - skip it gracefully
                // Some markers have no length field (standalone markers)
                if (byte2 >= 0xD0 && byte2 <= 0xD7) || byte2 == 0xD8 || byte2 == 0xD9 {
                    // RST markers (0xD0-0xD7), SOI (0xD8), and EOI (0xD9) have no length field
                    continue
                } else if byte2 >= 0x60 && byte2 <= 0x7F {
                    // Defensive compatibility: tolerate low-valued standalone
                    // continuation codes without interpreting a length field.
                    continue
                } else {
                    // Read length and skip the marker segment
                    let length: UInt16
                    switch reader.readUInt16() {
                    case .success(let value): length = value
                    case .failure(let failure): return .failure(failure)
                    }
                    guard length >= 2 else {
                        return .failure(JPEGLSManagedFailure(.unknownMarkerLength, Int(byte2), Int(length)))
                    }
                    let skipLength = Int(length) - 2
                    if case .failure(let failure) = reader.readRange(skipLength) { return .failure(failure) }
                    continue
                }
            }
            
            switch marker {
            case .endOfImage:
                // A decoder consumes one complete codestream. Permit only the single
                // zero byte needed to even-pad an odd stream in DICOM PS3.5 A.4.
                if reader.bytesRemaining > 0 {
                    guard reader.currentPosition % 2 == 1, reader.bytesRemaining == 1 else {
                        return .failure(JPEGLSManagedFailure(.trailingBytes))
                    }
                    let padding: UInt8
                    switch reader.readByte() {
                    case .success(let value): padding = value
                    case .failure(let failure): return .failure(failure)
                    }
                    guard padding == 0 else { return .failure(JPEGLSManagedFailure(.trailingBytes)) }
                }
                guard let frame = frameHeader else {
                    return .failure(JPEGLSManagedFailure(.missingFrame))
                }
                guard scanCount > 0 else {
                    return .failure(JPEGLSManagedFailure(.missingScan))
                }
                return .success(JPEGLSParseState(frameHeader: frame, firstScan: firstScan!, scanCount: scanCount,
                    presetParameters: presetParameters, restartInterval: restartInterval,
                    scanRestartInterval: firstScanRestartInterval, colorTransformation: colorTransformation))
                
            case .startOfFrameJPEGLS:
                // Parse frame header
                guard frameHeader == nil else {
                    return .failure(JPEGLSManagedFailure(.multipleFrames))
                }
                switch parseFrameHeader(monochrome: Storage.monochrome,
                    extendedWidth: extendedWidth, extendedHeight: extendedHeight) {
                case .success(let value): frameHeader = value
                case .failure(let failure): return .failure(failure)
                }
                
            case .startOfScan:
                // Parse scan header
                guard let frame = frameHeader else {
                    return .failure(JPEGLSManagedFailure(.scanBeforeFrame))
                }
                if Storage.monochrome, scanCount > 0 {
                    return .failure(JPEGLSManagedFailure(.monochromeScanCount))
                }
                let scanHeader: JPEGLSScanFields
                switch parseScanHeader(frameHeader: frame, monochrome: Storage.monochrome) {
                case .success(let value): scanHeader = value
                case .failure(let failure): return .failure(failure)
                }
                scanCount += 1
                if firstScan == nil { firstScan = scanHeader; firstScanRestartInterval = restartInterval ?? 0 }
                storage.scan(scanHeader, interval: restartInterval ?? 0)
                // Record the restart interval in effect at this SOS (a DRI
                // between scans applies to following scans only, T.81 B.2.4.4).

                // Skip scan data until we hit a marker, recording the body's
                // byte range so the decoder can slice it without a second
                // full-file walk.
                // Per ISO 14495-1 §9.1, a byte following 0xFF with MSB = 0 (value < 0x80)
                // is a stuffed byte; with MSB = 1 (value ≥ 0x80) it is a real marker.
                let scanStart = reader.currentPosition
                var regionStart = scanStart
                var scanEnd: Int? = nil
                while !reader.isAtEnd {
                    let byte: UInt8
                    switch reader.readByte() {
                    case .success(let value): byte = value
                    case .failure(let failure): return .failure(failure)
                    }
                    if byte == JPEGLSMarker.markerPrefix {
                        // Check next byte to determine if it's stuffing or a real marker
                        if let nextByte = reader.peekByte() {
                            if nextByte >= JPEGLSMarker.restart0.rawValue
                                && nextByte <= JPEGLSMarker.restart7.rawValue {
                                // Restart marker (FFD0–FFD7) inside the scan
                                // body: part of the entropy-coded segment, not
                                // a scan terminator. Consume and continue.
                                let regionEnd = reader.currentPosition - 1
                                if case .failure(let failure) = reader.readByte() { return .failure(failure) }
                                if let failure = storage.region(regionStart..<regionEnd, marker: nextByte) { return .failure(failure) }
                                regionStart = reader.currentPosition
                                continue
                            }
                            if nextByte >= 0x80 {
                                // Real marker — back up to re-read the FF byte in the outer loop
                                if let failure = reader.seek(to: reader.currentPosition - 1) { return .failure(failure) }
                                scanEnd = reader.currentPosition
                                break
                            }
                            // nextByte < 0x80: stuffed byte — consume it and continue
                            if case .failure(let failure) = reader.readByte() { return .failure(failure) }
                        } else {
                            // End of stream: a trailing lone 0xFF is not scan data
                            scanEnd = reader.currentPosition - 1
                            break
                        }
                    }
                }
                let end = scanEnd ?? reader.currentPosition
                storage.scanRange(scanStart..<end)
                if let failure = storage.region(regionStart..<end, marker: nil) { return .failure(failure) }
                
            case .jpegLSExtension:
                // Parse JPEG-LS extension
                if let failure = parseJPEGLSExtension(
                    storage: &storage,
                    frameHeader: frameHeader,
                    presetParameters: &presetParameters,
                    extendedWidth: &extendedWidth,
                    extendedHeight: &extendedHeight
                ) { return .failure(failure) }
                
            case .applicationMarker0, .applicationMarker1, .applicationMarker2,
                 .applicationMarker3, .applicationMarker4, .applicationMarker5,
                 .applicationMarker6, .applicationMarker7, .applicationMarker8,
                 .applicationMarker9, .applicationMarker10, .applicationMarker11,
                 .applicationMarker12, .applicationMarker13, .applicationMarker14,
                 .applicationMarker15:
                let range: Range<Int>
                switch parseMarkerRange() {
                case .success(let value): range = value
                case .failure(let failure): return .failure(failure)
                }
                storage.application(marker, range: range, reader: reader)
                // Inspect the existing APP8 signal in place; no payload copy.
                if marker == .applicationMarker8, range.count >= 5 {
                    let i = range.lowerBound
                    if reader.byte(at: i) == 0x6D && reader.byte(at: i + 1) == 0x72 &&
                       reader.byte(at: i + 2) == 0x66 && reader.byte(at: i + 3) == 0x78,
                       let ct = JPEGLSColorTransformation(rawValue: reader.byte(at: i + 4)) {
                        colorTransformation = ct
                    }
                }

            case .comment:
                let range: Range<Int>
                switch parseMarkerRange() {
                case .success(let value): range = value
                case .failure(let failure): return .failure(failure)
                }
                storage.comment(range, reader: reader)
                
            case .restart0, .restart1, .restart2, .restart3,
                 .restart4, .restart5, .restart6, .restart7:
                // Restart markers have no length field, just skip
                continue
                
            case .defineRestartInterval:
                // Parse Define Restart Interval (DRI) marker per ITU-T.87 §5.1
                switch parseRestartInterval() {
                case .success(let value): restartInterval = value
                case .failure(let failure): return .failure(failure)
                }
                
            case .defineNumberOfLines:
                // Parse Define Number of Lines (DNL) marker per ITU-T.87 §5.1.
                // DNL may appear after the first scan to supply the Y value when it was
                // unknown (Y=0) at SOF time. Frame dimensions are already known from the
                // SOF marker in typical usage, so the DNL payload is consumed but not
                // applied. Full DNL-based dimension update is deferred to a future milestone.
                if case .failure(let failure) = parseMarkerRange() { return .failure(failure) }
                
            case .startOfImage:
                return .failure(JPEGLSManagedFailure(.unexpectedSOI))
            }
        }
        
        return .failure(JPEGLSManagedFailure(.missingEOI))
    }
    
    // MARK: - Private Parsing Methods
    
    /// Expect a specific marker
    private mutating func expectMarker(_ expected: JPEGLSMarker) -> JPEGLSManagedFailure? {
        let marker: JPEGLSMarker
        switch reader.readMarker() {
        case .success(let value): marker = value
        case .failure(let failure): return failure
        }
        guard marker == expected else {
            return JPEGLSManagedFailure(.expectedMarker, Int(expected.rawValue), Int(marker.rawValue))
        }
        return nil
    }
    
    /// Parse a generic marker segment with length field
    private mutating func parseMarkerRange() -> JPEGLSManagedOutcome<Range<Int>> {
        let length: UInt16
        switch reader.readUInt16() {
        case .success(let value): length = value
        case .failure(let failure): return .failure(failure)
        }
        guard length >= 2 else {
            return .failure(JPEGLSManagedFailure(.markerLength, Int(length)))
        }
        // Length includes the 2 bytes of the length field itself
        let dataLength = Int(length) - 2
        return reader.readRange(dataLength)
    }
    
    /// Parse frame header (SOF marker segment)
    private mutating func parseFrameHeader(monochrome: Bool,
        extendedWidth: Int? = nil, extendedHeight: Int? = nil) -> JPEGLSManagedOutcome<JPEGLSFrameFields> {
        let length: UInt16
        switch reader.readUInt16() {
        case .success(let value): length = value
        case .failure(let failure): return .failure(failure)
        }
        
        // Read precision (bits per sample)
        let bitsPerSample: Int
        switch reader.readByte() {
        case .success(let value): bitsPerSample = Int(value)
        case .failure(let failure): return .failure(failure)
        }
        
        // Read dimensions from SOF.  When a dimension is 0, the actual value comes
        // from a preceding LSE type 4 (extended dimensions) segment per ITU-T.87 §5.1.1.4.
        let sofHeight: Int
        switch reader.readUInt16() {
        case .success(let value): sofHeight = Int(value)
        case .failure(let failure): return .failure(failure)
        }
        let sofWidth: Int
        switch reader.readUInt16() {
        case .success(let value): sofWidth = Int(value)
        case .failure(let failure): return .failure(failure)
        }
        let height = (sofHeight == 0) ? (extendedHeight ?? sofHeight) : sofHeight
        let width  = (sofWidth  == 0) ? (extendedWidth  ?? sofWidth)  : sofWidth
        
        // Read component count
        let componentCount: Int
        switch reader.readByte() {
        case .success(let value): componentCount = Int(value)
        case .failure(let failure): return .failure(failure)
        }
        if monochrome, componentCount != 1 {
            return .failure(JPEGLSManagedFailure(.monochromeComponentCount))
        }
        
        // Validate expected length
        let expectedLength = 2 + 1 + 2 + 2 + 1 + (componentCount * 3)
        guard length == expectedLength else {
            return .failure(JPEGLSManagedFailure(.sofLength, expectedLength, Int(length)))
        }
        
        // Read component specifications
        var components = JPEGLSInline4(repeating: JPEGLSFrameHeader.ComponentSpec(id: 0))
        
        for _ in 0..<componentCount {
            let id: UInt8
            switch reader.readByte() {
            case .success(let value): id = value
            case .failure(let failure): return .failure(failure)
            }
            let samplingFactors: UInt8
            switch reader.readByte() {
            case .success(let value): samplingFactors = value
            case .failure(let failure): return .failure(failure)
            }
            let horizontalSampling = samplingFactors >> 4
            let verticalSampling = samplingFactors & 0x0F
            // Quantization table selector (not used in JPEG-LS).
            if case .failure(let failure) = reader.readByte() { return .failure(failure) }
            
            if components.count < 4 { components.append(JPEGLSFrameHeader.ComponentSpec(
                id: id, horizontalSamplingFactor: horizontalSampling, verticalSamplingFactor: verticalSampling)) }
        }
        
        if let failure = JPEGLSFrameFields.validate(bitsPerSample: bitsPerSample, height: height,
            width: width, componentCount: componentCount, actualComponentCount: components.count) {
            return .failure(failure)
        }
        return .success(JPEGLSFrameFields(
            bitsPerSample: bitsPerSample,
            height: height,
            width: width,
            componentCount: componentCount,
            components: components
        ))
    }
    
    /// Parse scan header (SOS marker segment)
    private mutating func parseScanHeader(frameHeader: JPEGLSFrameFields,
        monochrome: Bool) -> JPEGLSManagedOutcome<JPEGLSScanFields> {
        let length: UInt16
        switch reader.readUInt16() {
        case .success(let value): length = value
        case .failure(let failure): return .failure(failure)
        }
        
        // Read component count in this scan
        let componentCount: Int
        switch reader.readByte() {
        case .success(let value): componentCount = Int(value)
        case .failure(let failure): return .failure(failure)
        }
        if monochrome, componentCount != 1 {
            return .failure(JPEGLSManagedFailure(.monochromeComponentCount))
        }
        
        // Validate expected length
        let expectedLength = 2 + 1 + (componentCount * 2) + 3
        guard length == expectedLength else {
            return .failure(JPEGLSManagedFailure(.sosLength, expectedLength, Int(length)))
        }
        
        // Read component selectors
        var components = JPEGLSInline4(repeating: JPEGLSScanHeader.ComponentSelector(id: 0))
        
        for _ in 0..<componentCount {
            let id: UInt8
            switch reader.readByte() {
            case .success(let value): id = value
            case .failure(let failure): return .failure(failure)
            }
            // Tdi field: mapping table ID per ITU-T.87 §5.1.2.
            // 0 means no mapping table; 1–255 references a mapping table from an LSE type 2/3 marker.
            let mappingTableID: UInt8
            switch reader.readByte() {
            case .success(let value): mappingTableID = value
            case .failure(let failure): return .failure(failure)
            }
            if components.count < 4 { components.append(JPEGLSScanHeader.ComponentSelector(id: id, mappingTableID: mappingTableID)) }
        }
        
        // Read NEAR parameter
        let near: Int
        switch reader.readByte() {
        case .success(let value): near = Int(value)
        case .failure(let failure): return .failure(failure)
        }
        
        // Read interleave mode
        let interleaveModeValue: UInt8
        switch reader.readByte() {
        case .success(let value): interleaveModeValue = value
        case .failure(let failure): return .failure(failure)
        }
        guard let interleaveMode = JPEGLSInterleaveMode(rawValue: interleaveModeValue) else {
            return .failure(JPEGLSManagedFailure(.interleaveMode, Int(interleaveModeValue)))
        }
        
        // Read point transform
        let pointTransform: Int
        switch reader.readByte() {
        case .success(let value): pointTransform = Int(value)
        case .failure(let failure): return .failure(failure)
        }
        
        if let failure = JPEGLSScanFields.validate(componentCount: componentCount,
            actualComponentCount: components.count, near: near, interleaveMode: interleaveMode,
            pointTransform: pointTransform) { return .failure(failure) }
        let scanHeader = JPEGLSScanFields(
            componentCount: componentCount,
            components: components,
            near: near,
            interleaveMode: interleaveMode,
            pointTransform: pointTransform
        )
        
        // Validate scan header against frame header
        if let failure = scanHeader.validate(against: frameHeader) { return .failure(failure) }
        
        return .success(scanHeader)
    }
    
    /// Parse JPEG-LS extension marker (LSE)
    private mutating func parseJPEGLSExtension<Storage: JPEGLSParseStorage>(
        storage: inout Storage,
        frameHeader: JPEGLSFrameFields?,
        presetParameters: inout JPEGLSPresetParameters?,
        extendedWidth: inout Int?,
        extendedHeight: inout Int?
    ) -> JPEGLSManagedFailure? {
        let length: UInt16
        switch reader.readUInt16() {
        case .success(let value): length = value
        case .failure(let failure): return failure
        }
        // Length includes the 2-byte length field and the 1-byte type that
        // follows; anything shorter is structurally invalid (and would make
        // the skip count below negative).
        guard length >= 3 else {
            return JPEGLSManagedFailure(.lseLength, Int(length))
        }

        // Read extension type
        let extensionTypeByte: UInt8
        switch reader.readByte() {
        case .success(let value): extensionTypeByte = value
        case .failure(let failure): return failure
        }
        guard let extensionType = JPEGLSExtensionType(rawValue: extensionTypeByte) else {
            // Unknown extension type - skip the rest
            let skipLength = Int(length) - 3  // Length includes itself (2) and type (1)
            if case .failure(let failure) = reader.readRange(skipLength) { return failure }
            return nil
        }
        
        switch extensionType {
        case .presetCodingParameters:
            // Parse preset parameters
            // Length should be 13: 2 (length field) + 1 (type) + 10 (5 x 2-byte params)
            guard length == 13 else {
                return JPEGLSManagedFailure(.presetLength, Int(length))
            }
            
            let maxValue: Int
            switch reader.readUInt16() {
            case .success(let value): maxValue = Int(value)
            case .failure(let failure): return failure
            }
            let threshold1: Int
            switch reader.readUInt16() {
            case .success(let value): threshold1 = Int(value)
            case .failure(let failure): return failure
            }
            let threshold2: Int
            switch reader.readUInt16() {
            case .success(let value): threshold2 = Int(value)
            case .failure(let failure): return failure
            }
            let threshold3: Int
            switch reader.readUInt16() {
            case .success(let value): threshold3 = Int(value)
            case .failure(let failure): return failure
            }
            let reset: Int
            switch reader.readUInt16() {
            case .success(let value): reset = Int(value)
            case .failure(let failure): return failure
            }
            
            switch JPEGLSPresetParameters.qualified(maxValue: maxValue, threshold1: threshold1,
                threshold2: threshold2, threshold3: threshold3, reset: reset) {
            case .success(let value): presetParameters = value
            case .failure(let failure): return failure
            }
            
        case .mappingTable:
            // Parse mapping table specification per ITU-T.87 §5.1.1.3.
            // Format: Length(2) + Type(1) + TID(1) + Wt(1) + Entries((Length-5)*1 or (Length-5)/2)
            // Minimum length = 5 (no entries)
            guard length >= 5 else {
                return JPEGLSManagedFailure(.mappingLength, Int(length))
            }
            let tableID: UInt8
            switch reader.readByte() {
            case .success(let value): tableID = value
            case .failure(let failure): return failure
            }
            let entryWidth: Int
            switch reader.readByte() {
            case .success(let value): entryWidth = Int(value)
            case .failure(let failure): return failure
            }
            guard entryWidth == 1 || entryWidth == 2 else {
                return JPEGLSManagedFailure(.mappingWidth, entryWidth)
            }
            // Data bytes = length - 5 (subtract: 2 for Ll, 1 for Id, 1 for TID, 1 for Wt)
            let dataBytes = Int(length) - 5
            guard dataBytes >= 0 && dataBytes % entryWidth == 0 else {
                return JPEGLSManagedFailure(.mappingRemainder, dataBytes, entryWidth)
            }
            let range: Range<Int>
            switch reader.readRange(dataBytes) {
            case .success(let value): range = value
            case .failure(let failure): return failure
            }
            if let failure = storage.replaceMapping(id: tableID, width: entryWidth, range: range, reader: reader) { return failure }

        case .mappingTableContinuation:
            // Append additional entries to an existing mapping table per ITU-T.87 §5.1.1.3.
            // Format: Length(2) + Type(1) + TID(1) + Entries((Length-4) bytes or /2)
            guard length >= 4 else {
                return JPEGLSManagedFailure(.continuationLength, Int(length))
            }
            let tableID: UInt8
            switch reader.readByte() {
            case .success(let value): tableID = value
            case .failure(let failure): return failure
            }
            // data bytes = length - 4 (subtract: 2 for Ll, 1 for Id, 1 for TID)
            let dataBytes = Int(length) - 4
            if let failure = storage.preflightContinuation(id: tableID, byteCount: dataBytes) { return failure }
            let range: Range<Int>
            switch reader.readRange(dataBytes) {
            case .success(let value): range = value
            case .failure(let failure): return failure
            }
            if let failure = storage.continueMapping(id: tableID, range: range, reader: reader) { return failure }

        case .extendedDimensions:
            // Parse extended X/Y dimensions per ITU-T.87 §5.1.1.4.
            // Format: Ll(2) + Id(1) + Wxy(1) + XSIZE(Wxy bytes) + YSIZE(Wxy bytes)
            // remainingBytes = everything after Ll (2) and Id (1) that has already been read.
            let remainingBytes = Int(length) - 3
            guard remainingBytes >= 1 else {
                return JPEGLSManagedFailure(.extendedLength, Int(length))
            }
            let wxy: Int
            switch reader.readByte() {
            case .success(let value): wxy = Int(value)
            case .failure(let failure): return failure
            }
            // Wxy must be 1, 2, or 4 and the remaining bytes must be exactly 1 + 2*Wxy.
            guard (wxy == 1 || wxy == 2 || wxy == 4) && remainingBytes == 1 + 2 * wxy else {
                // Unsupported or malformed — skip remaining bytes gracefully.
                let skipLength = remainingBytes - 1
                if skipLength > 0 {
                    if case .failure(let failure) = reader.readRange(skipLength) { return failure }
                }
                return nil
            }
            // Read XSIZE (image width) as Wxy bytes, big-endian.
            var xSize = 0
            for _ in 0..<wxy {
                let byte: UInt8
                switch reader.readByte() {
                case .success(let value): byte = value
                case .failure(let failure): return failure
                }
                xSize = (xSize << 8) | Int(byte)
            }
            // Read YSIZE (image height) as Wxy bytes, big-endian.
            var ySize = 0
            for _ in 0..<wxy {
                let byte: UInt8
                switch reader.readByte() {
                case .success(let value): byte = value
                case .failure(let failure): return failure
                }
                ySize = (ySize << 8) | Int(byte)
            }
            extendedWidth  = xSize
            extendedHeight = ySize
        }
        return nil
    }
    
    /// Parse Define Restart Interval (DRI) marker segment per ITU-T.87 §5.1
    ///
    /// The DRI segment specifies the number of MCUs between restart markers.
    /// Length field is always 4 (2-byte length + 2-byte interval value).
    ///
    /// - Returns: Restart interval value (0 means restart markers are not used)
    private mutating func parseRestartInterval() -> JPEGLSManagedOutcome<Int> {
        let length: UInt16
        switch reader.readUInt16() {
        case .success(let value): length = value
        case .failure(let failure): return .failure(failure)
        }
        guard length == 4 else {
            return .failure(JPEGLSManagedFailure(.driLength, Int(length)))
        }
        let interval: UInt16
        switch reader.readUInt16() {
        case .success(let value): interval = value
        case .failure(let failure): return .failure(failure)
        }
        return .success(Int(interval))
    }
}
