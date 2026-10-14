import Foundation
import Testing
@testable import JPEGLS

private struct QualifiedCancellationCounter {
    var calls = 0
    var cancelAt = 8
}

private enum QualifiedTestFailure: Error {
    case unexpectedFailure
}

@Suite("Qualified monochrome caller storage")
struct QualifiedMonochromeTests {
    private let columns = 7
    private let rows = 9
    private let canary: UInt16 = 0xABCD

    private func withWorkspace<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        let count = JPEGLSDecoder.monochromeWorkspaceByteCount
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        defer { pointer.deallocate() }
        return try body(UnsafeMutableRawBufferPointer(start: pointer, count: count))
    }

    private func encoded(bits: Int = 12, near: Int = 0, interval: Int = 0,
                         mapping: JPEGLSMappingTable? = nil) throws -> Data {
        let maximum = (1 << bits) - 1
        let pixels = (0..<rows).map { row in
            (0..<columns).map { column in
                row % 3 == 0 ? (column < 3 ? 0 : maximum) : ((row * 137 + column * 67) & maximum)
            }
        }
        return try JPEGLSEncoder().encode(
            MultiComponentImageData.grayscale(pixels: pixels, bitsPerSample: bits),
            configuration: .init(near: near, mappingTable: mapping, restartInterval: interval))
    }

    private func legacy(_ data: Data) throws -> [Int] {
        try JPEGLSDecoder().decode(data).components[0].pixels.flatMap { $0 }
    }

    private func qualified(_ data: Data, workspace: UnsafeMutableRawBufferPointer) throws -> [Int] {
        try data.withUnsafeBytes { encoded in
            let decoder = JPEGLSDecoder()
            let info = try requireSuccess(decoder.inspectMonochromeQualified(encoded, workspace: workspace))
            #expect(info.width == columns && info.height == rows)
            var output = [UInt16](repeating: canary, count: info.sampleCount + 2)
            let decoded = try requireSuccess(output.withUnsafeMutableBufferPointer { buffer in
                decoder.decodeMonochromeQualified(encoded,
                    into: UnsafeMutableBufferPointer(rebasing: buffer[1..<(buffer.count - 1)]),
                    workspace: workspace)
            })
            #expect(decoded == info)
            #expect(output.first == canary && output.last == canary)
            return output.dropFirst().dropLast().map(Int.init)
        }
    }

    private func requireSuccess<Value>(_ outcome: JPEGLSManagedOutcome<Value>) throws -> Value {
        switch outcome {
        case .success(let value): return value
        case .failure(let failure):
            Issue.record("Unexpected qualified failure: \(failure.code)")
            throw QualifiedTestFailure.unexpectedFailure
        }
    }

    private func expectFailure<Value>(_ outcome: JPEGLSManagedOutcome<Value>,
                                      code: JPEGLSManagedFailure.Code) {
        switch outcome {
        case .success:
            Issue.record("Expected qualified failure: \(code)")
        case .failure(let failure):
            #expect(failure.code == code)
        }
    }

    @Test("Qualified entry points have nonthrowing function types")
    func nonthrowingEntryPoints() throws {
        let decoder = JPEGLSDecoder()
        let inspect: (UnsafeRawBufferPointer, UnsafeMutableRawBufferPointer, JPEGLSCancellation)
            -> JPEGLSManagedOutcome<JPEGLSDecoder.MonochromeInfo> = decoder.inspectMonochromeQualified
        let decode: (UnsafeRawBufferPointer, UnsafeMutableBufferPointer<UInt16>,
                     UnsafeMutableRawBufferPointer, JPEGLSCancellation)
            -> JPEGLSManagedOutcome<JPEGLSDecoder.MonochromeInfo> = decoder.decodeMonochromeQualified
        let data = try encoded()
        let expected = try legacy(data)
        try withWorkspace { workspace in
            try data.withUnsafeBytes { encoded in
                let info = try requireSuccess(inspect(encoded, workspace, .init()))
                var output = [UInt16](repeating: canary, count: info.sampleCount)
                let decoded = try requireSuccess(output.withUnsafeMutableBufferPointer { buffer in
                    decode(encoded, buffer, workspace, .init())
                })
                #expect(decoded == info)
                #expect(output.map(Int.init) == expected)
            }
        }
    }

    @Test("Qualified samples match legacy across precision, near-lossless and restart boundaries",
          arguments: [8, 12, 16])
    func sampleParity(bits: Int) throws {
        try withWorkspace { workspace in
            for interval in [0, 1, 4, rows, rows + 3] {
                for near in interval == 0 ? [0, 3] : [0] {
                    let data = try encoded(bits: bits, near: near, interval: interval)
                    let actual = try qualified(data, workspace: workspace)
                    let expected = try legacy(data)
                    #expect(actual == expected)
                }
            }
        }
    }

    @Test("Qualified mapping retains final replacement semantics")
    func mappingParity() throws {
        let palette = try JPEGLSMappingTable(id: 5, entryWidth: 1, entries: (0..<256).map { 255 - $0 })
        let data = try encoded(bits: 8, mapping: palette)
        try withWorkspace { workspace in
            let actual = try qualified(data, workspace: workspace)
            let expected = try legacy(data)
            #expect(actual == expected)
            for replacement in [Data([0xff, 0xf8, 0, 5, 2, 5, 1]),
                                Data([0xff, 0xf8, 0, 7, 2, 5, 1, 19, 23])] {
                let changed = Data(data.dropLast(2)) + replacement + Data([0xff, 0xd9])
                let changedActual = try qualified(changed, workspace: workspace)
                let changedExpected = try legacy(changed)
                #expect(changedActual == changedExpected)
            }
        }
    }

    @Test("Rejected output and workspace capacities leave every caller sample untouched")
    func rejectedCapacity() throws {
        let data = try encoded(interval: 1)
        withWorkspace { workspace in
            data.withUnsafeBytes { encoded in
                let decoder = JPEGLSDecoder()
                var output = [UInt16](repeating: canary, count: rows * columns + 2)
                output.withUnsafeMutableBufferPointer { buffer in
                    let shortOutput = UnsafeMutableBufferPointer(rebasing: buffer[1..<(buffer.count - 2)])
                    expectFailure(decoder.decodeMonochromeQualified(encoded,
                        into: shortOutput, workspace: workspace), code: .destinationTooSmall)
                    #expect(buffer.allSatisfy { $0 == canary })
                    let shortWorkspace = UnsafeMutableRawBufferPointer(rebasing: workspace.dropLast())
                    expectFailure(decoder.inspectMonochromeQualified(encoded,
                        workspace: shortWorkspace), code: .invalidCallerSpans)
                    let exactOutput = UnsafeMutableBufferPointer(rebasing: buffer[1..<(buffer.count - 1)])
                    expectFailure(decoder.decodeMonochromeQualified(encoded,
                        into: exactOutput, workspace: shortWorkspace), code: .invalidCallerSpans)
                    #expect(buffer.allSatisfy { $0 == canary })
                }
            }
        }
    }

    @Test("Immediate cancellation returns its failure code and preserves caller output")
    func immediateCancellation() throws {
        let data = try encoded()
        let check: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { _ in true }
        let cancellation = JPEGLSCancellation(check: check)
        withWorkspace { workspace in
            data.withUnsafeBytes { encoded in
                let decoder = JPEGLSDecoder()
                expectFailure(decoder.inspectMonochromeQualified(encoded,
                    workspace: workspace, cancellation: cancellation), code: .cancelled)
                var output = [UInt16](repeating: canary, count: rows * columns + 2)
                output.withUnsafeMutableBufferPointer { buffer in
                    expectFailure(decoder.decodeMonochromeQualified(encoded,
                        into: UnsafeMutableBufferPointer(rebasing: buffer[1..<(buffer.count - 1)]),
                        workspace: workspace, cancellation: cancellation), code: .cancelled)
                    #expect(buffer.allSatisfy { $0 == canary })
                }
            }
        }
    }

    @Test("Cancellation is polled during marker parsing through the supplied context")
    func cancellationDuringParsing() throws {
        var data = try encoded()
        // Many small ignored markers exercise repeated parser checkpoints cheaply.
        let marker: [UInt8] = [0xff, 0xe1, 0, 3, 73]
        data.insert(contentsOf: Array(repeating: marker, count: 32).flatMap { $0 }, at: 2)
        var counter = QualifiedCancellationCounter()
        let check: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { context in
            guard let context else { return false }
            let counter = context.assumingMemoryBound(to: QualifiedCancellationCounter.self)
            counter.pointee.calls += 1
            return counter.pointee.calls >= counter.pointee.cancelAt
        }
        withWorkspace { workspace in
            withUnsafeMutablePointer(to: &counter) { context in
                let cancellation = JPEGLSCancellation(check: check, context: UnsafeMutableRawPointer(context))
                data.withUnsafeBytes { encoded in
                    expectFailure(JPEGLSDecoder().inspectMonochromeQualified(encoded,
                        workspace: workspace, cancellation: cancellation), code: .cancelled)
                }
            }
        }
        #expect(counter.calls == counter.cancelAt)
    }

    @Test("Malformed streams return explicit qualified failure codes")
    func malformedFailure() throws {
        let data = try encoded()
        withWorkspace { workspace in
            let cases: [(Data, JPEGLSManagedFailure.Code)] = [
                (Data([0, 1, 2, 3]), .invalidMarker),
                (Data(data.dropLast(2)), .missingEOI),
                (data + data, .trailingBytes)
            ]
            for (malformed, code) in cases {
                malformed.withUnsafeBytes { encoded in
                    expectFailure(JPEGLSDecoder().inspectMonochromeQualified(encoded,
                        workspace: workspace), code: code)
                    var output = [UInt16](repeating: canary, count: rows * columns + 2)
                    output.withUnsafeMutableBufferPointer { buffer in
                        expectFailure(JPEGLSDecoder().decodeMonochromeQualified(encoded,
                            into: UnsafeMutableBufferPointer(rebasing: buffer[1..<(buffer.count - 1)]),
                            workspace: workspace), code: code)
                        #expect(buffer.allSatisfy { $0 == canary })
                    }
                }
            }
        }
    }

    @Test("Empty entropy passes inspection then fails before changing caller samples")
    func earlyEntropyFailurePreservesCanaries() throws {
        var data = try encoded()
        let parsed = try JPEGLSParser(data: data).parse()
        let entropy = try #require(parsed.scanDataRanges.first)
        #expect(!entropy.isEmpty)
        // Preserve all headers and EOI so only the numerical decoder rejects it.
        data.removeSubrange(entropy)
        try withWorkspace { workspace in
            try data.withUnsafeBytes { encoded in
                let decoder = JPEGLSDecoder()
                let info = try requireSuccess(decoder.inspectMonochromeQualified(encoded, workspace: workspace))
                #expect(info.sampleCount == rows * columns)
                var output = [UInt16](repeating: canary, count: info.sampleCount + 2)
                output.withUnsafeMutableBufferPointer { buffer in
                    expectFailure(decoder.decodeMonochromeQualified(encoded,
                        into: UnsafeMutableBufferPointer(rebasing: buffer[1..<(buffer.count - 1)]),
                        workspace: workspace), code: .prematureEndOfStream)
                    #expect(buffer.allSatisfy { $0 == canary })
                }
            }
        }
    }

    @Test("Omitted callback ignores Task cancellation")
    func noTaskDependency() async throws {
        let data = try encoded(interval: 4)
        let expected = try legacy(data)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try withWorkspace { try qualified(data, workspace: $0) }
        }
        #expect(try await task.value == expected)
    }

    @Test("Independent live workspaces do not share reconstruction state")
    func independentWorkspaces() throws {
        let first = try encoded(bits: 8, interval: 1)
        let second = try encoded(bits: 16, near: 3)
        let firstExpected = try legacy(first), secondExpected = try legacy(second)
        try withWorkspace { firstWorkspace in
            try withWorkspace { secondWorkspace in
                #expect(firstWorkspace.baseAddress != secondWorkspace.baseAddress)
                let firstActual = try qualified(first, workspace: firstWorkspace)
                let secondActual = try qualified(second, workspace: secondWorkspace)
                let firstAgain = try qualified(first, workspace: firstWorkspace)
                #expect(firstActual == firstExpected)
                #expect(secondActual == secondExpected)
                #expect(firstAgain == firstExpected)
            }
        }
    }

    @Test("Retry after a rejected concatenated frame returns only the next frame's storage")
    func legacyParserRetryClearsStorage() throws {
        var first = try encoded(bits: 8, interval: 1)
        first.insert(contentsOf: [UInt8](arrayLiteral:
            0xff, 0xe1, 0, 3, 65,
            0xff, 0xfe, 0, 3, 65,
            0xff, 0xf8, 0, 5, 2, 5, 1), at: 2)
        var second = try encoded(bits: 16)
        second.insert(contentsOf: [UInt8](arrayLiteral:
            0xff, 0xe2, 0, 3, 66,
            0xff, 0xfe, 0, 3, 66), at: 2)
        let expected = try JPEGLSParser(data: second).parse()
        let parser = JPEGLSParser(data: first + second)
        #expect(throws: JPEGLSError.self) { try parser.parse() }
        let result = try parser.parse()
        #expect(result.frameHeader == expected.frameHeader)
        #expect(result.scanHeaders == expected.scanHeaders)
        #expect(result.scanRestartIntervals == expected.scanRestartIntervals)
        #expect(result.mappingTables.isEmpty)
        #expect(result.comments == expected.comments)
        #expect(result.applicationMarkers.map { $0.marker } == expected.applicationMarkers.map { $0.marker })
        #expect(result.applicationMarkers.map { $0.data } == expected.applicationMarkers.map { $0.data })
        let expectedRanges = expected.scanDataRanges.map {
            ($0.lowerBound + first.count)..<($0.upperBound + first.count)
        }
        #expect(result.scanDataRanges == expectedRanges)
    }

    @Test("Scalar run-index mapping matches every table entry and clamps both ends")
    func scalarRunIndexMapping() throws {
        let expected = [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
                        4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        let decoder = try JPEGLSRunModeDecoder(parameters: .defaultParameters(bitsPerSample: 12))
        for index in expected.indices { #expect(decoder.computeJ(runIndex: index) == expected[index]) }
        for index in [Int.min, -1] { #expect(decoder.computeJ(runIndex: index) == 0) }
        for index in [32, Int.max] { #expect(decoder.computeJ(runIndex: index) == 15) }
    }
}
