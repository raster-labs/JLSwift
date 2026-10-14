import Foundation
import Testing
@testable import JPEGLS

@Suite("Bounded JPEG-LS malformed marker rejection")
struct BoundedParserRejectionTests {
    private let soi = Data([0xff, 0xd8])
    private let eoi = Data([0xff, 0xd9])
    // A complete 8-bit, 2-by-2 monochrome SOF55 segment.
    private let frame = Data([0xff, 0xf7, 0, 11, 8, 0, 2, 0, 2, 1, 1, 0x11, 0])

    private func expectStructureFailure(_ data: Data, reason: String) {
        do {
            _ = try JPEGLSParser(data: data).parse()
            Issue.record("Expected malformed marker rejection")
        } catch JPEGLSError.invalidBitstreamStructure(let actual) {
            #expect(actual == reason)
        } catch {
            Issue.record("Expected structural rejection, received \(error)")
        }
    }

    @Test func endOfImageRequiresBothFrameAndScanHeaders() {
        expectStructureFailure(soi + eoi, reason: "No frame header found before EOI")
        expectStructureFailure(soi + frame + eoi, reason: "No scan headers found before EOI")
    }

    @Test func markerSequenceRejectsMissingPrefixAndNestedStart() {
        expectStructureFailure(soi + Data([0x12]),
            reason: "Expected marker prefix (0xFF), got 0x12")
        expectStructureFailure(soi + soi, reason: "Unexpected SOI marker")
    }

    @Test func markerLengthsCannotBeShorterThanTheirOwnLengthField() {
        for length in [UInt8(0), UInt8(1)] {
            // Unrecognized length-prefixed markers must obey the same bounds as APP/COM.
            expectStructureFailure(soi + Data([0xff, 0xc0, 0, length]),
                reason: "Invalid marker segment length for unknown marker 0xFFc0: \(length)")
            for marker in [UInt8(0xe0), UInt8(0xfe)] {
                expectStructureFailure(soi + Data([0xff, marker, 0, length]),
                    reason: "Invalid marker segment length: \(length)")
            }
        }
    }

    @Test func extensionHeadersRejectMissingRequiredFields() {
        expectStructureFailure(soi + Data([0xff, 0xf8, 0, 2]),
            reason: "LSE segment length 2 is shorter than its own header")
        expectStructureFailure(soi + Data([0xff, 0xf8, 0, 3, 1]),
            reason: "Invalid LSE preset parameters length: 3")
        expectStructureFailure(soi + Data([0xff, 0xf8, 0, 3, 4]),
            reason: "Invalid LSE extended dimensions segment length: 3")
    }

    @Test func mappingTableRequiresItsHeaderAndWholeSupportedEntries() {
        expectStructureFailure(soi + Data([0xff, 0xf8, 0, 4, 2, 1]),
            reason: "Invalid LSE mapping table length: 4")
        for width in [UInt8(0), UInt8(3)] {
            expectStructureFailure(soi + Data([0xff, 0xf8, 0, 5, 2, 1, width]),
                reason: "Invalid mapping table entry width: \(width) (must be 1 or 2)")
        }
        expectStructureFailure(soi + Data([0xff, 0xf8, 0, 6, 2, 1, 2, 0]),
            reason: "Mapping table data length 1 not a multiple of entry width 2")
    }

    @Test func mappingContinuationRequiresItsHeaderAndMatchingEntryWidth() {
        expectStructureFailure(soi + Data([0xff, 0xf8, 0, 3, 3]),
            reason: "Invalid LSE mapping table continuation length: 3")
        // TID 1 has one two-byte entry. An odd continuation cannot extend it.
        let table = Data([0xff, 0xf8, 0, 7, 2, 1, 2, 0x12, 0x34])
        let continuation = Data([0xff, 0xf8, 0, 5, 3, 1, 0x56])
        expectStructureFailure(soi + table + continuation,
            reason: "Mapping table continuation data length 1 not a multiple of entry width 2")
    }

    @Test func unknownExtensionCannotSkipPastAvailableBytes() {
        // Unknown Id=255 declares three payload bytes but supplies only one.
        // It must fail the bounded read even though its meaning is unsupported.
        let truncated = soi + Data([0xff, 0xf8, 0, 6, 0xff, 0x42])
        do {
            _ = try JPEGLSParser(data: truncated).parse()
            Issue.record("Expected truncated extension rejection")
        } catch JPEGLSError.prematureEndOfStream {
            // The declared payload must fit entirely in the source.
        } catch {
            Issue.record("Expected premature end of stream, received \(error)")
        }
    }

    @Test func completeTwoByteMappingContinuationPreservesEntryBoundaries() throws {
        let pixels = [[1, 2], [3, 4]]
        let encoded = try JPEGLSEncoder().encode(MultiComponentImageData.grayscale(
            pixels: pixels, bitsPerSample: 8))
        let table = Data([0xff, 0xf8, 0, 9, 2, 1, 2, 0x12, 0x34, 0xab, 0xcd])
        let continuation = Data([0xff, 0xf8, 0, 8, 3, 1, 0, 1, 0xff, 0xff])
        let data = soi + table + continuation + encoded.dropFirst(2)
        let parsed = try JPEGLSParser(data: data).parse()
        let mapping = try #require(parsed.mappingTables[1])
        #expect(mapping.entryWidth == 2)
        #expect(mapping.entries == [0x1234, 0xabcd, 1, 0xffff])
        #expect(parsed.scanHeaders.count == 1)
        // The scan selects table 0, so unused table metadata must not change pixels.
        #expect(try JPEGLSDecoder().decode(data).components[0].pixels == pixels)
    }
}
