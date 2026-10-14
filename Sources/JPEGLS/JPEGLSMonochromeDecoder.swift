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
    /// This describes payload scratch, not Swift runtime/control object allocations.
    /// Scratch must contain only trivial raw storage; its memory binding may change.
    public static var monochromeWorkspaceByteCount: Int {
        256 * MemoryLayout<Int>.stride + 65_536 * MemoryLayout<UInt16>.stride +
        JPEGLSContextModel.workspaceByteCount
    }

    /// Inspect through the canonical parser without owning a compressed-data copy
    /// or expanding APP, COM or palette payloads. Input and workspace must not
    /// overlap and must remain alive throughout the synchronous call.
    public func inspectMonochrome(_ encoded: UnsafeRawBufferPointer,
                                  workspace: UnsafeMutableRawBufferPointer) throws -> MonochromeInfo {
        try validateMonochromeSpans(encoded, workspace: workspace)
        let storage = monochromeStorage(workspace)
        let parsed = try JPEGLSParser(borrowing: encoded, storage: storage).parse()
        try storage.validateRestarts(parsed)
        return try monochromePlan(parsed, hasMappingTables: storage.hasMappingTables).info
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
    public func decodeMonochrome(_ encoded: UnsafeRawBufferPointer,
                                 into output: UnsafeMutableBufferPointer<UInt16>,
                                 workspace: UnsafeMutableRawBufferPointer) throws -> MonochromeInfo {
        try validateMonochromeSpans(encoded, workspace: workspace)
        guard output.count <= Int.max / MemoryLayout<UInt16>.stride else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "JPEG-LS destination size overflows")
        }
        let outputRaw = UnsafeRawBufferPointer(output)
        guard !Self.overlaps(encoded, outputRaw),
              !Self.overlaps(UnsafeRawBufferPointer(workspace), outputRaw),
              outputRaw.baseAddress.map({ UInt(bitPattern: $0) % UInt(MemoryLayout<UInt16>.alignment) == 0 }) ?? true else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "JPEG-LS caller buffers overlap or are unaligned")
        }
        let firstStorage = monochromeStorage(workspace)
        let inspection = try JPEGLSParser(borrowing: encoded, storage: firstStorage).parse()
        try firstStorage.validateRestarts(inspection)
        let plan = try monochromePlan(inspection, hasMappingTables: firstStorage.hasMappingTables)
        let info = plan.info
        guard output.count >= info.sampleCount else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "JPEG-LS destination is too small")
        }
        guard let scan = inspection.scanHeaders.first, let selector = scan.components.first else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "Missing monochrome scan")
        }
        let interval = inspection.scanRestartIntervals.first ?? 0
        let restartActive = interval > 0 && interval < info.height
        let expectedRegions = restartActive ? 1 + (info.height - 1) / interval : 1
        let storage = monochromeStorage(workspace, selectedTable: selector.mappingTableID)
        let contextOffset = 256 * MemoryLayout<Int>.stride + 65_536 * MemoryLayout<UInt16>.stride
        let contextWorkspace = UnsafeMutableRawBufferPointer(rebasing: workspace[contextOffset..<Self.monochromeWorkspaceByteCount])
        let (limit, qbppBits) = computeGolombLimit(parameters: plan.parameters, near: info.near,
                                                  bitsPerSample: info.bitsPerSample)
        var region = 0
        var decodedRows = 0
        storage.consumeRegion = { range, marker in
            try Task.checkCancellation()
            guard region < expectedRegions else {
                throw JPEGLSError.invalidBitstreamStructure(reason: "Too many JPEG-LS restart regions")
            }
            if let marker {
                guard restartActive, region < expectedRegions - 1,
                      marker == JPEGLSMarker.restart0.rawValue + UInt8(region % 8) else {
                    throw JPEGLSError.invalidBitstreamStructure(reason: "Unexpected JPEG-LS restart marker")
                }
            } else if region != expectedRegions - 1 {
                throw JPEGLSError.invalidBitstreamStructure(reason: "Missing JPEG-LS restart regions")
            }
            let rows = restartActive ? min(interval, info.height - decodedRows) : info.height
            let start = decodedRows * info.width
            let destination = UnsafeMutableBufferPointer(rebasing: output[start..<(start + rows * info.width)])
            try decodeFlatRegion(reader: JPEGLSBitstreamReader(borrowing: UnsafeRawBufferPointer(rebasing: encoded[range])),
                rows: rows, width: info.width, parameters: plan.parameters, near: info.near,
                limit: limit, qbppBits: qbppBits, into: destination, workspace: contextWorkspace)
            decodedRows += rows
            region += 1
        }
        // The same grammar finds the regions again; no separate restart walker or
        // an unbounded array of ranges/decoded regions is introduced.
        _ = try JPEGLSParser(borrowing: encoded, storage: storage).parse()
        guard region == expectedRegions, decodedRows == info.height else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "Incomplete JPEG-LS reconstruction")
        }
        let sampleCap = (1 << info.bitsPerSample) - 1
        for index in 0..<info.sampleCount {
            if index & 0xFFFF == 0 { try Task.checkCancellation() }
            let value = storage.mapped(output[index])
            guard Int(value) <= sampleCap else {
                throw JPEGLSError.invalidBitstreamStructure(reason: "Mapped sample exceeds frame precision")
            }
            output[index] = value
        }
        return info
    }

    private func monochromePlan(_ parsed: JPEGLSParseResult, hasMappingTables: Bool) throws ->
        (info: MonochromeInfo, parameters: JPEGLSPresetParameters) {
        let frame = parsed.frameHeader
        guard frame.componentCount == 1, parsed.scanHeaders.count == 1,
              let scan = parsed.scanHeaders.first, scan.interleaveMode == .none else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "Monochrome decoding requires one non-interleaved scan")
        }
        guard let component = frame.components.first,
              component.horizontalSamplingFactor > 0, component.verticalSamplingFactor > 0 else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "Invalid monochrome sampling factors")
        }
        let (count, overflow) = frame.width.multipliedReportingOverflow(by: frame.height)
        let (bytes, byteOverflow) = count.multipliedReportingOverflow(by: MemoryLayout<UInt16>.stride)
        guard !overflow, !byteOverflow, count > 0,
              count <= limits.maximumPixels, bytes <= limits.maximumDecodedBytes else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "JPEG-LS exceeds decoded pixel/byte limit")
        }
        let parameters = try parsed.presetParameters ?? JPEGLSPresetParameters.defaultParameters(
            bitsPerSample: frame.bitsPerSample, near: scan.near)
        guard parameters.maxValue <= (1 << frame.bitsPerSample) - 1 else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "MAXVAL exceeds frame precision")
        }
        return (MonochromeInfo(width: frame.width, height: frame.height,
            bitsPerSample: frame.bitsPerSample, near: scan.near, pointTransform: scan.pointTransform,
            mappingTableID: scan.components.first?.mappingTableID ?? 0,
            hasMappingTables: hasMappingTables, colorTransformation: parsed.colorTransformation), parameters)
    }

    private func validateMonochromeSpans(_ encoded: UnsafeRawBufferPointer,
                                        workspace: UnsafeMutableRawBufferPointer) throws {
        guard encoded.count <= limits.maximumEncodedBytes,
              workspace.count >= Self.monochromeWorkspaceByteCount,
              let address = workspace.baseAddress,
              UInt(bitPattern: address) % UInt(MemoryLayout<Int>.alignment) == 0,
              !Self.overlaps(encoded, UnsafeRawBufferPointer(workspace)) else {
            throw JPEGLSError.invalidBitstreamStructure(reason: "Invalid JPEG-LS input or workspace capacity/alignment")
        }
        try Task.checkCancellation()
    }

    private func monochromeStorage(_ workspace: UnsafeMutableRawBufferPointer,
                                   selectedTable: UInt8? = nil) -> JPEGLSMonochromeParseStorage {
        // validateMonochromeSpans establishes a nonnil, aligned backing first.
        let tableOffset = 256 * MemoryLayout<Int>.stride
        let widths = UnsafeMutableRawBufferPointer(rebasing: workspace[..<tableOffset]).bindMemory(to: Int.self)
        let values = UnsafeMutableRawBufferPointer(rebasing: workspace[tableOffset..<(tableOffset + 65_536 * 2)])
            .bindMemory(to: UInt16.self)
        return JPEGLSMonochromeParseStorage(widths: UnsafeMutableBufferPointer(rebasing: widths[..<256]),
            values: values, selectedTable: selectedTable)
    }

    private static func overlaps(_ left: UnsafeRawBufferPointer, _ right: UnsafeRawBufferPointer) -> Bool {
        guard !left.isEmpty, !right.isEmpty, let l = left.baseAddress, let r = right.baseAddress else { return false }
        let a = UInt(bitPattern: l), b = UInt(bitPattern: r)
        let (endA, overA) = a.addingReportingOverflow(UInt(left.count))
        let (endB, overB) = b.addingReportingOverflow(UInt(right.count))
        return overA || overB || (a < endB && b < endA)
    }
}
