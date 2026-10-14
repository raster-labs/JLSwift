/// JPEG-LS scan header per ITU-T.87
///
/// The scan header defines parameters for encoding/decoding a scan.
/// A scan contains one or more components encoded together.

import Foundation

/// JPEG-LS scan header
///
/// Encoded in the Start of Scan (SOS) marker segment.
public struct JPEGLSScanHeader: Sendable, Equatable {
    /// Number of components in this scan (1-4)
    public let componentCount: Int
    
    /// Component selectors for this scan
    public let components: [ComponentSelector]
    
    /// NEAR parameter for near-lossless mode (0 = lossless)
    public let near: Int
    
    /// Interleave mode for this scan
    public let interleaveMode: JPEGLSInterleaveMode
    
    /// Point transform (usually 0)
    public let pointTransform: Int
    
    /// Component selector within a scan
    public struct ComponentSelector: Sendable, Equatable {
        /// Component identifier (must match frame component ID)
        public let id: UInt8

        /// Mapping table ID referenced by this component (0 = no mapping table).
        ///
        /// When non-zero, decoded sample values for this component are treated as
        /// indices into the mapping table with this ID per ITU-T.87 §5.1.1.3.
        public let mappingTableID: UInt8

        /// Initialise a component selector.
        ///
        /// - Parameters:
        ///   - id: Component identifier.
        ///   - mappingTableID: Mapping table ID (0 = no mapping table).
        public init(id: UInt8, mappingTableID: UInt8 = 0) {
            self.id = id
            self.mappingTableID = mappingTableID
        }
    }
    
    /// Initialize scan header with validation
    ///
    /// - Parameters:
    ///   - componentCount: Number of components in scan
    ///   - components: Component selectors
    ///   - near: NEAR parameter (0 for lossless)
    ///   - interleaveMode: Component interleaving mode
    ///   - pointTransform: Point transform parameter
    /// - Throws: `JPEGLSError` if parameters are invalid
    public init(
        componentCount: Int,
        components: [ComponentSelector],
        near: Int,
        interleaveMode: JPEGLSInterleaveMode,
        pointTransform: Int = 0
    ) throws {
        if let failure = JPEGLSScanFields.validate(componentCount: componentCount, actualComponentCount: components.count,
            near: near, interleaveMode: interleaveMode, pointTransform: pointTransform) { throw failure.legacyError }
        self.componentCount = componentCount
        self.components = components
        self.near = near
        self.interleaveMode = interleaveMode
        self.pointTransform = pointTransform
    }
    
    internal init(validated fields: JPEGLSScanFields) {
        componentCount = fields.componentCount; components = fields.components.array
        near = fields.near; interleaveMode = fields.interleaveMode; pointTransform = fields.pointTransform
    }

    /// Create a scan header for grayscale lossless encoding
    ///
    /// - Returns: Scan header for single component lossless
    /// - Throws: `JPEGLSError` if parameters are invalid
    public static func grayscaleLossless() throws -> JPEGLSScanHeader {
        return try JPEGLSScanHeader(
            componentCount: 1,
            components: [ComponentSelector(id: 1)],
            near: 0,
            interleaveMode: .none
        )
    }
    
    /// Create a scan header for RGB lossless encoding with sample interleaving
    ///
    /// - Returns: Scan header for RGB lossless with sample interleaving
    /// - Throws: `JPEGLSError` if parameters are invalid
    public static func rgbLossless() throws -> JPEGLSScanHeader {
        return try JPEGLSScanHeader(
            componentCount: 3,
            components: [
                ComponentSelector(id: 1),  // R
                ComponentSelector(id: 2),  // G
                ComponentSelector(id: 3)   // B
            ],
            near: 0,
            interleaveMode: .sample
        )
    }
    
    /// Returns true if this scan is lossless (NEAR = 0)
    public var isLossless: Bool {
        return near == 0
    }
    
    /// Returns true if this scan is near-lossless (NEAR > 0)
    public var isNearLossless: Bool {
        return near > 0
    }
    
    /// Validate that this scan header is compatible with a frame header
    ///
    /// - Parameter frameHeader: Frame header to validate against
    /// - Throws: `JPEGLSError.parameterMismatch` if incompatible
    public func validate(against frameHeader: JPEGLSFrameHeader) throws {
        if let failure = JPEGLSScanFields(self).validate(against: JPEGLSFrameFields(frameHeader)) { throw failure.legacyError }
    }
}

extension JPEGLSScanHeader: CustomStringConvertible {
    /// Human-readable summary of scan header parameters
    public var description: String {
        let mode = isLossless ? "lossless" : "near-lossless(NEAR=\(near))"
        return "JPEGLSScanHeader(\(componentCount) components, \(interleaveMode), \(mode))"
    }
}
