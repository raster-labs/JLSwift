/// Bitstream reader for JPEG-LS decoding
///
/// Provides bit-level and byte-level reading operations on a data buffer
/// with marker detection and error handling.

import Foundation

/// Bitstream reader for JPEG-LS
///
/// Reads bytes and bits from a buffer, handling marker stuffing and
/// detecting premature end of stream.
///
/// Bit-level reads run over a 64-bit window refilled several bytes at a
/// time (applying the ISO 14495-1 §9.1 stuff-bit rule per refilled byte),
/// so per-bit work is a shift and a counter update instead of a byte fetch.
/// Unary prefixes are decoded with `leadingZeroBitCount` over the window.
///
/// - Important: The eager refill advances the byte position ahead of bit
///   consumption. After any bit-level read, call `resetBitBuffer()` before
///   using the byte-level API (`readByte`, `peekByte`, `readBytes`,
///   `readUInt16`, `findNextMarker`, `currentPosition`, `bytesRemaining`) —
///   it realigns the position to the byte boundary after the last consumed
///   bit. Mixing the two modes without a reset reads ahead of the logical
///   position.
internal struct JPEGLSBitstreamCursor {
    let cancellation: JPEGLSCancellation
    private let bytes: JPEGLSReadBytes
    /// Index of the next byte to load (bit reads) or read directly (byte reads).
    /// Bit-level refill advances this eagerly; the unconsumed bits live in
    /// `bitBuffer`/`bitsInBuffer`.
    private var position: Int
    private var nextCancellationCheckpoint = 65_536
    /// Bit accumulator. The low `bitsInBuffer` bits below previously-consumed
    /// garbage are valid; consumption only decrements `bitsInBuffer` (matching
    /// the historical extract-by-shift-and-mask behaviour).
    private var bitBuffer: UInt64
    private var bitsInBuffer: Int
    /// Byte index where the current buffered bit region began, and the number
    /// of bits consumed from it. `resetBitBuffer` replays the stuffing rules
    /// over the region to land `position` on the byte boundary following the
    /// last consumed bit (the eager refill advances `position` further ahead).
    private var bitRegionStart: Int
    private var bitsConsumedInRegion: Int

    /// Initialize reader with data buffer
    ///
    /// - Parameter data: Input data to read from
    init(data: Data) {
        cancellation = .init()
        self.bytes = JPEGLSReadBytes(data: data)
        self.position = 0
        self.bitBuffer = 0
        self.bitsInBuffer = 0
        self.bitRegionStart = 0
        self.bitsConsumedInRegion = 0
    }

    /// Internal synchronous borrow. The caller keeps the input immutable and alive.
    init(borrowing bytes: UnsafeRawBufferPointer, cancellation: JPEGLSCancellation = .init()) {
        self.cancellation = cancellation
        self.bytes = JPEGLSReadBytes(borrowing: bytes)
        position = 0; bitBuffer = 0; bitsInBuffer = 0
        bitRegionStart = 0; bitsConsumedInRegion = 0
    }

    /// Advance over an encoded range without copying its contents.
    internal mutating func readRange(_ count: Int) -> JPEGLSManagedOutcome<Range<Int>> {
        if let failure = cancellation.checkpoint() { return .failure(failure) }
        guard count >= 0, count <= bytes.count - position else {
            return .failure(JPEGLSManagedFailure(.prematureEndOfStream))
        }
        let start = position
        position += count
        return .success(start..<position)
    }

    internal func byte(at position: Int) -> UInt8 { bytes[position] }
    internal func copy(_ range: Range<Int>) -> Data { bytes.copy(range) }

    /// Current read position in bytes
    public var currentPosition: Int {
        return position
    }

    /// Number of bytes remaining in buffer
    public var bytesRemaining: Int {
        return bytes.count - position
    }

    /// Returns true if end of data reached
    public var isAtEnd: Bool {
        return position >= bytes.count && bitsInBuffer == 0
    }

    /// Read a single byte from the stream
    ///
    /// - Returns: The byte value
    /// - Failure: `JPEGLSManagedFailure(.prematureEndOfStream)` if no data available
    public mutating func readByte() -> JPEGLSManagedOutcome<UInt8> {
        if bytes.isBorrowed, position >= nextCancellationCheckpoint {
            if let failure = cancellation.checkpoint() { return .failure(failure) }
            nextCancellationCheckpoint = position > Int.max - 65_536 ? Int.max : position + 65_536
        }
        guard position < bytes.count else {
            return .failure(JPEGLSManagedFailure(.prematureEndOfStream))
        }
        let byte = bytes[position]
        position += 1
        return .success(byte)
    }

    /// Read multiple bytes from the stream
    ///
    /// - Parameter count: Number of bytes to read
    /// - Returns: Data containing the bytes
    /// - Failure: `JPEGLSManagedFailure(.prematureEndOfStream)` if not enough data
    public mutating func readBytes(_ count: Int) -> JPEGLSManagedOutcome<Data> {
        let range: Range<Int>
        switch readRange(count) {
        case .success(let value): range = value
        case .failure(let failure): return .failure(failure)
        }
        return .success(bytes.copy(range))
    }

    /// Read a 16-bit big-endian value
    ///
    /// - Returns: The 16-bit value
    /// - Failure: `JPEGLSManagedFailure(.prematureEndOfStream)` if not enough data
    public mutating func readUInt16() -> JPEGLSManagedOutcome<UInt16> {
        let byte1: UInt8
        switch readByte() {
        case .success(let value): byte1 = value
        case .failure(let failure): return .failure(failure)
        }
        let byte2: UInt8
        switch readByte() {
        case .success(let value): byte2 = value
        case .failure(let failure): return .failure(failure)
        }
        return .success((UInt16(byte1) << 8) | UInt16(byte2))
    }

    /// Peek at the next byte without advancing position
    ///
    /// - Returns: The next byte, or nil if at end
    public func peekByte() -> UInt8? {
        guard position < bytes.count else {
            return nil
        }
        return bytes[position]
    }

    /// Read a marker (0xFF, optionally more 0xFF fill bytes, then the code)
    ///
    /// ITU-T T.81 B.1.1.2 allows any number of 0xFF fill bytes before a marker
    /// code; they are skipped here.
    ///
    /// - Returns: The marker
    /// - Failure: `JPEGLSError` if marker is invalid or not found
    public mutating func readMarker() -> JPEGLSManagedOutcome<JPEGLSMarker> {
        let byte1: UInt8
        switch readByte() {
        case .success(let value): byte1 = value
        case .failure(let failure): return .failure(failure)
        }
        guard byte1 == JPEGLSMarker.markerPrefix else {
            return .failure(JPEGLSManagedFailure(.invalidMarker, Int(byte1), 0))
        }

        var byte2: UInt8
        switch readByte() {
        case .success(let value): byte2 = value
        case .failure(let failure): return .failure(failure)
        }
        while byte2 == JPEGLSMarker.markerPrefix {
            switch readByte() {
            case .success(let value): byte2 = value
            case .failure(let failure): return .failure(failure)
            }
        }
        guard let marker = JPEGLSMarker(rawValue: byte2) else {
            return .failure(JPEGLSManagedFailure(.invalidMarker, Int(byte1), Int(byte2)))
        }

        return .success(marker)
    }

    /// Skip to the next marker in the stream
    ///
    /// Uses the standard JPEG-LS stuffing rule (ISO 14495-1 §9.1): a byte following 0xFF
    /// with MSB = 1 (value ≥ 0x80) is a marker; with MSB = 0 (value < 0x80) it is a
    /// stuffed byte and the pair is skipped.
    ///
    /// - Returns: The marker found
    /// - Failure: `JPEGLSError` if no marker found before end of stream
    public mutating func findNextMarker() -> JPEGLSManagedOutcome<JPEGLSMarker> {
        while !isAtEnd {
            let byte: UInt8
            switch readByte() {
            case .success(let value): byte = value
            case .failure(let failure): return .failure(failure)
            }
            if byte == JPEGLSMarker.markerPrefix {
                if let nextByte = peekByte(), nextByte >= 0x80 {
                    // MSB = 1: real marker
                    position -= 1  // Back up to re-read the 0xFF
                    return readMarker()
                }
                // MSB = 0: stuffed byte, skip and continue
            }
        }
        return .failure(JPEGLSManagedFailure(.prematureEndOfStream))
    }

    // MARK: - Bit-level reading

    /// Top up the 64-bit window while at least 16 bits of headroom remain,
    /// applying the §9.1 stuffing rule per refilled byte:
    /// - 0xFF followed by a byte < 0x80: stuffed pair contributes 8 + 7 bits
    ///   (the follower's MSB is the discarded stuff bit).
    /// - 0xFF followed by a byte ≥ 0x80 (marker) or at end of data:
    ///   the 0xFF alone contributes 8 bits.
    @inline(__always)
    private mutating func refill() {
        if bitsInBuffer == 0 && bitsConsumedInRegion == 0 {
            bitRegionStart = position
        }
        let count = bytes.count
        while bitsInBuffer <= 48 && position < count {
            let byte = bytes[position]
            if byte == 0xFF && position + 1 < count {
                let next = bytes[position + 1]
                if next < 0x80 {
                    // Stuffed pair: 0xFF (8 bits) + stuff bit dropped + 7 data bits.
                    position += 2
                    bitBuffer = (bitBuffer << 15) | (0xFF << 7) | UInt64(next & 0x7F)
                    bitsInBuffer += 15
                    continue
                }
                // next >= 0x80: marker follows. The FF is added below; decoding
                // should finish before any marker bytes are consumed.
            }
            position += 1
            bitBuffer = (bitBuffer << 8) | UInt64(byte)
            bitsInBuffer += 8
        }
    }

    /// The valid bits left-aligned at the top of a 64-bit word.
    /// Only call with `bitsInBuffer > 0`.
    @inline(__always)
    private func alignedWindow() -> UInt64 {
        let mask: UInt64 = (1 << UInt64(bitsInBuffer)) &- 1
        return (bitBuffer & mask) << UInt64(64 - bitsInBuffer)
    }

    /// Read bits from the bitstream
    ///
    /// Implements JPEG-LS bit-level byte stuffing per ISO 14495-1 §9.1:
    /// When a byte of 0xFF is read, the following byte is examined:
    /// - If its MSB (bit 7) is 0: it is a stuffed byte. Bit 7 is the stuff bit (discarded);
    ///   bits 6–0 are real data bits. Total contribution: 8 bits (0xFF) + 7 data bits = 15 bits.
    /// - If its MSB (bit 7) is 1: it is the start of a marker. The 0xFF byte alone is added
    ///   to the buffer; the following byte is not consumed. Decoding should terminate before
    ///   consuming any marker bytes.
    ///
    /// All JPEG-LS markers have their second byte with MSB = 1 (values 0x80–0xFF).
    /// All stuffed bytes have their second byte with MSB = 0 (values 0x00–0x7F).
    ///
    /// - Parameter count: Number of bits to read (1-32)
    /// - Returns: The bits as a UInt32
    /// - Failure: `JPEGLSManagedFailure(.prematureEndOfStream)` if not enough data
    public mutating func readBits(_ count: Int) -> JPEGLSManagedOutcome<UInt32> {
        if bytes.isBorrowed, position >= nextCancellationCheckpoint {
            if let failure = cancellation.checkpoint() { return .failure(failure) }
            nextCancellationCheckpoint = position > Int.max - 65_536 ? Int.max : position + 65_536
        }
        guard count > 0 && count <= 32 else {
            return .failure(JPEGLSManagedFailure(.bitCount, count))
        }

        if bitsInBuffer < count {
            refill()
            guard bitsInBuffer >= count else {
                return .failure(JPEGLSManagedFailure(.prematureEndOfStream))
            }
        }

        // Extract bits from the most-significant valid position.
        let shift = bitsInBuffer - count
        let mask: UInt32 = count < 32 ? ((1 << count) - 1) : UInt32.max
        let bits = UInt32(truncatingIfNeeded: bitBuffer >> UInt64(shift)) & mask

        bitsInBuffer -= count
        bitsConsumedInRegion += count

        return .success(bits)
    }

    /// Read a unary prefix: zero or more '0' bits terminated by a single '1'
    /// bit, returning the number of zeros. Equivalent to calling
    /// `readBits(1)` in a loop until a 1 appears, but counts the zeros with
    /// `leadingZeroBitCount` over the buffered window instead of one call
    /// per bit.
    ///
    /// - Returns: The number of '0' bits before the terminating '1'
    /// - Failure: `JPEGLSManagedFailure(.prematureEndOfStream)` if the stream ends
    ///   before a '1' bit is found
    public mutating func readUnaryCount() -> JPEGLSManagedOutcome<Int> {
        var count = 0
        while true {
            if bytes.isBorrowed, position >= nextCancellationCheckpoint {
                if let failure = cancellation.checkpoint() { return .failure(failure) }
                nextCancellationCheckpoint = position > Int.max - 65_536 ? Int.max : position + 65_536
            }
            if bitsInBuffer == 0 {
                refill()
                guard bitsInBuffer > 0 else {
                    return .failure(JPEGLSManagedFailure(.prematureEndOfStream))
                }
            }
            let window = alignedWindow()
            let zeros = min(window.leadingZeroBitCount, bitsInBuffer)
            if zeros < bitsInBuffer {
                // Found the terminating '1': consume the zeros and the 1.
                bitsInBuffer -= zeros + 1
                bitsConsumedInRegion += zeros + 1
                return .success(count + zeros)
            }
            // Every buffered bit is 0 — consume them all and keep scanning.
            count += bitsInBuffer
            bitsConsumedInRegion += bitsInBuffer
            bitsInBuffer = 0
        }
    }

    /// Reset the bit buffer (typically called at scan boundaries)
    ///
    /// Discards any unconsumed buffered bits and aligns the byte position to
    /// the boundary following the last consumed bit, replaying the §9.1
    /// stuffing rule over the buffered region (a stuffed 0xFF pair counts as
    /// two bytes carrying 15 bits).
    public mutating func resetBitBuffer() {
        if bitsConsumedInRegion > 0 {
            var pos = bitRegionStart
            var remaining = bitsConsumedInRegion
            let count = bytes.count
            while remaining > 0 && pos < count {
                let byte = bytes[pos]
                if byte == 0xFF && pos + 1 < count && bytes[pos + 1] < 0x80 {
                    pos += 2
                    remaining -= 15
                } else {
                    pos += 1
                    remaining -= 8
                }
            }
            position = pos
        }
        bitBuffer = 0
        bitsInBuffer = 0
        bitRegionStart = position
        bitsConsumedInRegion = 0
    }

    /// Seek to a specific position in the stream
    ///
    /// - Parameter position: Target position in bytes
    /// - Failure: `JPEGLSError` if position is invalid
    public mutating func seek(to position: Int) -> JPEGLSManagedFailure? {
        guard position >= 0 && position <= bytes.count else {
            return JPEGLSManagedFailure(.seekPosition, position)
        }
        bitBuffer = 0
        bitsInBuffer = 0
        bitsConsumedInRegion = 0
        self.position = position
        bitRegionStart = position
        return nil
    }
}

/// Reference-semantics compatibility adapter over the canonical value cursor.
public final class JPEGLSBitstreamReader {
    internal var cursor: JPEGLSBitstreamCursor
    public init(data: Data) { cursor = JPEGLSBitstreamCursor(data: data) }
    internal init(borrowing bytes: UnsafeRawBufferPointer) {
        cursor = JPEGLSBitstreamCursor(borrowing: bytes, cancellation: .task)
    }
    public var currentPosition: Int { cursor.currentPosition }
    public var bytesRemaining: Int { cursor.bytesRemaining }
    public var isAtEnd: Bool { cursor.isAtEnd }
    public func peekByte() -> UInt8? { cursor.peekByte() }
    public func resetBitBuffer() { cursor.resetBitBuffer() }
    internal func byte(at position: Int) -> UInt8 { cursor.byte(at: position) }
    internal func copy(_ range: Range<Int>) -> Data { cursor.copy(range) }
    internal func readRange(_ count: Int) throws -> Range<Int> {
        return try cursor.readRange(count).legacyValue()
    }
    public func readByte() throws -> UInt8 {
        return try cursor.readByte().legacyValue()
    }
    public func readBytes(_ count: Int) throws -> Data {
        return try cursor.readBytes(count).legacyValue()
    }
    public func readUInt16() throws -> UInt16 {
        return try cursor.readUInt16().legacyValue()
    }
    public func readMarker() throws -> JPEGLSMarker {
        return try cursor.readMarker().legacyValue()
    }
    public func findNextMarker() throws -> JPEGLSMarker {
        return try cursor.findNextMarker().legacyValue()
    }
    public func readBits(_ count: Int) throws -> UInt32 {
        return try cursor.readBits(count).legacyValue()
    }
    public func readUnaryCount() throws -> Int {
        return try cursor.readUnaryCount().legacyValue()
    }
    public func seek(to position: Int) throws {
        if let failure = cursor.seek(to: position) { throw failure.legacyError }
    }
}
