// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster Images Private Limited
//
// The shared-contract codec surface for JPEG-LS.
//
// This is the contract's `Image` layer wired to the existing JPEG-LS codec.
// It sits beside the library's established `JPEGLSEncoder`/`JPEGLSDecoder`
// API rather than replacing it: decision D1 keeps the codec in this
// repository, so both surfaces coexist and the established one keeps its
// consumers.
//
// The initial shared layout (MEM-03) is what this surface guarantees today:
// one plane, one component, unsigned 16-bit, little-endian, even
// `rowBytes >= width * 2`, no subsampling, lossless. Anything else is
// reported as an incompatibility rather than silently converted.

import Foundation

public struct JPEGLSContractCodec: Sendable {
    public init() {}

    /// What this surface can actually do, as opposed to what the contract
    /// describes. POL-08: planned capability is not reported as present.
    public static var capabilities: CodecCapabilities {
        CodecCapabilities(
            formats: ["JPEG-LS"],
            compressionModes: [.lossless],
            sampleTypes: [.unsignedInteger],
            meaningfulPrecision: 2...16,
            layouts: ["greyscale16"],
            availableBackends: [.scalarCPU],
            canInspect: true, canEncode: true, canDecode: true)
    }

    // MARK: - Inspection

    /// Describe the output layout a decode would produce, without decoding
    /// (MEM-10). Callers use this to allocate or check their own storage.
    public func inspect(_ data: Data, limits: ResourceLimits = .default) throws -> ImageDescriptor {
        let frame = try Self.frameHeader(of: data, limits: limits)
        return try ImageDescriptor.greyscale16(
            width: frame.width, height: frame.height,
            meaningfulBits: frame.bitsPerSample, limits: limits)
    }

    // MARK: - Encode

    /// Encode an `Image` whose samples stay where the caller put them.
    ///
    /// Under `requireSharedStorage` the samples are read directly out of the
    /// caller's allocation, honouring its row stride; no full-frame copy is
    /// made and no intermediate image is built. Metadata preservation and progress
    /// callbacks are not implemented by this synchronous surface and are rejected
    /// when requested; ancillary metadata may be explicitly discarded.
    public func encode(_ image: Image,
                       configuration: EncoderConfiguration = .default,
                       options: EncodeOptions = EncodeOptions()) throws -> (Data, OperationReport) {
        let started = Date()
        let fallbackReason = try Self.validatePolicy(options.executionPolicy, hasProgress: options.progress != nil)
        try Self.validateMetadata(image.metadata, iccProfile: image.descriptor.iccProfile,
                                  policy: options.metadataPolicy)
        guard configuration.mode == .lossless else {
            throw CodecError(.unsupportedFeature, "This surface encodes the lossless mode only.")
        }
        let layout = try SharedLayout(descriptor: image.descriptor, policy: options.copyPolicy)
        try image.descriptor.validate(limits: options.resourceLimits)

        let encoder = JPEGLSEncoder()
        let parameters = try JPEGLSPresetParameters.defaultParameters(
            bitsPerSample: layout.meaningfulBits, near: 0)
        let frame = try JPEGLSFrameHeader(
            bitsPerSample: layout.meaningfulBits, height: layout.height, width: layout.width,
            componentCount: 1, components: [JPEGLSFrameHeader.ComponentSpec(id: 1)])
        let scan = try JPEGLSScanHeader(
            componentCount: 1,
            components: [JPEGLSScanHeader.ComponentSelector(id: 1, mappingTableID: 0)],
            near: 0, interleaveMode: .none, pointTransform: 0)

        let capacity = try checkedAdd(checkedMultiply(layout.sampleCount, 2), 4096)
        guard capacity <= options.resourceLimits.maximumWorkspaceBytes else {
            throw CodecError(.resourceLimitExceeded, "Encoder workspace exceeds the operation budget.")
        }
        let writer = JPEGLSBitstreamWriter(capacity: capacity)
        writer.writeMarker(.startOfImage)
        try encoder.writeFrameHeaderForContract(frame, to: writer)
        try encoder.writeScanHeaderForContract(scan, to: writer)

        let regularMode = try JPEGLSRegularMode(parameters: parameters, near: 0)
        let runMode = try JPEGLSRunMode(parameters: parameters, near: 0)
        var context = try JPEGLSContextModel(parameters: parameters, near: 0)
        let (limit, qbppBits) = encoder.golombLimitForContract(
            parameters: parameters, near: 0, bitsPerSample: layout.meaningfulBits)

        try image.storage.withUnsafeBytes { bytes in
            try layout.checkCapacity(bytes.count)
            try Task.checkCancellation()
            let region = UnsafeRawBufferPointer(
                rebasing: bytes[layout.offset..<(layout.offset + layout.extent)])
            // Reinterpreting the caller's bytes as native UInt16 is a view, not
            // a conversion: the shared layout declares little-endian and the
            // layout check above rejects a big-endian host.
            try region.withMemoryRebound(to: UInt16.self) { samples in
                guard let base = samples.baseAddress else {
                    throw CodecError(.storageUnavailable, "Sample region has no base address.")
                }
                encoder.encodeFlatRowsLossless(
                    buf: UnsafeBufferPointer(start: base, count: layout.strideSamples * (layout.height - 1) + layout.width),
                    rowStride: layout.strideSamples, rowRange: 0..<layout.height, width: layout.width,
                    regularMode: regularMode, runMode: runMode, context: &context,
                    writer: writer, limit: limit, qbppBits: qbppBits)
            }
        }

        writer.flush()
        writer.writeMarker(.endOfImage)
        let data = try writer.getData()
        let report = OperationReport(
            backend: .scalarCPU, fallbackReason: fallbackReason, fidelity: .exactSamples,
            // No copy events: samples were read in place. Under `allowCopy`
            // this surface still shares, because sharing is always compatible
            // with the shared layout; a conversion would appear here.
            copyEvents: [],
            pixelAllocationCount: 0, peakPixelBytes: 0,
            peakWorkspaceBytes: capacity,
            elapsedSeconds: Date().timeIntervalSince(started))
        return (data, report)
    }

    // MARK: - Decode

    /// Decode into the caller's destination, writing final samples straight
    /// into its allocation (MEM-10). Unsupported policies and signalled transforms
    /// are rejected before the destination's write begins, leaving it reusable.
    @discardableResult
    public func decode(_ data: Data, into destination: ImageDestination,
                       configuration: DecoderConfiguration = DecoderConfiguration(),
                       options: DecodeOptions = DecodeOptions()) throws -> (Image, OperationReport) {
        let started = Date()
        let fallbackReason = try Self.validatePolicy(options.executionPolicy, hasProgress: options.progress != nil)
        _ = configuration
        try destination.descriptor.validate(limits: options.resourceLimits)
        let layout = try SharedLayout(descriptor: destination.descriptor, policy: options.copyPolicy)
        let data = try Self.normalisedInput(data, limits: options.resourceLimits)
        let parsed = try Self.parse(data, limits: options.resourceLimits)
        let frame = parsed.frameHeader
        guard frame.width == layout.width, frame.height == layout.height else {
            throw CodecError(.incompatibleImageLayout,
                "Codestream is \(frame.width)x\(frame.height); destination is \(layout.width)x\(layout.height).")
        }
        guard frame.bitsPerSample == layout.meaningfulBits else {
            throw CodecError(.incompatibleImageLayout,
                "Codestream is \(frame.bitsPerSample)-bit; destination declares \(layout.meaningfulBits).")
        }
        guard frame.componentCount == 1 else {
            throw CodecError(.unsupportedFeature,
                "This surface decodes one component; codestream has \(frame.componentCount).")
        }
        guard let scan = parsed.scanHeaders.first, scan.near == 0 else {
            throw CodecError(.unsupportedFeature, "This surface decodes the lossless mode only.")
        }
        guard parsed.scanDataRanges.count == 1 else {
            throw CodecError(.unsupportedFeature, "This surface decodes a single scan.")
        }
        guard scan.pointTransform == 0, scan.components.allSatisfy({ $0.mappingTableID == 0 }),
              parsed.colorTransformation == .none else {
            throw CodecError(.unsupportedFeature, "This surface does not implement sample or colour transforms.")
        }
        let restartInterval = parsed.scanRestartIntervals.first ?? 0
        guard restartInterval == 0 || restartInterval >= frame.height else {
            throw CodecError(.unsupportedFeature, "This surface does not implement restart-segmented scans.")
        }
        if options.metadataPolicy == .preserve,
           !parsed.applicationMarkers.isEmpty || !parsed.comments.isEmpty {
            throw CodecError(.unsupportedFeature,
                "This surface cannot preserve JPEG-LS application or comment metadata.")
        }

        let parameters = try parsed.presetParameters ?? JPEGLSPresetParameters.defaultParameters(
            bitsPerSample: frame.bitsPerSample, near: 0)
        // Match the legacy decoder's ITU-T.87 C.2.4.1.1 sample-range admission.
        guard parameters.maxValue <= (1 << frame.bitsPerSample) - 1 else {
            throw CodecError(.malformedInput, "Preset MAXVAL exceeds the frame's meaningful precision.")
        }
        let scanData = Data(data[parsed.scanDataRanges[0]])
        // The flat reconstruction kernel cannot reset contexts at restart markers.
        // Reject even stray RST markers when DRI is absent or covers the whole image.
        guard !JPEGLSDecoder.scanBodyContainsRestartMarker(scanData) else {
            throw CodecError(.unsupportedFeature, "This surface does not implement restart markers.")
        }
        let reader = JPEGLSBitstreamReader(data: scanData)
        let (limit, qbppBits) = JPEGLSEncoder().golombLimitForContract(
            parameters: parameters, near: 0, bitsPerSample: frame.bitsPerSample)
        let decoder = JPEGLSDecoder()

        // One exclusive write, sealed on success and invalidated on failure by
        // `ImageDestination.write`. Padding beyond the row payload is never
        // written, so caller sentinels there survive.
        let image = try destination.write { bytes in
            try layout.checkCapacity(bytes.count)
            try Task.checkCancellation()
            let region = UnsafeMutableRawBufferPointer(
                rebasing: bytes[layout.offset..<(layout.offset + layout.extent)])
            try region.withMemoryRebound(to: UInt16.self) { samples in
                guard let base = samples.baseAddress else {
                    throw CodecError(.storageUnavailable, "Sample region has no base address.")
                }
                try decoder.decodeFlatRegion(
                    into: UnsafeMutableBufferPointer(
                        start: base, count: layout.strideSamples * (layout.height - 1) + layout.width),
                    rowStride: layout.strideSamples, reader: reader,
                    rows: layout.height, width: layout.width, parameters: parameters,
                    near: 0, limit: limit, qbppBits: qbppBits)
            }
        }

        let report = OperationReport(
            backend: .scalarCPU, fallbackReason: fallbackReason, fidelity: .exactSamples, copyEvents: [],
            pixelAllocationCount: 0, peakPixelBytes: 0,
            // The decoder's own line/context state is bounded per row, not per
            // frame, so no frame-proportional workspace is owned here.
            peakWorkspaceBytes: nil,
            elapsedSeconds: Date().timeIntervalSince(started))
        return (image, report)
    }

    /// Allocating convenience. MEM-10 requires this and the caller-destination
    /// decode to use the same final-output path, so it allocates a destination
    /// and calls the method above rather than having a path of its own.
    public func decode(_ data: Data,
                       configuration: DecoderConfiguration = DecoderConfiguration(),
                       options: DecodeOptions = DecodeOptions()) throws -> (Image, OperationReport) {
        _ = try Self.validatePolicy(options.executionPolicy, hasProgress: options.progress != nil)
        let descriptor = try inspect(data, limits: options.resourceLimits)
        let destination = try ImageDestination.allocate(
            descriptor: descriptor, limits: options.resourceLimits)
        return try decode(data, into: destination, configuration: configuration, options: options)
    }

    // MARK: - Policy preflight

    /// Synchronous calls cannot meet the generic-executor callback contract.
    /// Decline callbacks rather than silently dropping them or invoking them on
    /// an undocumented executor while the caller's storage is borrowed.
    private static func validatePolicy(_ policy: ExecutionPolicy, hasProgress: Bool) throws -> String? {
        if case .required(.accelerated) = policy {
            throw CodecError(.backendUnavailable, "No accelerated backend is implemented by this surface.")
        }
        guard !hasProgress else {
            throw CodecError(.unsupportedFeature, "Progress callbacks are not implemented by this synchronous surface.")
        }
        if case .preferred(.accelerated) = policy {
            return "The preferred accelerated backend is unavailable; scalar CPU was used."
        }
        return nil
    }

    private static func validateMetadata(_ metadata: ImageMetadata, iccProfile: Data?,
                                         policy: MetadataPolicy) throws {
        guard metadata.requiredKeys.isEmpty else {
            throw CodecError(.unsupportedFeature, "This surface cannot preserve required image metadata.")
        }
        if policy == .preserve, !metadata.entries.isEmpty || !(iccProfile?.isEmpty ?? true) {
            throw CodecError(.unsupportedFeature, "This surface cannot preserve image metadata or ICC profiles.")
        }
    }

    // MARK: - Parsing helpers

    private static func normalisedInput(_ data: Data, limits: ResourceLimits) throws -> Data {
        guard data.count <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input exceeds the operation budget.")
        }
        return data.startIndex == 0 ? data : Data(data)
    }

    private static func parse(_ data: Data, limits: ResourceLimits) throws -> JPEGLSParseResult {
        let normalised = try normalisedInput(data, limits: limits)
        do {
            return try JPEGLSParser(data: normalised).parse()
        } catch let error as JPEGLSError {
            throw CodecError(.malformedInput, "JPEG-LS parse failed: \(error)")
        }
    }

    private static func frameHeader(of data: Data, limits: ResourceLimits) throws -> JPEGLSFrameHeader {
        let frame = try parse(data, limits: limits).frameHeader
        guard frame.componentCount == 1 else {
            throw CodecError(.unsupportedFeature,
                "This surface describes one-component images; codestream has \(frame.componentCount).")
        }
        guard (2...16).contains(frame.bitsPerSample) else {
            throw CodecError(.unsupportedFeature,
                "The shared layout supports 2...16 meaningful bits; codestream is \(frame.bitsPerSample)-bit.")
        }
        return frame
    }
}

// MARK: - Shared layout

/// The MEM-03 profile read off a descriptor, with MEM-04's checked arithmetic
/// resolved once so neither codec direction repeats it.
struct SharedLayout {
    let width: Int, height: Int, meaningfulBits: Int
    let offset: Int, rowBytes: Int, strideSamples: Int
    let extent: Int, sampleCount: Int

    init(descriptor: ImageDescriptor, policy: CopyPolicy) throws {
        guard descriptor.planes.count == 1, descriptor.components.count == 1,
              descriptor.components.first == .grey, descriptor.colour == .greyscale,
              descriptor.alpha == .absent else {
            throw CodecError(.incompatibleImageLayout,
                "This surface requires the single-plane greyscale shared layout.")
        }
        guard descriptor.sampleType == .unsignedInteger, descriptor.storageBits == 16 else {
            throw CodecError(.incompatibleImageLayout,
                "The shared layout is unsigned 16-bit storage.")
        }
        guard descriptor.byteOrder == .littleEndian else {
            // The conversion is representable, but it is a copy, and under
            // `requireSharedStorage` a copy is the thing being excluded. Rather
            // than silently differ by policy, this surface declines both ways
            // and says so.
            throw CodecError(.incompatibleImageLayout,
                "The shared layout is little-endian; this descriptor is big-endian.")
        }
        let plane = descriptor.planes[0]
        guard plane.pixelStride == 2, plane.sampleStride == 2 else {
            throw CodecError(.incompatibleImageLayout,
                "The shared layout is a two-byte sample and pixel stride.")
        }
        guard plane.rowBytes % 2 == 0, plane.rowBytes >= descriptor.width * 2 else {
            throw CodecError(.incompatibleImageLayout,
                "rowBytes must be even and at least width * 2.")
        }
        guard plane.offset % 2 == 0 else {
            throw CodecError(.incompatibleImageLayout,
                "Plane offset must be two-byte aligned for 16-bit samples.")
        }
        // `allowCopy` would permit a conversion here. None is needed: every
        // layout this surface accepts is already shareable, so the default
        // path never silently becomes a copy (MEM-12).
        _ = policy

        width = descriptor.width
        height = descriptor.height
        meaningfulBits = descriptor.meaningfulBits
        offset = plane.offset
        rowBytes = plane.rowBytes
        strideSamples = plane.rowBytes / 2
        extent = try checkedAdd(checkedMultiply(descriptor.height - 1, plane.rowBytes),
                                checkedMultiply(descriptor.width, 2))
        sampleCount = try checkedMultiply(descriptor.width, descriptor.height)
    }

    /// MEM-04: the last byte touched, checked against the retained allocation.
    func checkCapacity(_ byteCount: Int) throws {
        let needed = try checkedAdd(offset, extent)
        guard byteCount >= needed else {
            throw CodecError(.storageUnavailable,
                "Storage holds \(byteCount) bytes; the layout needs \(needed).")
        }
    }
}

// MARK: - Narrow internal access for the contract surface

extension JPEGLSEncoder {
    func writeFrameHeaderForContract(_ header: JPEGLSFrameHeader, to writer: JPEGLSBitstreamWriter) throws {
        try writeFrameHeaderInternal(header, to: writer)
    }
    func writeScanHeaderForContract(_ header: JPEGLSScanHeader, to writer: JPEGLSBitstreamWriter) throws {
        try writeScanHeaderInternal(header, to: writer)
    }
    func golombLimitForContract(parameters: JPEGLSPresetParameters, near: Int,
                                bitsPerSample: Int) -> (limit: Int, qbppBits: Int) {
        computeGolombLimitInternal(parameters: parameters, near: near, bitsPerSample: bitsPerSample)
    }
}
