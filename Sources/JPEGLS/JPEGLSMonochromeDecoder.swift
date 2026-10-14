import Foundation

extension JPEGLSDecoder {
    /// Scalar result for the caller-storage monochrome API. Samples are unsigned
    /// UInt16 values in host byte order, with the same mapping semantics as decode.
    public struct MonochromeInfo: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let bitsPerSample: Int
        public let near: Int
        public let pointTransform: Int
        public let mappingTableID: UInt8
        public let hasMappingTables: Bool
        public let colorTransformation: JPEGLSColorTransformation
        public var sampleCount: Int { width * height }
    }

    /// Caller-provided scratch: 256 table widths, 65,536 reachable palette values,
    /// and fixed adaptive context records. Alignment must be at least Int.alignment.
    /// The qualified API uses this exact payload capacity plus fixed value controls
    /// on the synchronous call stack; no variable control backing is allocated.
    /// Scratch must contain only trivial raw storage; its memory binding may change.
    public static var monochromeWorkspaceByteCount: Int {
        256 * MemoryLayout<Int>.stride + 65_536 * MemoryLayout<UInt16>.stride +
        JPEGLSContextModel.workspaceByteCount
    }

    /// Compatibility API: retains Task cancellation and legacy error values.
    public func inspectMonochrome(_ encoded: UnsafeRawBufferPointer,
                                  workspace: UnsafeMutableRawBufferPointer) throws -> MonochromeInfo {
        return try inspectMonochromeQualified(encoded, workspace: workspace, cancellation: .task).legacyValue()
    }

    /// Compatibility API: retains Task cancellation and legacy error values.
    public func decodeMonochrome(_ encoded: UnsafeRawBufferPointer,
                                 into output: UnsafeMutableBufferPointer<UInt16>,
                                 workspace: UnsafeMutableRawBufferPointer) throws -> MonochromeInfo {
        return try decodeMonochromeQualified(encoded, into: output, workspace: workspace, cancellation: .task).legacyValue()
    }

    /// Inspect through the canonical parser without owning a compressed-data copy
    /// or expanding APP, COM or palette payloads. Failures are returned as values;
    /// the qualified path never throws or looks up an Error witness. Input and
    /// workspace must not overlap and must remain alive throughout the call.
    public func inspectMonochromeQualified(_ encoded: UnsafeRawBufferPointer,
                                  workspace: UnsafeMutableRawBufferPointer,
                                  cancellation: JPEGLSCancellation = .init()) -> JPEGLSManagedOutcome<MonochromeInfo> {
        if let failure = validateMonochromeSpans(encoded, workspace: workspace, cancellation: cancellation) { return .failure(failure) }
        var storage = monochromeStorage(workspace)
        var parser = JPEGLSParserCore(reader: JPEGLSBitstreamCursor(borrowing: encoded, cancellation: cancellation))
        let parsed: JPEGLSParseState
        switch parser.parse(storage: &storage) {
        case .success(let value): parsed = value
        case .failure(let failure): return .failure(failure)
        }
        if let failure = storage.validateRestarts(parsed) { return .failure(failure) }
        switch monochromePlan(parsed, hasMappingTables: storage.hasMappingTables) {
        case .success(let value): return .success(value.info)
        case .failure(let failure): return .failure(failure)
        }
    }

    /// Decode with the canonical flat kernel into caller-owned initialized UInt16
    /// storage. Input, destination and workspace must be disjoint and remain alive
    /// and exclusively borrowed for this call. No pointer escapes. On error or
    /// cancellation the destination may be partly written; it must not be published.
    ///
    /// The complete structure/header/restart envelope is checked before sample writes.
    /// Entropy and mapped-sample validation can still fail afterward. Restart regions
    /// run sequentially in the destination; palettes are applied after reconstruction.
    /// The decoded-byte limit counts this API's UInt16 output, rather than the
    /// legacy API's Int rows. No input-sized or image-sized internal copy is made.
    /// The existing point-transform reconstruction behavior is unchanged.
    public func decodeMonochromeQualified(_ encoded: UnsafeRawBufferPointer,
                                 into output: UnsafeMutableBufferPointer<UInt16>,
                                 workspace: UnsafeMutableRawBufferPointer,
                                  cancellation: JPEGLSCancellation = .init()) -> JPEGLSManagedOutcome<MonochromeInfo> {
        if let failure = validateMonochromeSpans(encoded, workspace: workspace, cancellation: cancellation) { return .failure(failure) }
        guard output.count <= Int.max / MemoryLayout<UInt16>.stride else {
            return .failure(JPEGLSManagedFailure(.destinationOverflow))
        }
        let outputRaw = UnsafeRawBufferPointer(output)
        guard !Self.overlaps(encoded, outputRaw),
              !Self.overlaps(UnsafeRawBufferPointer(workspace), outputRaw),
              outputRaw.baseAddress.map({ UInt(bitPattern: $0) % UInt(MemoryLayout<UInt16>.alignment) == 0 }) ?? true else {
            return .failure(JPEGLSManagedFailure(.overlappingBuffers))
        }
        var firstStorage = monochromeStorage(workspace)
        var firstParser = JPEGLSParserCore(reader: JPEGLSBitstreamCursor(borrowing: encoded, cancellation: cancellation))
        let inspection: JPEGLSParseState
        switch firstParser.parse(storage: &firstStorage) {
        case .success(let value): inspection = value
        case .failure(let failure): return .failure(failure)
        }
        if let failure = firstStorage.validateRestarts(inspection) { return .failure(failure) }
        let plan: MonochromePlan
        switch monochromePlan(inspection, hasMappingTables: firstStorage.hasMappingTables) {
        case .success(let value): plan = value
        case .failure(let failure): return .failure(failure)
        }
        let info = plan.info
        guard output.count >= info.sampleCount else {
            return .failure(JPEGLSManagedFailure(.destinationTooSmall))
        }
        let scan = inspection.firstScan
        let selector = scan.components[0]
        let interval = inspection.scanRestartInterval
        let restartActive = interval > 0 && interval < info.height
        let expectedRegions = restartActive ? 1 + (info.height - 1) / interval : 1
        let contextOffset = 256 * MemoryLayout<Int>.stride + 65_536 * MemoryLayout<UInt16>.stride
        let contextWorkspace = UnsafeMutableRawBufferPointer(rebasing: workspace[contextOffset..<Self.monochromeWorkspaceByteCount])
        let (limit, qbppBits) = computeGolombLimit(parameters: plan.parameters, near: info.near,
                                                  bitsPerSample: info.bitsPerSample)
        let consumer = JPEGLSMonochromeRegionConsumer(decoder: self, encoded: encoded, output: output,
            contextWorkspace: contextWorkspace, cancellation: cancellation, info: info,
            parameters: plan.parameters, interval: interval, expectedRegions: expectedRegions,
            restartActive: restartActive, limit: limit, qbppBits: qbppBits)
        var storage = monochromeStorage(workspace, selectedTable: selector.mappingTableID, consumer: consumer)
        var parser = JPEGLSParserCore(reader: JPEGLSBitstreamCursor(borrowing: encoded, cancellation: cancellation))
        // The same grammar emits regions into a concrete value sink. There is no
        // escaping callback, capture box, or retained region list.
        if case .failure(let failure) = parser.parse(storage: &storage) { return .failure(failure) }
        guard storage.consumer?.region == expectedRegions,
              storage.consumer?.decodedRows == info.height else {
            return .failure(JPEGLSManagedFailure(.incompleteReconstruction))
        }
        let sampleCap = (1 << info.bitsPerSample) - 1
        for index in 0..<info.sampleCount {
            if index & 0xFFFF == 0, let failure = cancellation.checkpoint() { return .failure(failure) }
            let value = storage.mapped(output[index])
            guard Int(value) <= sampleCap else {
                return .failure(JPEGLSManagedFailure(.mappedPrecision))
            }
            output[index] = value
        }
        return .success(info)
    }

    private typealias MonochromePlan = (info: MonochromeInfo, parameters: JPEGLSPresetParameters)

    private func monochromePlan(_ parsed: JPEGLSParseState, hasMappingTables: Bool) -> JPEGLSManagedOutcome<MonochromePlan> {
        let frame = parsed.frameHeader
        let scan = parsed.firstScan
        guard frame.componentCount == 1, parsed.scanCount == 1, scan.interleaveMode == .none else {
            return .failure(JPEGLSManagedFailure(.monochromeProfile))
        }
        let component = frame.components[0]
        guard component.horizontalSamplingFactor > 0, component.verticalSamplingFactor > 0 else {
            return .failure(JPEGLSManagedFailure(.samplingFactors))
        }
        let (count, overflow) = frame.width.multipliedReportingOverflow(by: frame.height)
        let (bytes, byteOverflow) = count.multipliedReportingOverflow(by: MemoryLayout<UInt16>.stride)
        guard !overflow, !byteOverflow, count > 0,
              count <= limits.maximumPixels, bytes <= limits.maximumDecodedBytes else {
            return .failure(JPEGLSManagedFailure(.decodedLimit))
        }
        let parameters: JPEGLSPresetParameters
        if let preset = parsed.presetParameters { parameters = preset }
        else {
            switch JPEGLSPresetParameters.qualifiedDefaultParameters(bitsPerSample: frame.bitsPerSample, near: scan.near) {
            case .success(let value): parameters = value
            case .failure(let failure): return .failure(failure)
            }
        }
        guard parameters.maxValue <= (1 << frame.bitsPerSample) - 1 else {
            return .failure(JPEGLSManagedFailure(.maxValuePrecision))
        }
        return .success((MonochromeInfo(width: frame.width, height: frame.height,
            bitsPerSample: frame.bitsPerSample, near: scan.near, pointTransform: scan.pointTransform,
            mappingTableID: scan.components[0].mappingTableID,
            hasMappingTables: hasMappingTables, colorTransformation: parsed.colorTransformation), parameters))
    }

    private func validateMonochromeSpans(_ encoded: UnsafeRawBufferPointer,
                                        workspace: UnsafeMutableRawBufferPointer, cancellation: JPEGLSCancellation) -> JPEGLSManagedFailure? {
        guard encoded.count <= limits.maximumEncodedBytes,
              workspace.count >= Self.monochromeWorkspaceByteCount,
              let address = workspace.baseAddress,
              UInt(bitPattern: address) % UInt(MemoryLayout<Int>.alignment) == 0,
              !Self.overlaps(encoded, UnsafeRawBufferPointer(workspace)) else {
            return JPEGLSManagedFailure(.invalidCallerSpans)
        }
        return cancellation.checkpoint()
    }

    private func monochromeStorage(_ workspace: UnsafeMutableRawBufferPointer,
                                   selectedTable: UInt8? = nil,
                                   consumer: JPEGLSMonochromeRegionConsumer? = nil) -> JPEGLSMonochromeParseStorage {
        // validateMonochromeSpans establishes a nonnil, aligned backing first.
        let tableOffset = 256 * MemoryLayout<Int>.stride
        let widths = UnsafeMutableRawBufferPointer(rebasing: workspace[..<tableOffset]).bindMemory(to: Int.self)
        let values = UnsafeMutableRawBufferPointer(rebasing: workspace[tableOffset..<(tableOffset + 65_536 * 2)])
            .bindMemory(to: UInt16.self)
        return JPEGLSMonochromeParseStorage(widths: UnsafeMutableBufferPointer(rebasing: widths[..<256]),
            values: values, selectedTable: selectedTable, consumer: consumer)
    }

    private static func overlaps(_ left: UnsafeRawBufferPointer, _ right: UnsafeRawBufferPointer) -> Bool {
        guard !left.isEmpty, !right.isEmpty, let l = left.baseAddress, let r = right.baseAddress else { return false }
        let a = UInt(bitPattern: l), b = UInt(bitPattern: r)
        let (endA, overA) = a.addingReportingOverflow(UInt(left.count))
        let (endB, overB) = b.addingReportingOverflow(UInt(right.count))
        return overA || overB || (a < endB && b < endA)
    }
}

/// Concrete mutable region sink. Its pointers and cancellation context are borrowed
/// for the enclosing synchronous call, and no value is returned to the caller.
internal struct JPEGLSMonochromeRegionConsumer {
    let decoder: JPEGLSDecoder
    let encoded: UnsafeRawBufferPointer
    let output: UnsafeMutableBufferPointer<UInt16>
    let contextWorkspace: UnsafeMutableRawBufferPointer
    let cancellation: JPEGLSCancellation
    let info: JPEGLSDecoder.MonochromeInfo
    let parameters: JPEGLSPresetParameters
    let interval: Int, expectedRegions: Int
    let restartActive: Bool
    let limit: Int, qbppBits: Int
    private(set) var region = 0
    private(set) var decodedRows = 0

    mutating func consume(_ range: Range<Int>, marker: UInt8?) -> JPEGLSManagedFailure? {
        if let failure = cancellation.checkpoint() { return failure }
        guard region < expectedRegions else { return JPEGLSManagedFailure(.tooManyRegions) }
        if let marker {
            guard restartActive, region < expectedRegions - 1,
                  marker == JPEGLSMarker.restart0.rawValue + UInt8(region % 8) else {
                return JPEGLSManagedFailure(.restartMarker)
            }
        } else if region != expectedRegions - 1 { return JPEGLSManagedFailure(.missingRegions) }
        let rows = restartActive ? min(interval, info.height - decodedRows) : info.height
        let start = decodedRows * info.width
        let destination = UnsafeMutableBufferPointer(rebasing: output[start..<(start + rows * info.width)])
        var reader = JPEGLSBitstreamCursor(borrowing: UnsafeRawBufferPointer(rebasing: encoded[range]),
            cancellation: cancellation)
        if let failure = decoder.decodeFlatRegionQualified(reader: &reader, rows: rows, width: info.width,
            parameters: parameters, near: info.near, limit: limit, qbppBits: qbppBits,
            into: destination, workspace: contextWorkspace) { return failure }
        decodedRows += rows
        region += 1
        return nil
    }
}
