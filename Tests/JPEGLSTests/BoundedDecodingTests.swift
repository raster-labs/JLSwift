import Foundation
import Testing
@testable import JPEGLS

@Suite("Bounded complete JPEG-LS frames")
struct BoundedDecodingTests {
    func fixture() throws -> Data {
        try JPEGLSEncoder().encode(MultiComponentImageData.grayscale(
            pixels: [[1, 2], [3, 4]], bitsPerSample: 8))
    }
    @Test func rejectsTrailingFrames() throws {
        let data = try fixture()
        for bad in [Data(data.dropLast(2)), data + data, data + Data([1, 2])] {
            #expect(throws: JPEGLSError.self) { try JPEGLSDecoder().decode(bad) }
        }
        let padded = data.count % 2 == 1 ? data + Data([0]) : data
        #expect(try JPEGLSDecoder().decode(padded).components[0].pixels == [[1, 2], [3, 4]])
    }
    @Test func boundsIncludeAllSampleStorage() throws {
        let data = try fixture()
        for limits in [JPEGLSDecoder.Limits(maximumEncodedBytes: 2),
                       JPEGLSDecoder.Limits(maximumPixels: 3),
                       JPEGLSDecoder.Limits(maximumDecodedBytes: 31)] {
            #expect(throws: JPEGLSError.self) { try JPEGLSDecoder(limits: limits).decode(data) }
        }
    }
    @Test func effectiveLSEDimensionsAreBounded() throws {
        let data = try fixture()
        // ITU-T T.87 LSE type 4, Wxy=4, effective 100000 x 100000.
        let lse = Data([0xff, 0xf8, 0, 12, 4, 4, 0, 1, 0x86, 0xa0, 0, 1, 0x86, 0xa0])
        var huge = Data(data.prefix(2)) + lse + data.dropFirst(2)
        let sof = try #require(huge.range(of: Data([0xff, 0xf7]))).lowerBound
        for i in (sof + 5)...(sof + 8) { huge[i] = 0 }
        #expect(throws: JPEGLSError.self) { try JPEGLSDecoder().decode(huge) }
    }
}
