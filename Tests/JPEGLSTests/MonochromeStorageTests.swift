import Foundation
import Testing
@testable import JPEGLS

@Suite("Caller-owned JPEG-LS storage")
struct MonochromeStorageTests {
    private func withWorkspace<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: JPEGLSDecoder.monochromeWorkspaceByteCount, alignment: 16)
        defer { pointer.deallocate() }
        return try body(UnsafeMutableRawBufferPointer(start: pointer, count: JPEGLSDecoder.monochromeWorkspaceByteCount))
    }

    private func bounded(_ encoded: Data, decoder: JPEGLSDecoder = JPEGLSDecoder()) throws -> [Int] {
        try withWorkspace { workspace in
            try encoded.withUnsafeBytes { bytes in
                let info = try decoder.inspectMonochrome(bytes, workspace: workspace)
                let legacy = try JPEGLSParser(data: encoded).parse()
                #expect(info.mappingTableID == legacy.scanHeaders.first?.components.first?.mappingTableID)
                #expect(info.hasMappingTables == !legacy.mappingTables.isEmpty)
                #expect(info.colorTransformation == legacy.colorTransformation)
                var samples = [UInt16](repeating: 0xABCD, count: info.sampleCount + 2)
                try samples.withUnsafeMutableBufferPointer { buffer in
                    let result = try decoder.decodeMonochrome(bytes,
                        into: UnsafeMutableBufferPointer(rebasing: buffer[1..<(buffer.count - 1)]), workspace: workspace)
                    #expect(result == info)
                }
                #expect(samples.first == 0xABCD && samples.last == 0xABCD)
                return samples.dropFirst().dropLast().map(Int.init)
            }
        }
    }

    private func encoded(bits: Int = 12, near: Int = 0, interval: Int = 0,
                         mapping: JPEGLSMappingTable? = nil,
                         preset: JPEGLSPresetParameters? = nil) throws -> Data {
        let maximum = (1 << bits) - 1
        let pixels = (0..<19).map { row in (0..<17).map { col in
            row % 4 == 0 ? maximum : ((row * 137 + col * 67) & maximum)
        } }
        return try JPEGLSEncoder().encode(MultiComponentImageData.grayscale(pixels: pixels, bitsPerSample: bits),
            configuration: JPEGLSEncoder.Configuration(near: near, presetParameters: preset,
                mappingTable: mapping, restartInterval: interval))
    }

    @Test("Sample and restart parity", arguments: [8, 12, 16], [0, 1, 4, 25])
    func sampleParity(bits: Int, interval: Int) throws {
        for near in interval == 0 ? [0, 3] : [0] {
            let data = try encoded(bits: bits, near: near, interval: interval)
            let legacy = try JPEGLSDecoder().decode(data).components[0].pixels.flatMap { $0 }
            #expect(try bounded(data) == legacy)
        }
    }

    @Test("Mapping continuations and replacement after entropy preserve final-table semantics")
    func mappingParity() throws {
        let palette = try JPEGLSMappingTable(id: 5, entryWidth: 2, entries: (0..<65_536).map { 65_535 - $0 })
        let data = try encoded(bits: 16, mapping: palette)
        #expect(try bounded(data) == JPEGLSDecoder().decode(data).components[0].pixels.flatMap { $0 })
        for replacement in [Data([0xff, 0xf8, 0, 5, 2, 5, 2]),
                            Data([0xff, 0xf8, 0, 9, 2, 5, 2, 0, 19, 0, 23])] {
            let replaced = data.dropLast(2) + replacement + Data([0xff, 0xd9])
            #expect(try bounded(replaced) == JPEGLSDecoder().decode(replaced).components[0].pixels.flatMap { $0 })
        }
    }

    @Test("Final preset after scan and large ignored marker payloads preserve decoding")
    func finalPresetAndMetadata() throws {
        let preset = try JPEGLSPresetParameters(maxValue: 4095, threshold1: 7, threshold2: 19, threshold3: 45, reset: 48)
        var data = try encoded(preset: preset)
        let range = try #require(data.range(of: Data([0xff, 0xf8, 0, 13, 1])))
        let segment = Data(data[range.lowerBound..<(range.lowerBound + 15)])
        data.removeSubrange(range.lowerBound..<(range.lowerBound + 15))
        data.insert(contentsOf: segment, at: data.count - 2)
        let large = Data([0xff, 0xe1, 0xff, 0xff]) + Data(repeating: 73, count: 65_533)
        data.insert(contentsOf: large + large, at: 2)
        #expect(try bounded(data) == JPEGLSDecoder().decode(data).components[0].pixels.flatMap { $0 })
    }

    @Test("Invalid input or caller spans fail before publication")
    func invalidSpans() throws {
        let data = try encoded(interval: 1)
        withWorkspace { workspace in
            data.withUnsafeBytes { raw in
                var output = [UInt16](repeating: 0xABCD, count: 17 * 19)
                output.withUnsafeMutableBufferPointer { buffer in
                    #expect(throws: JPEGLSError.self) {
                        try JPEGLSDecoder().decodeMonochrome(raw,
                            into: UnsafeMutableBufferPointer(rebasing: buffer.dropLast()), workspace: workspace)
                    }
                    #expect(buffer.allSatisfy { $0 == 0xABCD })
                    let short = UnsafeMutableRawBufferPointer(rebasing: workspace.dropLast())
                    #expect(throws: JPEGLSError.self) { try JPEGLSDecoder().inspectMonochrome(raw, workspace: short) }
                    let overlapping = workspace.bindMemory(to: UInt16.self)
                    #expect(throws: JPEGLSError.self) {
                        try JPEGLSDecoder().decodeMonochrome(raw, into: overlapping, workspace: workspace)
                    }
                }
            }
        }
        var invalidSampling = data
        let sof = try #require(invalidSampling.range(of: Data([0xff, 0xf7])))
        invalidSampling[sof.lowerBound + 11] = 0
        #expect(throws: JPEGLSError.self) { try bounded(invalidSampling) }
        #expect(throws: JPEGLSError.self) { try JPEGLSDecoder().decode(invalidSampling) }
        var wrongCycle = data
        let restart = try #require(wrongCycle.range(of: Data([0xff, 0xd0])))
        wrongCycle[restart.lowerBound + 1] = 0xd3
        for malformed in [wrongCycle, data + data, Data(data.dropLast(2))] {
            #expect(throws: JPEGLSError.self) { try bounded(malformed) }
        }
        let exact = JPEGLSDecoder(limits: .init(maximumPixels: 17 * 19, maximumDecodedBytes: 17 * 19 * 2))
        #expect(try bounded(data, decoder: exact).count == 17 * 19)
        let short = JPEGLSDecoder(limits: .init(maximumPixels: 17 * 19, maximumDecodedBytes: 17 * 19 * 2 - 1))
        #expect(throws: JPEGLSError.self) { try bounded(data, decoder: short) }
    }

    @Test("Owned context copies retain value semantics")
    func contextCopies() throws {
        let original = try JPEGLSContextModel(parameters: .defaultParameters(bitsPerSample: 12))
        var copy = original
        copy.updateContext(contextIndex: 17, predictionError: 8, sign: 1)
        #expect(copy.getA(contextIndex: 17) != original.getA(contextIndex: 17))
    }

    @Test("Cancellation retains caller ownership and stops before sample writes")
    func cancellation() async throws {
        let data = try encoded()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try bounded(data)
        }
        do { _ = try await task.value; Issue.record("Cancelled decode returned samples") }
        catch is CancellationError {} 
    }
}
