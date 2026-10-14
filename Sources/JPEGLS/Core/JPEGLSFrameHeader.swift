/// Interleave mode for multi-component JPEG-LS images
///
/// Defines how multiple colour components are arranged in the encoded bitstream.

import Foundation

/// Component interleave mode
///
/// JPEG-LS supports three interleaving modes for multi-component images.
/// The choice affects compression efficiency and decoding complexity.
public enum JPEGLSInterleaveMode: UInt8, Sendable, Equatable {
    /// No interleaving - components are encoded separately in order
    /// Each component has its own scan. Best for independent components.
    case none = 0
    
    /// Line-interleaved mode - components alternate by scan line
    /// Better cache locality than no interleaving.
    case line = 1
    
    /// Sample-interleaved mode - components alternate by sample (pixel)
    /// Best compression for correlated components (e.g., RGB).
    case sample = 2
    
    /// Returns true if this mode is valid for the given component count
    ///
    /// - Parameter componentCount: Number of image components
    /// - Returns: True if interleave mode is valid
    public func isValid(forComponentCount componentCount: Int) -> Bool {
        switch self {
        case .none:
            // No interleaving is always valid
            return true
        case .line, .sample:
            // Interleaving requires multiple components
            return componentCount > 1
        }
    }
}

extension JPEGLSInterleaveMode: CustomStringConvertible {
    /// Human-readable name of the interleave mode
    public var description: String {
        switch self {
        case .none:
            return "None"
        case .line:
            return "Line"
        case .sample:
            return "Sample"
        }
    }
}

/// JPEG-LS frame header per ITU-T.87
///
/// Contains fundamental image parameters that apply to the entire frame.
/// This information is encoded in the Start of Frame (SOF) marker segment.
public struct JPEGLSFrameHeader: Sendable, Equatable {
    /// Precision (bits per sample) - valid range: 2-16
    public let bitsPerSample: Int
    
    /// Image height in pixels - valid range: 1–65535 in standard SOF; up to 2^32–1 with LSE type 4
    public let height: Int
    
    /// Image width in pixels - valid range: 1–65535 in standard SOF; up to 2^32–1 with LSE type 4
    public let width: Int
    
    /// Number of components - valid range: 1-4 for baseline JPEG-LS
    public let componentCount: Int
    
    /// Component specifications (one per component)
    public let components: [ComponentSpec]
    
    /// Component specification within a frame
    public struct ComponentSpec: Sendable, Equatable {
        /// Component identifier (typically 1, 2, 3, ...)
        public let id: UInt8
        
        /// Horizontal sampling factor (usually 1)
        public let horizontalSamplingFactor: UInt8
        
        /// Vertical sampling factor (usually 1)
        public let verticalSamplingFactor: UInt8
        
        /// Initialize component specification
        ///
        /// - Parameters:
        ///   - id: Component identifier
        ///   - horizontalSamplingFactor: Horizontal sampling factor (default: 1)
        ///   - verticalSamplingFactor: Vertical sampling factor (default: 1)
        public init(
            id: UInt8,
            horizontalSamplingFactor: UInt8 = 1,
            verticalSamplingFactor: UInt8 = 1
        ) {
            self.id = id
            self.horizontalSamplingFactor = horizontalSamplingFactor
            self.verticalSamplingFactor = verticalSamplingFactor
        }
    }
    
    /// Initialize frame header with validation
    ///
    /// - Parameters:
    ///   - bitsPerSample: Precision in bits per sample
    ///   - height: Image height in pixels
    ///   - width: Image width in pixels
    ///   - componentCount: Number of image components
    ///   - components: Component specifications
    /// - Throws: `JPEGLSError` if parameters are invalid
    public init(
        bitsPerSample: Int,
        height: Int,
        width: Int,
        componentCount: Int,
        components: [ComponentSpec]
    ) throws {
        if let failure = JPEGLSFrameFields.validate(bitsPerSample: bitsPerSample, height: height, width: width,
            componentCount: componentCount, actualComponentCount: components.count) { throw failure.legacyError }
        self.bitsPerSample = bitsPerSample
        self.height = height
        self.width = width
        self.componentCount = componentCount
        self.components = components
    }
    
    internal init(validated fields: JPEGLSFrameFields) {
        bitsPerSample = fields.bitsPerSample; height = fields.height; width = fields.width
        componentCount = fields.componentCount; components = fields.components.array
    }

    /// Create a frame header for a grayscale image
    ///
    /// - Parameters:
    ///   - bitsPerSample: Bits per sample (2-16)
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: Frame header for grayscale image
    /// - Throws: `JPEGLSError` if parameters are invalid
    public static func grayscale(
        bitsPerSample: Int,
        width: Int,
        height: Int
    ) throws -> JPEGLSFrameHeader {
        return try JPEGLSFrameHeader(
            bitsPerSample: bitsPerSample,
            height: height,
            width: width,
            componentCount: 1,
            components: [ComponentSpec(id: 1)]
        )
    }
    
    /// Create a frame header for an RGB image
    ///
    /// - Parameters:
    ///   - bitsPerSample: Bits per sample (2-16)
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: Frame header for RGB image
    /// - Throws: `JPEGLSError` if parameters are invalid
    public static func rgb(
        bitsPerSample: Int,
        width: Int,
        height: Int
    ) throws -> JPEGLSFrameHeader {
        return try JPEGLSFrameHeader(
            bitsPerSample: bitsPerSample,
            height: height,
            width: width,
            componentCount: 3,
            components: [
                ComponentSpec(id: 1),  // R
                ComponentSpec(id: 2),  // G
                ComponentSpec(id: 3)   // B
            ]
        )
    }
}

extension JPEGLSFrameHeader: CustomStringConvertible {
    /// Human-readable summary of frame header parameters
    public var description: String {
        return "JPEGLSFrameHeader(\(width)×\(height), \(bitsPerSample) bps, \(componentCount) components)"
    }
}
