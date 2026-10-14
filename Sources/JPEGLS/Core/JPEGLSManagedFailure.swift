import Foundation

/// Nonthrowing result of a qualified synchronous operation. The failure payload
/// contains scalar facts only; constructing or inspecting it requires no Error
/// conformance lookup. The generic value has no Error constraint.
public enum JPEGLSManagedOutcome<Value> {
    /// The operation completed and returned its result.
    case success(Value)
    /// The operation failed; any partially written destination must be discarded.
    case failure(JPEGLSManagedFailure)

    /// Compatibility conversion, called only outside the qualified operation.
    internal func legacyValue() throws -> Value {
        switch self {
        case .success(let value): return value
        case .failure(let failure): throw failure.legacyError
        }
    }
}


/// Scalar failures for the qualified synchronous codec. Formatting is deliberately
/// confined to compatibility wrappers; this value owns no String or error object.
public struct JPEGLSManagedFailure: Error, Sendable, Equatable {
    /// Stable scalar category; operands contain the associated numeric context.
    public enum Code: UInt8, Sendable {
        /// Input ended before a required field or entropy value.
        case prematureEndOfStream
        /// Frame precision is unsupported; operand0 is the supplied precision.
        case invalidBitsPerSample
        /// Frame dimensions are invalid; operands are width and height.
        case invalidDimensions
        /// Component count is invalid; operand0 is the supplied count.
        case invalidComponentCount
        /// NEAR is invalid; operand0 is the supplied value.
        case invalidNearParameter
        /// A marker pair is invalid; operands are its two bytes.
        case invalidMarker
        /// A marker prefix was missing; operand0 is the observed byte.
        case expectedPrefix
        /// Unknown marker length is invalid; operands are marker and length.
        case unknownMarkerLength
        /// The next marker differs; operands are expected and actual marker values.
        case expectedMarker
        /// Marker segment length is invalid; operand0 is the supplied length.
        case markerLength
        /// SOF length differs; operands are expected and actual lengths.
        case sofLength
        /// SOS length differs; operands are expected and actual lengths.
        case sosLength
        /// Scan interleave mode is invalid; operand0 is the encoded mode.
        case interleaveMode
        /// An LSE segment is shorter than its header; operand0 is its length.
        case lseLength
        /// Preset segment length is invalid; operand0 is its length.
        case presetLength
        /// Mapping segment length is invalid; operand0 is its length.
        case mappingLength
        /// Mapping entry width is invalid; operand0 is its width.
        case mappingWidth
        /// Mapping payload is incomplete; operands are byte count and entry width.
        case mappingRemainder
        /// Mapping continuation length is invalid; operand0 is its length.
        case continuationLength
        /// Continuation payload is incomplete; operands are byte count and width.
        case continuationRemainder
        /// Extended-dimension segment length is invalid; operand0 is its length.
        case extendedLength
        /// Restart interval segment length is invalid; operand0 is its length.
        case driLength
        /// Frame component count differs; operands are expected and actual counts.
        case frameComponentMismatch
        /// Scan component count differs; operands are expected and actual counts.
        case scanComponentMismatch
        /// Interleave and component count conflict; operands are mode and count.
        case scanInterleave
        /// Point transform is invalid; operand0 is its value.
        case pointTransform
        /// Scan selector is absent from the frame; operand0 is its identifier.
        case unknownScanComponent
        /// A non-interleaved scan declares multiple components.
        case noninterleavedCount
        /// An interleaved scan has an incompatible component count.
        case interleavedCount
        /// MAXVAL is invalid; operand0 is its value.
        case maxValue
        /// The first preset threshold is invalid; operand0 is its value.
        case threshold1
        /// The second preset threshold is invalid; operand0 is its value.
        case threshold2
        /// The third preset threshold is invalid; operand0 is its value.
        case threshold3
        /// The context reset parameter is invalid; operand0 is its value.
        case reset
        /// A bit request is invalid; operand0 is the requested count.
        case bitCount
        /// A cursor position is invalid; operand0 is the requested position.
        case seekPosition
        /// Bytes remain after the end-of-image marker.
        case trailingBytes
        /// No frame header was found.
        case missingFrame
        /// No scan header was found.
        case missingScan
        /// Multiple frame headers are outside the accepted structure.
        case multipleFrames
        /// A scan precedes its frame header.
        case scanBeforeFrame
        /// The caller-storage profile requires exactly one scan.
        case monochromeScanCount
        /// An unexpected start-of-image marker occurs inside the frame.
        case unexpectedSOI
        /// The end-of-image marker is missing.
        case missingEOI
        /// The caller-storage profile requires one component.
        case monochromeComponentCount
        /// The destination byte count cannot be represented.
        case destinationOverflow
        /// Caller spans overlap or have invalid sample alignment.
        case overlappingBuffers
        /// The destination has insufficient sample capacity.
        case destinationTooSmall
        /// The monochrome scan is absent.
        case missingMonochromeScan
        /// More restart regions were encountered than expected.
        case tooManyRegions
        /// A restart marker does not match the expected cycle.
        case restartMarker
        /// One or more required restart regions are missing.
        case missingRegions
        /// The reconstructed region or row count is incomplete.
        case incompleteReconstruction
        /// A mapped sample exceeds the frame precision.
        case mappedPrecision
        /// The frame or scan lies outside the monochrome profile.
        case monochromeProfile
        /// A monochrome sampling factor is zero.
        case samplingFactors
        /// Dimensions or decoded bytes exceed the configured decoder limits.
        case decodedLimit
        /// MAXVAL exceeds the precision declared by the frame.
        case maxValuePrecision
        /// Encoded input or scratch capacity/alignment is invalid.
        case invalidCallerSpans
        /// The restart count or marker cycle is invalid.
        case restartCycle
        /// Mapping table identifier zero is invalid.
        case mappingID
        /// A mapping continuation has an incomplete entry.
        case mappingContinuation
        /// The supplied cancellation callback requested termination.
        case cancelled
    }
    /// The scalar category of the failure.
    public let code: Code
    /// First numeric context value, or zero when unused by this category.
    public let operand0: Int
    /// Second numeric context value, or zero when unused by this category.
    public let operand1: Int
    internal init(_ code: Code, _ operand0: Int = 0, _ operand1: Int = 0) {
        self.code = code; self.operand0 = operand0; self.operand1 = operand1
    }
    internal var legacyError: any Error {
        let a = operand0, b = operand1
        switch code {
        case .prematureEndOfStream: return JPEGLSError.prematureEndOfStream
        case .invalidBitsPerSample: return JPEGLSError.invalidBitsPerSample(bits: a)
        case .invalidDimensions: return JPEGLSError.invalidDimensions(width: a, height: b)
        case .invalidComponentCount: return JPEGLSError.invalidComponentCount(count: a)
        case .invalidNearParameter: return JPEGLSError.invalidNearParameter(near: a)
        case .invalidMarker: return JPEGLSError.invalidMarker(byte1: UInt8(a), byte2: UInt8(b))
        case .expectedPrefix: return JPEGLSError.invalidBitstreamStructure(reason: "Expected marker prefix (0xFF), got 0x\(String(a, radix: 16))")
        case .unknownMarkerLength: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid marker segment length for unknown marker 0xFF\(String(a, radix: 16)): \(b)")
        case .expectedMarker: return JPEGLSError.invalidBitstreamStructure(reason: "Expected \(JPEGLSMarker(rawValue: UInt8(a))!), got \(JPEGLSMarker(rawValue: UInt8(b))!)")
        case .markerLength: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid marker segment length: \(a)")
        case .sofLength: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid SOF length: expected \(a), got \(b)")
        case .sosLength: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid SOS length: expected \(a), got \(b)")
        case .interleaveMode: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid interleave mode: \(a)")
        case .lseLength: return JPEGLSError.invalidBitstreamStructure(reason: "LSE segment length \(a) is shorter than its own header")
        case .presetLength: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid LSE preset parameters length: \(a)")
        case .mappingLength: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid LSE mapping table length: \(a)")
        case .mappingWidth: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid mapping table entry width: \(a) (must be 1 or 2)")
        case .mappingRemainder: return JPEGLSError.invalidBitstreamStructure(reason: "Mapping table data length \(a) not a multiple of entry width \(b)")
        case .continuationLength: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid LSE mapping table continuation length: \(a)")
        case .continuationRemainder: return JPEGLSError.invalidBitstreamStructure(reason: "Mapping table continuation data length \(a) not a multiple of entry width \(b)")
        case .extendedLength: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid LSE extended dimensions segment length: \(a)")
        case .driLength: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid DRI marker length: expected 4, got \(a)")
        case .frameComponentMismatch: return JPEGLSError.invalidFrameHeader(reason: "Component count mismatch: expected \(a), got \(b)")
        case .scanComponentMismatch: return JPEGLSError.invalidScanHeader(reason: "Component count mismatch: expected \(a), got \(b)")
        case .scanInterleave: return JPEGLSError.invalidScanHeader(reason: "Interleave mode \(JPEGLSInterleaveMode(rawValue: UInt8(a))!) invalid for \(b) components")
        case .pointTransform: return JPEGLSError.invalidScanHeader(reason: "Point transform must be in range [0, 15], got \(a)")
        case .unknownScanComponent: return JPEGLSError.parameterMismatch(reason: "Scan component ID \(a) not found in frame")
        case .noninterleavedCount: return JPEGLSError.parameterMismatch(reason: "Non-interleaved scan must have exactly 1 component, got \(a)")
        case .interleavedCount: return JPEGLSError.parameterMismatch(reason: "Interleaved scan should include all \(a) components, got \(b)")
        case .maxValue: return JPEGLSError.invalidPresetParameters(reason: "MAXVAL must be in range [1, 65535], got \(a)")
        case .threshold1: return JPEGLSError.invalidPresetParameters(reason: "T1 must be in range [1, MAXVAL], got \(a)")
        case .threshold2: return JPEGLSError.invalidPresetParameters(reason: "T2 must be in range [T1, MAXVAL], got \(a)")
        case .threshold3: return JPEGLSError.invalidPresetParameters(reason: "T3 must be in range [T2, MAXVAL], got \(a)")
        case .reset: return JPEGLSError.invalidPresetParameters(reason: "RESET must be in range [3, 255], got \(a)")
        case .bitCount: return JPEGLSError.internalError(reason: "Invalid bit count: \(a)")
        case .seekPosition: return JPEGLSError.internalError(reason: "Invalid seek position: \(a)")
        case .trailingBytes: return JPEGLSError.invalidBitstreamStructure(reason: "Trailing bytes after JPEG-LS EOI")
        case .missingFrame: return JPEGLSError.invalidBitstreamStructure(reason: "No frame header found before EOI")
        case .missingScan: return JPEGLSError.invalidBitstreamStructure(reason: "No scan headers found before EOI")
        case .multipleFrames: return JPEGLSError.invalidBitstreamStructure(reason: "Multiple SOF markers found")
        case .scanBeforeFrame: return JPEGLSError.invalidBitstreamStructure(reason: "SOS marker found before SOF")
        case .monochromeScanCount: return JPEGLSError.invalidBitstreamStructure(reason: "Monochrome decoding requires one scan")
        case .unexpectedSOI: return JPEGLSError.invalidBitstreamStructure(reason: "Unexpected SOI marker")
        case .missingEOI: return JPEGLSError.invalidBitstreamStructure(reason: "Missing EOI marker")
        case .monochromeComponentCount: return JPEGLSError.invalidBitstreamStructure(reason: "Monochrome decoding requires one component")
        case .destinationOverflow: return JPEGLSError.invalidBitstreamStructure(reason: "JPEG-LS destination size overflows")
        case .overlappingBuffers: return JPEGLSError.invalidBitstreamStructure(reason: "JPEG-LS caller buffers overlap or are unaligned")
        case .destinationTooSmall: return JPEGLSError.invalidBitstreamStructure(reason: "JPEG-LS destination is too small")
        case .missingMonochromeScan: return JPEGLSError.invalidBitstreamStructure(reason: "Missing monochrome scan")
        case .tooManyRegions: return JPEGLSError.invalidBitstreamStructure(reason: "Too many JPEG-LS restart regions")
        case .restartMarker: return JPEGLSError.invalidBitstreamStructure(reason: "Unexpected JPEG-LS restart marker")
        case .missingRegions: return JPEGLSError.invalidBitstreamStructure(reason: "Missing JPEG-LS restart regions")
        case .incompleteReconstruction: return JPEGLSError.invalidBitstreamStructure(reason: "Incomplete JPEG-LS reconstruction")
        case .mappedPrecision: return JPEGLSError.invalidBitstreamStructure(reason: "Mapped sample exceeds frame precision")
        case .monochromeProfile: return JPEGLSError.invalidBitstreamStructure(reason: "Monochrome decoding requires one non-interleaved scan")
        case .samplingFactors: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid monochrome sampling factors")
        case .decodedLimit: return JPEGLSError.invalidBitstreamStructure(reason: "JPEG-LS exceeds decoded pixel/byte limit")
        case .maxValuePrecision: return JPEGLSError.invalidBitstreamStructure(reason: "MAXVAL exceeds frame precision")
        case .invalidCallerSpans: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid JPEG-LS input or workspace capacity/alignment")
        case .restartCycle: return JPEGLSError.invalidBitstreamStructure(reason: "Invalid JPEG-LS restart count or cycle")
        case .mappingID: return JPEGLSError.invalidBitstreamStructure(reason: "Mapping table ID must be in range [1, 255], got 0")
        case .mappingContinuation: return JPEGLSError.invalidBitstreamStructure(reason: "Mapping table continuation has incomplete entry")
        case .cancelled: return CancellationError()
        }
    }
}

/// Synchronous borrowed cancellation hook. Neither function nor context escapes a
/// qualified call. The caller owns the context and any synchronisation needed when
/// another thread changes it. Allocations performed by the callback are caller work.
public struct JPEGLSCancellation {
    private let check: (@convention(c) (UnsafeMutableRawPointer?) -> Bool)?
    private let context: UnsafeMutableRawPointer?
    /// Borrow a cancellation callback and optional context for each synchronous call.
    /// A nil callback never requests cancellation. The callback must not escape
    /// or retain codec borrows; its work and context are owned by the caller.
    public init(check: (@convention(c) (UnsafeMutableRawPointer?) -> Bool)? = nil,
                context: UnsafeMutableRawPointer? = nil) {
        self.check = check; self.context = context
    }
    internal func checkpoint() -> JPEGLSManagedFailure? {
        check?(context) == true ? JPEGLSManagedFailure(.cancelled) : nil
    }
    internal static var task: Self { Self(check: { _ in Task.isCancelled }) }
}
