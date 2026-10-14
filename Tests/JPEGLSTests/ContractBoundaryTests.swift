// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster Images Private Limited

import Foundation
import Testing
@testable import JPEGLS

/// Admission and ownership must fail before an invalid image can be published.
@Suite("Contract boundary and ownership")
struct ContractBoundaryTests {
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

    private func expectError(_ category: CodecError.Category,
                             _ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected codec error \(category)")
        } catch let error as CodecError {
            #expect(error.category == category)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func plane(width: Int = 2, height: Int = 2, components: [Int] = [0],
                       offset: Int = 0, sampleStride: Int = 2, pixelStride: Int = 2,
                       rowBytes: Int = 4, byteCount: Int = 8) throws -> PlaneDescriptor {
        try PlaneDescriptor(width: width, height: height, components: components, offset: offset,
                            sampleStride: sampleStride, pixelStride: pixelStride,
                            rowBytes: rowBytes, byteCount: byteCount)
    }

    @Test func resourceLimitsRejectNonPositiveAndNonFiniteBounds() throws {
        let invalid: [() throws -> ResourceLimits] = [
            { try ResourceLimits(maximumCompressedBytes: 0) },
            { try ResourceLimits(maximumDecodedBytes: -1) },
            { try ResourceLimits(maximumWorkspaceBytes: 0) },
            { try ResourceLimits(maximumPixels: 0) },
            { try ResourceLimits(maximumDimension: 0) },
            { try ResourceLimits(maximumFrames: 0) },
            { try ResourceLimits(maximumMetadataBytes: 0) },
            { try ResourceLimits(maximumICCBytes: 0) },
            { try ResourceLimits(maximumNestingDepth: 0) },
            { try ResourceLimits(maximumWorkers: 0) },
            { try ResourceLimits(deadlineSeconds: 0) },
            { try ResourceLimits(deadlineSeconds: .infinity) },
            { try ResourceLimits(deadlineSeconds: .nan) },
            { try ResourceLimits(maximumMemoryBytes: 0) }
        ]
        for make in invalid { expectError(.invalidArgument) { _ = try make() } }
        let tight = try ResourceLimits(maximumCompressedBytes: 1, maximumDecodedBytes: 1,
            maximumWorkspaceBytes: 1, maximumPixels: 1, maximumDimension: 1, maximumFrames: 1,
            maximumMetadataBytes: 1, maximumICCBytes: 1, maximumNestingDepth: 1,
            maximumWorkers: 1, deadlineSeconds: 0.001, maximumMemoryBytes: 1)
        _ = try OwnedImageStorage(byteCount: 1, limits: tight)
        #expect(ResourceLimits.watch.maximumMemoryBytes < ResourceLimits.general.maximumMemoryBytes)
    }

    @Test func planeGeometryAndMappingsMustBeValid() {
        let invalid: [() throws -> PlaneDescriptor] = [
            { try plane(width: 0) }, { try plane(height: 0) }, { try plane(offset: -1) },
            { try plane(sampleStride: 0) }, { try plane(pixelStride: 0) },
            { try plane(rowBytes: 0) }, { try plane(byteCount: 0) },
            { try plane(components: []) }, { try plane(components: [-1]) },
            { try plane(components: [0, 0]) }
        ]
        for make in invalid { expectError(.invalidArgument) { _ = try make() } }
    }

    @Test func descriptorRejectsInvalidDimensionsPrecisionAndColourMeaning() throws {
        let p = try plane()
        expectError(.invalidArgument) { _ = try ImageDescriptor(width: 0, height: 2, planes: [p]) }
        expectError(.invalidArgument) { _ = try ImageDescriptor(width: 2, height: 2, planes: []) }
        expectError(.invalidArgument) {
            _ = try ImageDescriptor(width: 2, height: 2, components: [], planes: [p])
        }
        for (storage, meaningful) in [(24, 16), (16, 0), (16, 17)] {
            expectError(.invalidArgument) {
                _ = try ImageDescriptor(width: 2, height: 2, storageBits: storage,
                                        meaningfulBits: meaningful, planes: [p])
            }
        }
        expectError(.invalidArgument) {
            _ = try ImageDescriptor(width: 2, height: 2, sampleType: .floatingPoint, planes: [p])
        }
        expectError(.invalidArgument) {
            _ = try ImageDescriptor(width: 2, height: 2, components: [.red], planes: [p])
        }
        expectError(.invalidArgument) {
            _ = try ImageDescriptor(width: 2, height: 2, colour: .rgb, planes: [p])
        }
        expectError(.invalidArgument) {
            _ = try ImageDescriptor(width: 2, height: 2, alpha: .straight, planes: [p])
        }
        expectError(.invalidArgument) {
            _ = try ImageDescriptor(width: 2, height: 2, components: [.alpha],
                                    colour: .unknown, planes: [p])
        }
    }

    @Test func descriptorChecksEveryAdmissionCeilingWithoutAllocating() throws {
        let p = try plane()
        for limits in [try ResourceLimits(maximumDimension: 1),
                       try ResourceLimits(maximumPixels: 3),
                       try ResourceLimits(maximumDecodedBytes: 7)] {
            expectError(.resourceLimitExceeded) {
                _ = try ImageDescriptor(width: 2, height: 2, planes: [p], limits: limits)
            }
        }
        expectError(.resourceLimitExceeded) {
            _ = try ImageDescriptor(width: 2, height: 2, planes: [p], iccProfile: Data([1, 2]),
                                    limits: ResourceLimits(maximumICCBytes: 1))
        }
        let unboundedDimensions = try ResourceLimits(maximumPixels: .max, maximumDimension: .max)
        expectError(.invalidArgument) {
            _ = try ImageDescriptor(width: .max, height: 2, planes: [p], limits: unboundedDimensions)
        }
        expectError(.invalidArgument) {
            _ = try ImageDescriptor.greyscale16(width: .max, height: 1, limits: unboundedDimensions)
        }
        expectError(.invalidArgument) {
            _ = try ImageDescriptor.greyscale16(width: 1, height: 1, offset: .max)
        }
        expectError(.invalidArgument) { _ = try ImageDescriptor.greyscale16(width: -1, height: 1) }
    }

    @Test func descriptorRejectsOverlappingMisalignedAndIncompletePlanes() throws {
        for p in [try plane(offset: 1, byteCount: 10), try plane(sampleStride: 3),
                  try plane(pixelStride: 3, rowBytes: 6, byteCount: 12),
                  try plane(rowBytes: 5, byteCount: 10), try plane(rowBytes: 2),
                  try plane(byteCount: 7)] {
            expectError(.incompatibleImageLayout) {
                _ = try ImageDescriptor(width: 2, height: 2, planes: [p])
            }
        }
        expectError(.unsupportedFeature) {
            _ = try ImageDescriptor(width: 2, height: 2, planes: [plane(width: 1)])
        }
        expectError(.invalidArgument) {
            _ = try ImageDescriptor(width: 2, height: 2, planes: [plane(components: [1])])
        }
        let roles: [ComponentRole] = [.grey, .uninterpreted("auxiliary")]
        expectError(.invalidArgument) {
            _ = try ImageDescriptor(width: 2, height: 2, components: roles, planes: [plane()])
        }
        expectError(.invalidArgument) {
            _ = try ImageDescriptor(width: 2, height: 2, components: roles,
                planes: [plane(), plane(offset: 8, byteCount: 16)])
        }
        expectError(.incompatibleImageLayout) {
            _ = try ImageDescriptor(width: 2, height: 2, components: roles,
                planes: [plane(components: [0, 1])])
        }
        expectError(.incompatibleImageLayout) {
            _ = try ImageDescriptor(width: 2, height: 2, components: roles,
                planes: [plane(), plane(components: [1])])
        }
    }

    @Test func descriptorSupportsPlanarColourAndExplicitNativeByteOrder() throws {
        let rgb = try ImageDescriptor(width: 2, height: 2,
            components: [.red, .green, .blue], colour: .rgb,
            planes: [plane(), plane(components: [1], offset: 8, byteCount: 16),
                     plane(components: [2], offset: 16, byteCount: 24)])
        #expect(rgb.requiredByteCount == 24)
        let floating = try ImageDescriptor(width: 1, height: 1, sampleType: .floatingPoint,
            storageBits: 32, meaningfulBits: 32, byteOrder: .native,
            components: [.uninterpreted("depth")], colour: .unknown,
            planes: [plane(width: 1, height: 1, sampleStride: 4,
                           pixelStride: 4, rowBytes: 4, byteCount: 4)])
        #expect(floating.byteOrder == (UInt16(littleEndian: 1) == 1 ? .littleEndian : .bigEndian))
        let alpha = try ImageDescriptor(width: 1, height: 1, components: [.grey, .alpha],
            alpha: .premultiplied, planes: [plane(width: 1, height: 1, components: [0, 1],
                                                  pixelStride: 4, rowBytes: 4, byteCount: 4)])
        #expect(alpha.requiredByteCount == 4)
    }

    @Test func metadataRequiresValuesAndCountsUTF8KeysAndICCInTheBudget() throws {
        let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
        let source = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 7 }
        expectError(.invalidArgument) {
            _ = try Image(descriptor: descriptor, storage: source.storage,
                          metadata: ImageMetadata(requiredKeys: ["missing"]))
        }
        let metadata = ImageMetadata(entries: ["é": Data([42])], requiredKeys: ["é"])
        let image = try Image(descriptor: descriptor, storage: source.storage, metadata: metadata,
                              limits: ResourceLimits(maximumMetadataBytes: 3, maximumMemoryBytes: 5))
        #expect(image.metadata == metadata)
        expectError(.resourceLimitExceeded) {
            _ = try Image(descriptor: descriptor, storage: source.storage, metadata: metadata,
                          limits: ResourceLimits(maximumMetadataBytes: 2))
        }
        expectError(.resourceLimitExceeded) {
            _ = try Image(descriptor: descriptor, storage: source.storage, metadata: metadata,
                          limits: ResourceLimits(maximumMemoryBytes: 4))
        }
        let withICC = try ImageDescriptor(width: 1, height: 1,
            planes: [plane(width: 1, height: 1, rowBytes: 2, byteCount: 2)], iccProfile: Data([1, 2]))
        expectError(.resourceLimitExceeded) {
            _ = try Image(descriptor: withICC, storage: source.storage,
                          limits: ResourceLimits(maximumMetadataBytes: 1))
        }
        expectError(.resourceLimitExceeded) {
            _ = try Image(descriptor: withICC, storage: source.storage, metadata: metadata,
                          limits: ResourceLimits(maximumMetadataBytes: 4))
        }
    }

    @Test func imageAndDestinationCheckProviderCapacityBeforeUse() throws {
        let descriptor = try ImageDescriptor.greyscale16(width: 2, height: 2)
        expectError(.incompatibleImageLayout) {
            _ = try Image(descriptor: descriptor, storage: ReadProvider(reported: 6, actual: 6))
        }
        expectError(.storageUnavailable) {
            _ = try Image(descriptor: descriptor, storage: ReadProvider(reported: 8, actual: 6))
        }
        expectError(.storageUnavailable) {
            _ = try Image(descriptor: descriptor, storage: ReadProvider(reported: 8, actual: 10))
        }
        let small = try OwnedImageStorage(byteCount: 6)
        expectError(.incompatibleImageLayout) {
            _ = try ImageDestination(descriptor: descriptor, storage: small)
        }
        // Rejection must precede taking a provider's lease.
        let lease = try small.reserveWrite()
        try small.abortAndInvalidate(lease: lease)
        let larger = try OwnedImageStorage(byteCount: 10)
        expectError(.resourceLimitExceeded) {
            _ = try ImageDestination(descriptor: descriptor, storage: larger,
                                     limits: ResourceLimits(maximumMemoryBytes: 9))
        }
        expectError(.resourceLimitExceeded) {
            _ = try ImageDestination.allocate(descriptor: descriptor,
                                              limits: ResourceLimits(maximumMemoryBytes: 7))
        }
        for size in [0, -1] {
            expectError(.invalidArgument) { _ = try OwnedImageStorage(byteCount: size) }
        }
        expectError(.resourceLimitExceeded) {
            _ = try OwnedImageStorage(byteCount: 8, limits: ResourceLimits(maximumDecodedBytes: 7))
        }
    }

    @Test func storageRejectsForeignReentrantAndRetiredLeases() throws {
        let storage = try OwnedImageStorage(byteCount: 8)
        let lease = try storage.reserveWrite()
        let foreign = StorageWriteLease()
        #expect(lease != foreign)
        expectError(.storageUnavailable) { _ = try storage.reserveWrite() }
        expectError(.storageUnavailable) { try storage.withUnsafeMutableBytes(lease: foreign) { _ in } }
        expectError(.storageUnavailable) { _ = try storage.finishAndSeal(lease: foreign) }
        expectError(.storageUnavailable) { try storage.abortAndInvalidate(lease: foreign) }
        try storage.withUnsafeMutableBytes(lease: lease) { bytes in
            #expect(bytes.allSatisfy { $0 == 0 })
            bytes[0] = 42
            expectError(.storageUnavailable) { _ = try storage.reserveWrite() }
            expectError(.storageUnavailable) { try storage.withUnsafeMutableBytes(lease: lease) { _ in } }
            expectError(.storageUnavailable) { _ = try storage.finishAndSeal(lease: lease) }
            expectError(.storageUnavailable) { try storage.abortAndInvalidate(lease: lease) }
        }
        let sealed = try storage.finishAndSeal(lease: lease)
        #expect(sealed.allocationID == storage.allocationID)
        #expect(try sealed.withUnsafeBytes { $0[0] } == 42)
        expectError(.storageUnavailable) { try storage.withUnsafeMutableBytes(lease: lease) { _ in } }
        expectError(.storageUnavailable) { try storage.abortAndInvalidate(lease: lease) }
        expectError(.storageUnavailable) { _ = try storage.reserveWrite() }
    }

    @Test func abortAndAbandonmentPreventReusingPartialStorage() throws {
        let storage = try OwnedImageStorage(byteCount: 8)
        let lease = try storage.reserveWrite()
        try storage.abortAndInvalidate(lease: lease)
        expectError(.storageUnavailable) { _ = try storage.reserveWrite() }
        expectError(.storageUnavailable) { _ = try storage.finishAndSeal(lease: lease) }
        let abandoned = try OwnedImageStorage(byteCount: 8)
        do {
            let destination = try ImageDestination(
                descriptor: ImageDescriptor.greyscale16(width: 2, height: 2), storage: abandoned)
            #expect(destination.storage.allocationID == abandoned.allocationID)
        }
        expectError(.storageUnavailable) { _ = try abandoned.reserveWrite() }
    }

    @Test func sealedImagesRetainTheirStorageAfterDestinationDestruction() throws {
        let image: Image = try {
            let destination = try ImageDestination.allocate(
                descriptor: ImageDescriptor.greyscale16(width: 2, height: 2))
            return try destination.writeUInt16 { x, y in UInt16(100 + x + y * 2) }
        }()
        #expect(try image.sampleUInt16(x: 1, y: 1) == 103)
        for (x, y) in [(-1, 0), (0, -1), (2, 0), (0, 2)] {
            expectError(.invalidArgument) { _ = try image.sampleUInt16(x: x, y: y) }
        }
    }

    @Test func failedSampleInitializationCannotPublishOrRetry() throws {
        let destination = try ImageDestination.allocate(
            descriptor: ImageDescriptor.greyscale16(width: 2, height: 2, meaningfulBits: 12))
        expectError(.invalidArgument) {
            _ = try destination.writeUInt16 { x, y in x == 1 && y == 1 ? 4096 : 4095 }
        }
        expectError(.storageUnavailable) { _ = try destination.writeUInt16 { _, _ in 0 } }
        enum FillFailure: Error { case injected }
        let throwing = try ImageDestination.allocate(
            descriptor: ImageDescriptor.greyscale16(width: 1, height: 1))
        #expect(throws: FillFailure.self) { _ = try throwing.write { _ in throw FillFailure.injected } }
        expectError(.storageUnavailable) { _ = try throwing.storage.reserveWrite() }
    }

    @Test func byteOrderHelpersPreserveSamplesAndPadding() throws {
        for order in [ByteOrder.littleEndian, .bigEndian] {
            let descriptor = try ImageDescriptor(width: 2, height: 2, byteOrder: order,
                planes: [plane(offset: 2, rowBytes: 6, byteCount: 14)])
            let image = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { x, y in
                UInt16(0x1234 + x + 2 * y)
            }
            #expect(try image.sampleUInt16(x: 1, y: 1) == 0x1237)
            try image.storage.withUnsafeBytes { bytes in
                #expect(bytes[0] == 0 && bytes[1] == 0 && bytes[6] == 0 && bytes[7] == 0)
                #expect(bytes[2] == (order == .littleEndian ? 0x34 : 0x12))
                #expect(bytes[3] == (order == .littleEndian ? 0x12 : 0x34))
            }
        }
    }

    @Test func unsupportedSampleHelperDoesNotConsumeTheDestination() throws {
        let descriptor = try ImageDescriptor(width: 1, height: 1, storageBits: 8, meaningfulBits: 8,
            planes: [plane(width: 1, height: 1, sampleStride: 1, pixelStride: 1, rowBytes: 1, byteCount: 1)])
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        expectError(.unsupportedFeature) { _ = try destination.writeUInt16 { _, _ in 12 } }
        let image = try destination.write { $0[0] = 12 }
        expectError(.unsupportedFeature) { _ = try image.sampleUInt16(x: 0, y: 0) }
    }

    @Test func cancellationDuringFillPreventsPublication() async throws {
        let destination = try ImageDestination.allocate(
            descriptor: ImageDescriptor.greyscale16(width: 2, height: 2))
        let cancelled = await Task {
            do {
                _ = try destination.writeUInt16 { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 1
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        #expect(cancelled)
        expectError(.storageUnavailable) { _ = try destination.storage.reserveWrite() }
    }

    @Test func slicedCodestreamUsesTheSameByteOriginForParsingAndDecoding() throws {
        let payload = try ContractImageLayerTests.ordinaryCodestream(width: 6, height: 4)
        var sliced = Data(repeating: 0x5A, count: 13)
        sliced.append(payload)
        sliced.removeFirst(13)
        #expect(sliced.startIndex == 13)
        let codec = JPEGLSContractCodec()
        let expected = try codec.decode(payload).0
        let allocated = try codec.decode(sliced).0
        let destination = try ImageDestination.allocate(descriptor: expected.descriptor)
        let provided = try codec.decode(sliced, into: destination).0
        for y in 0..<4 {
            for x in 0..<6 {
                let sample = try expected.sampleUInt16(x: x, y: y)
                #expect(try allocated.sampleUInt16(x: x, y: y) == sample)
                #expect(try provided.sampleUInt16(x: x, y: y) == sample)
            }
        }
    }

    @Test func stricterDecodeOperationLimitsRejectBeforeUsingTheDestination() throws {
        let payload = try ContractImageLayerTests.ordinaryCodestream(width: 6, height: 4)
        let descriptor = try ImageDescriptor.greyscale16(width: 6, height: 4)
        let codec = JPEGLSContractCodec()
        for limits in [try ResourceLimits(maximumDecodedBytes: 47),
                       try ResourceLimits(maximumPixels: 23),
                       try ResourceLimits(maximumDimension: 5)] {
            let destination = try ImageDestination.allocate(descriptor: descriptor)
            expectError(.resourceLimitExceeded) {
                _ = try codec.decode(payload, into: destination,
                                     options: DecodeOptions(resourceLimits: limits))
            }
            let decoded = try codec.decode(payload, into: destination).0
            #expect(try decoded.sampleUInt16(x: 5, y: 3) == ContractImageLayerTests.sample(5, 3))
        }
    }

    @Test func progressAndCopyReportsRejectImpossibleCounts() throws {
        expectError(.invalidArgument) { _ = try ProgressUpdate(phase: .processing, completedUnits: -1) }
        expectError(.invalidArgument) {
            _ = try ProgressUpdate(phase: .completed, completedUnits: 2, totalUnits: 1)
        }
        #expect(try ProgressUpdate(phase: .completed, completedUnits: 2, totalUnits: 2).totalUnits == 2)
        #expect(try ProgressUpdate(phase: .processing, completedUnits: 1).totalUnits == nil)
        expectError(.invalidArgument) {
            _ = try CopyEvent(reason: "layout conversion", bytesMoved: -1,
                              sourceLayout: "big endian", destinationLayout: "little endian")
        }
        let event = try CopyEvent(reason: "layout conversion", bytesMoved: 8,
                                  sourceLayout: "big endian", destinationLayout: "little endian")
        let report = OperationReport(backend: .scalarCPU, fallbackReason: "Accelerator unavailable",
            fidelity: .exactSamples, copyEvents: [event], pixelAllocationCount: 1,
            peakPixelBytes: 8, peakWorkspaceBytes: 16, elapsedSeconds: 0.01)
        #expect(report.copyEvents == [event])
        #expect(report.fidelity == .exactSamples)
    }

    @Test func unavailableGenericCodecsRejectWithoutConsumingDestinations() async throws {
        let encoder = try Encoder()
        let decoder = try Decoder()
        #expect(!encoder.capabilities.canEncode)
        #expect(!decoder.capabilities.canDecode && !decoder.capabilities.canInspect)
        for mode in [CompressionMode.nearLossless(maximumAbsoluteError: 0),
                                      .nearLossless(maximumAbsoluteError: -1)] {
            expectError(.invalidArgument) { _ = try EncoderConfiguration(mode: mode) }
        }
        for mode in [CompressionMode.lossy, .nearLossless(maximumAbsoluteError: 1)] {
            expectError(.unsupportedFeature) { _ = try EncoderConfiguration(mode: mode) }
        }
        let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
        let image = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 42 }
        await expectError(.unsupportedFeature) { _ = try await encoder.encode(image) }
        await expectError(.backendUnavailable) {
            _ = try await encoder.encode(image, options: EncodeOptions(executionPolicy: .required(.accelerated)))
        }
        await expectError(.resourceLimitExceeded) {
            _ = try await encoder.encode(image, options: EncodeOptions(
                resourceLimits: ResourceLimits(maximumMemoryBytes: 1)))
        }
        expectError(.unsupportedFeature) { _ = try decoder.inspect(Data()) }
        expectError(.backendUnavailable) {
            _ = try decoder.inspect(Data(), options: DecodeOptions(executionPolicy: .required(.accelerated)))
        }
        expectError(.resourceLimitExceeded) {
            _ = try decoder.inspect(Data([1, 2]), options: DecodeOptions(
                resourceLimits: ResourceLimits(maximumCompressedBytes: 1)))
        }
        await expectError(.unsupportedFeature) { _ = try await decoder.decode(Data()) }
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        await expectError(.unsupportedFeature) { _ = try await decoder.decode(Data(), into: destination) }
        #expect(try destination.writeUInt16 { _, _ in 7 }.sampleUInt16(x: 0, y: 0) == 7)
    }
}

/// Models a misbehaving external provider without exposing or escaping pointers.
private struct ReadProvider: ReadOnlyImageStorage {
    let byteCount: Int
    let allocationID = UUID()
    private let bytes: [UInt8]
    init(reported: Int, actual: Int) {
        byteCount = reported
        bytes = [UInt8](repeating: 0, count: actual)
    }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try bytes.withUnsafeBytes(body)
    }
}
