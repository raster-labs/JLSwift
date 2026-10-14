// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster Images Private Limited

import Foundation
import Testing
@testable import JPEGLS

@Suite("Contract codec policy preflight")
struct ContractPolicyTests {
    private func expectError(_ category: CodecError.Category, _ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected codec error \(category)")
        } catch let error as CodecError {
            #expect(error.category == category)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func expectSamples(_ image: Image, matching expected: Image) throws {
        #expect(image.descriptor.width == expected.descriptor.width)
        #expect(image.descriptor.height == expected.descriptor.height)
        for y in 0..<expected.descriptor.height {
            for x in 0..<expected.descriptor.width {
                #expect(try image.sampleUInt16(x: x, y: y) == expected.sampleUInt16(x: x, y: y))
            }
        }
    }

    /// Insert a valid marker before SOF without altering the image's entropy.
    private func inserting(_ segment: [UInt8], into codestream: Data) -> Data {
        var result = Data(codestream.prefix(2))
        result.append(contentsOf: segment)
        result.append(codestream.dropFirst(2))
        return result
    }

    @Test func requiredUnavailableBackendRejectsBeforeWriting() throws {
        let codec = JPEGLSContractCodec()
        let source = try ContractImageLayerTests.filledImage(width: 8, height: 5)
        let payload = try codec.encode(source).0
        expectError(.backendUnavailable) {
            _ = try codec.encode(source, options: EncodeOptions(executionPolicy: .required(.accelerated)))
        }
        let destination = try ImageDestination.allocate(descriptor: source.descriptor)
        expectError(.backendUnavailable) {
            _ = try codec.decode(payload, into: destination,
                                 options: DecodeOptions(executionPolicy: .required(.accelerated)))
        }
        try expectSamples(codec.decode(payload, into: destination).0, matching: source)
        // Policy rejection precedes parsing and allocating a convenience destination.
        expectError(.backendUnavailable) {
            _ = try codec.decode(Data(), options: DecodeOptions(executionPolicy: .required(.accelerated)))
        }
    }

    @Test func preferredUnavailableBackendReportsFallbackWithoutChangingSamples() throws {
        let codec = JPEGLSContractCodec()
        let source = try ContractImageLayerTests.filledImage(width: 8, height: 5)
        let ordinary = try codec.encode(source)
        let preferred = try codec.encode(source,
            options: EncodeOptions(executionPolicy: .preferred(.accelerated)))
        #expect(preferred.0 == ordinary.0)
        #expect(preferred.1.backend == .scalarCPU)
        #expect(preferred.1.fallbackReason?.isEmpty == false)
        #expect(ordinary.1.fallbackReason == nil)
        let decoded = try codec.decode(preferred.0,
            options: DecodeOptions(executionPolicy: .preferred(.accelerated)))
        #expect(decoded.1.backend == .scalarCPU)
        #expect(decoded.1.fallbackReason?.isEmpty == false)
        try expectSamples(decoded.0, matching: source)
        let scalar = try codec.decode(preferred.0,
            options: DecodeOptions(executionPolicy: .required(.scalarCPU)))
        #expect(scalar.1.fallbackReason == nil)
        try expectSamples(scalar.0, matching: source)
    }

    @Test func synchronousProgressRequestsRejectBeforeAnyCallbackOrWrite() throws {
        let codec = JPEGLSContractCodec()
        let source = try ContractImageLayerTests.filledImage(width: 8, height: 5)
        let payload = try codec.encode(source).0
        let progress: @Sendable (ProgressUpdate) -> Void = { _ in
            Issue.record("A rejected progress request must not invoke its callback")
        }
        expectError(.unsupportedFeature) {
            _ = try codec.encode(source, options: EncodeOptions(progress: progress))
        }
        let destination = try ImageDestination.allocate(descriptor: source.descriptor)
        expectError(.unsupportedFeature) {
            _ = try codec.decode(payload, into: destination, options: DecodeOptions(progress: progress))
        }
        try expectSamples(codec.decode(payload, into: destination).0, matching: source)
        expectError(.unsupportedFeature) {
            _ = try codec.decode(Data(), options: DecodeOptions(progress: progress))
        }
    }

    @Test(arguments: [2, 8, 12, 16])
    func everyAdvertisedPrecisionUsesTheSameInspectionAndDecodeLayout(bits: Int) throws {
        let source = try ContractImageLayerTests.filledImage(width: 8, height: 5, bits: bits)
        let codec = JPEGLSContractCodec()
        let payload = try codec.encode(source).0
        #expect(payload == (try ContractImageLayerTests.ordinaryCodestream(width: 8, height: 5, bits: bits)))
        let inspected = try codec.inspect(payload)
        #expect(inspected.meaningfulBits == bits)
        #expect(inspected.storageBits == 16)
        #expect(JPEGLSContractCodec.capabilities.meaningfulPrecision?.contains(bits) == true)
        let allocated = try codec.decode(payload).0
        let destination = try ImageDestination.allocate(descriptor: inspected)
        let provided = try codec.decode(payload, into: destination).0
        #expect(allocated.descriptor == inspected)
        #expect(provided.descriptor == inspected)
        try expectSamples(allocated, matching: source)
        try expectSamples(provided, matching: source)
    }

    @Test func preservingMetadataIsRejectedWhileExplicitAncillaryDiscardIsAccepted() throws {
        let source = try ContractImageLayerTests.filledImage(width: 8, height: 5)
        let annotated = try Image(descriptor: source.descriptor, storage: source.storage,
                                  metadata: ImageMetadata(entries: ["description": Data("sample".utf8)]))
        let profiled = try Image(descriptor: ImageDescriptor(width: 8, height: 5,
            planes: source.descriptor.planes, iccProfile: Data([1, 2, 3])), storage: source.storage)
        let codec = JPEGLSContractCodec()
        let plain = try codec.encode(source).0
        for image in [annotated, profiled] {
            expectError(.unsupportedFeature) { _ = try codec.encode(image) }
            let discarded = try codec.encode(image, options: EncodeOptions(metadataPolicy: .discardAncillary))
            #expect(discarded.0 == plain)
            try expectSamples(codec.decode(discarded.0).0, matching: source)
        }
    }

    @Test func requiredMetadataCannotBeDiscarded() throws {
        let source = try ContractImageLayerTests.filledImage(width: 8, height: 5)
        let image = try Image(descriptor: source.descriptor, storage: source.storage,
            metadata: ImageMetadata(entries: ["required": Data([42])], requiredKeys: ["required"]))
        for policy in [MetadataPolicy.preserve, .discardAncillary] {
            expectError(.unsupportedFeature) {
                _ = try JPEGLSContractCodec().encode(image, options: EncodeOptions(metadataPolicy: policy))
            }
        }
    }

    @Test(arguments: [UInt8(0xE1), UInt8(0xFE)])
    func compressedMetadataRequiresExplicitDiscardBeforeWriting(marker: UInt8) throws {
        let codec = JPEGLSContractCodec()
        let source = try ContractImageLayerTests.filledImage(width: 8, height: 5)
        let payload = inserting([0xFF, marker, 0, 4, 12, 34], into: try codec.encode(source).0)
        let destination = try ImageDestination.allocate(descriptor: source.descriptor)
        expectError(.unsupportedFeature) { _ = try codec.decode(payload, into: destination) }
        let image = try codec.decode(payload, into: destination,
                                     options: DecodeOptions(metadataPolicy: .discardAncillary)).0
        #expect(image.metadata == .empty)
        try expectSamples(image, matching: source)
        expectError(.unsupportedFeature) { _ = try codec.decode(payload) }
        try expectSamples(codec.decode(payload,
            options: DecodeOptions(metadataPolicy: .discardAncillary)).0, matching: source)
    }

    @Test func unsupportedSampleAndColourTransformsRejectBeforeWriting() throws {
        let codec = JPEGLSContractCodec()
        let source = try ContractImageLayerTests.filledImage(width: 8, height: 5)
        let payload = try codec.encode(source).0
        let bytes = [UInt8](payload)
        let sos = try #require((0..<(bytes.count - 1)).first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA })
        var pointTransform = bytes
        pointTransform[sos + 9] = 1
        var mapped = bytes
        mapped[sos + 6] = 1
        // APP8 mrfx identifies a required sample transform, not disposable metadata.
        let colourTransform = inserting([0xFF, 0xE8, 0, 7, 0x6D, 0x72, 0x66, 0x78, 1], into: payload)
        for transformed in [Data(pointTransform), Data(mapped), colourTransform] {
            let destination = try ImageDestination.allocate(descriptor: source.descriptor)
            expectError(.unsupportedFeature) {
                _ = try codec.decode(transformed, into: destination,
                                     options: DecodeOptions(metadataPolicy: .discardAncillary))
            }
            try expectSamples(codec.decode(payload, into: destination).0, matching: source)
        }
    }

    @Test func activeRestartSegmentationRejectsButAnIntervalCoveringTheImageDecodes() throws {
        let codec = JPEGLSContractCodec()
        let source = try ContractImageLayerTests.filledImage(width: 8, height: 5)
        let payload = try codec.encode(source).0
        let active = inserting([0xFF, 0xDD, 0, 4, 0, 2], into: payload)
        let destination = try ImageDestination.allocate(descriptor: source.descriptor)
        expectError(.unsupportedFeature) { _ = try codec.decode(active, into: destination) }
        for interval in [UInt8(5), UInt8(6)] {
            let inactive = inserting([0xFF, 0xDD, 0, 4, 0, interval], into: payload)
            try expectSamples(codec.decode(inactive).0, matching: source)
        }
        try expectSamples(codec.decode(payload, into: destination).0, matching: source)
    }

    @Test func presetMaximumOutsideFramePrecisionRejectsBeforeWriting() throws {
        let codec = JPEGLSContractCodec()
        let source = try ContractImageLayerTests.filledImage(width: 8, height: 5, bits: 8)
        let payload = try codec.encode(source).0
        // The LSE parameters are individually valid, but MAXVAL=256 cannot
        // describe an eight-bit frame. Parsing alone does not check this relation.
        let outsidePrecision = inserting(
            [0xFF, 0xF8, 0, 13, 1, 1, 0, 0, 3, 0, 7, 0, 21, 0, 64], into: payload)
        let parsed = try JPEGLSParser(data: outsidePrecision).parse()
        #expect(parsed.frameHeader.bitsPerSample == 8)
        #expect(parsed.presetParameters?.maxValue == 256)
        #expect(throws: JPEGLSError.self) { _ = try JPEGLSDecoder().decode(outsidePrecision) }
        let destination = try ImageDestination.allocate(descriptor: source.descriptor)
        expectError(.malformedInput) { _ = try codec.decode(outsidePrecision, into: destination) }
        expectError(.malformedInput) { _ = try codec.decode(outsidePrecision) }
        try expectSamples(codec.decode(payload, into: destination).0, matching: source)
    }

    @Test func strayRestartMarkersRejectBeforeWritingEvenWithoutAnActiveInterval() throws {
        let codec = JPEGLSContractCodec()
        let source = try ContractImageLayerTests.filledImage(width: 8, height: 5)
        let payload = try codec.encode(source).0
        let scan = try #require(JPEGLSParser(data: payload).parse().scanDataRanges.first)
        var corrupted = payload
        corrupted.insert(contentsOf: [0xFF, 0xD0], at: scan.lowerBound)
        for withRestart in [corrupted, inserting([0xFF, 0xDD, 0, 4, 0, 5], into: corrupted)] {
            let destination = try ImageDestination.allocate(descriptor: source.descriptor)
            expectError(.unsupportedFeature) { _ = try codec.decode(withRestart, into: destination) }
            try expectSamples(codec.decode(payload, into: destination).0, matching: source)
        }
    }
}
