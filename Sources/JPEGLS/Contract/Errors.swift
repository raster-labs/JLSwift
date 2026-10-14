// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster Images Private Limited

import Foundation

/// Stable categories shared by the independent suite modules.
public struct CodecError: Error, Sendable, Equatable {
    public enum Category: String, Sendable, CaseIterable {
        case invalidArgument, malformedInput, unsupportedFormat, unsupportedFeature
        case incompatibleImageLayout, resourceLimitExceeded, storageUnavailable
        case backendUnavailable, ioFailure, internalFailure
    }
    public let category: Category
    /// A fixed diagnostic, never sample bytes or caller metadata.
    public let message: String
    public init(_ category: Category, _ message: String) {
        self.category = category
        self.message = message
    }
}

func checkedAdd(_ a: Int, _ b: Int) throws -> Int {
    let (value, overflow) = a.addingReportingOverflow(b)
    guard !overflow else { throw CodecError(.invalidArgument, "Image arithmetic overflow.") }
    return value
}

func checkedMultiply(_ a: Int, _ b: Int) throws -> Int {
    let (value, overflow) = a.multipliedReportingOverflow(by: b)
    guard !overflow else { throw CodecError(.invalidArgument, "Image arithmetic overflow.") }
    return value
}
