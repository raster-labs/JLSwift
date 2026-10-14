import Foundation
import Testing
@testable import JPEGLS

@Suite("Bounded JPEG-LS scan topology")
struct BoundedScanTopologyTests {
    private let pixels = [[1, 2], [3, 4]]

    private func rgb(_ mode: JPEGLSInterleaveMode = .none) throws -> Data {
        try JPEGLSEncoder().encode(MultiComponentImageData.rgb(
            redPixels: pixels, greenPixels: pixels, bluePixels: pixels, bitsPerSample: 8),
            interleaveMode: mode)
    }

    private func headers(_ data: Data) throws -> [Data] {
        let parsed = try JPEGLSParser(data: data).parse()
        return zip(parsed.scanHeaders, parsed.scanDataRanges).map { scan, range in
            // SOS marker, length, component count, selectors, NEAR, ILV, Al.
            let headerLength = 8 + 2 * scan.componentCount
            return Data(data[(range.lowerBound - headerLength)..<range.lowerBound])
        }
    }

    private func emptyScans(_ data: Data, headers: [Data]) throws -> Data {
        let sos = try #require(data.range(of: Data([0xff, 0xda]))).lowerBound
        var result = Data(data.prefix(sos))
        for header in headers { result.append(header) }
        result.append(contentsOf: [0xff, 0xd9])
        return result
    }

    private func expectStructureFailure(_ data: Data, reason: String,
                                        limits: JPEGLSDecoder.Limits = .init()) {
        do {
            _ = try JPEGLSDecoder(limits: limits).decode(data)
            Issue.record("Expected structural rejection before entropy decoding")
        } catch JPEGLSError.invalidBitstreamStructure(let actual) {
            #expect(actual == reason)
        } catch {
            Issue.record("Expected structural rejection, received \(error)")
        }
    }

    @Test func duplicateMonochromeScansAreRejectedBeforeDecoding() throws {
        let data = try JPEGLSEncoder().encode(MultiComponentImageData.grayscale(
            pixels: pixels, bitsPerSample: 8))
        let scan = try #require(headers(data).first)
        // Both entropy bodies are empty. A decoder that attempts either plane
        // first reports premature EOF instead of this structural rejection.
        let malformed = try emptyScans(data, headers: [scan, scan])
        expectStructureFailure(malformed, reason: "Expected 1 scans, found 2",
            limits: .init(maximumDecodedBytes: 4 * MemoryLayout<Int>.stride))
    }

    @Test func duplicateComponentScansCannotReplaceMissingComponents() throws {
        let data = try rgb()
        let scans = try headers(data)
        let malformed = try emptyScans(data, headers: [scans[0], scans[0], scans[2]])
        expectStructureFailure(malformed, reason: "Duplicate scan component IDs")
    }

    @Test func extraInterleavedScanIsRejectedBeforeDecoding() throws {
        let data = try rgb(.sample)
        let scan = try #require(headers(data).first)
        let malformed = try emptyScans(data, headers: [scan, scan])
        expectStructureFailure(malformed, reason: "Expected 1 scans, found 2")
    }

    @Test func duplicateSelectorsInInterleavedScanAreRejected() throws {
        let data = try rgb(.sample)
        var scan = try #require(headers(data).first)
        scan[7] = scan[5] // The second component selector repeats the first.
        let malformed = try emptyScans(data, headers: [scan])
        expectStructureFailure(malformed, reason: "Duplicate scan component IDs")
    }

    @Test func mixedInterleaveModesAreRejectedBeforeDecoding() throws {
        let data = try rgb()
        let scans = try headers(data)
        let interleaved = try #require(headers(rgb(.sample)).first)
        let malformed = try emptyScans(data, headers: [scans[0], interleaved, scans[2]])
        expectStructureFailure(malformed, reason: "Mixed scan interleave modes")
    }

    @Test func duplicateFrameIDsAreRejectedBeforeDecoding() throws {
        let data = try rgb()
        var scans = try headers(data)
        scans[1][5] = scans[0][5]
        var malformed = try emptyScans(data, headers: scans)
        let sof = try #require(malformed.range(of: Data([0xff, 0xf7]))).lowerBound
        malformed[sof + 13] = malformed[sof + 10]
        expectStructureFailure(malformed, reason: "Duplicate frame component IDs")
    }

    @Test func exactRGBSampleBudgetIncludesAllComponents() throws {
        let requiredBytes = 4 * 3 * MemoryLayout<Int>.stride
        for mode in [JPEGLSInterleaveMode.none, .line, .sample] {
            let data = try rgb(mode)
            let limits = JPEGLSDecoder.Limits(maximumEncodedBytes: data.count,
                maximumPixels: 4, maximumDecodedBytes: requiredBytes)
            let decoded = try JPEGLSDecoder(limits: limits).decode(data)
            #expect(decoded.components.count == 3)
            for component in decoded.components { #expect(component.pixels == pixels) }
            expectStructureFailure(data, reason: "JPEG-LS exceeds decoded pixel/byte limit",
                limits: .init(maximumDecodedBytes: requiredBytes - 1))
        }
    }

    @Test func paddingRequiresAnOddCodestreamAndExactlyOneZero() throws {
        let original = try JPEGLSEncoder().encode(MultiComponentImageData.grayscale(
            pixels: pixels, bitsPerSample: 8))
        for parity in 0...1 {
            // A one-byte COM payload adds five bytes without changing samples.
            let data = original.count % 2 == parity ? original :
                Data(original.prefix(2)) + Data([0xff, 0xfe, 0, 3, 0]) + original.dropFirst(2)
            #expect(data.count % 2 == parity)
            #expect(try JPEGLSDecoder().decode(data).components[0].pixels == pixels)
            if parity == 1 {
                #expect(try JPEGLSDecoder().decode(data + Data([0])).components[0].pixels == pixels)
            } else {
                expectStructureFailure(data + Data([0]), reason: "Trailing bytes after JPEG-LS EOI")
            }
            for suffix in [Data([1]), Data([0, 0])] {
                expectStructureFailure(data + suffix, reason: "Trailing bytes after JPEG-LS EOI")
            }
        }
    }

    @Test func effectiveDimensionArithmeticRejectsEveryOverflowStage() throws {
        let data = try rgb()
        let dimensions: [(UInt32, UInt32)] = [
            (0xffff_ffff, 0xffff_ffff), // Width times height overflows Int.
            (0xffff_ffff, 0x4000_0000), // Pixels times three components overflows Int.
            (0xffff_ffff, 0x1000_0000), // Samples times Int stride overflows Int.
        ]
        for (width, height) in dimensions {
            var lse = Data([0xff, 0xf8, 0, 12, 4, 4])
            for dimension in [width, height] {
                for shift in [24, 16, 8, 0] {
                    lse.append(UInt8(truncatingIfNeeded: dimension >> shift))
                }
            }
            var huge = Data(data.prefix(2)) + lse + data.dropFirst(2)
            let sof = try #require(huge.range(of: Data([0xff, 0xf7]))).lowerBound
            for index in (sof + 5)...(sof + 8) { huge[index] = 0 }
            expectStructureFailure(huge, reason: "JPEG-LS exceeds decoded pixel/byte limit",
                limits: .init(maximumPixels: Int.max, maximumDecodedBytes: Int.max))
        }
    }
}
