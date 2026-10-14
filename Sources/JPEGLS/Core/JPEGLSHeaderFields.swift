// Fixed scalar header facts shared by both parser storage policies.
internal struct JPEGLSInline4<Element> {
    private var a: Element, b: Element, c: Element, d: Element
    private(set) var count = 0
    init(repeating value: Element) { a = value; b = value; c = value; d = value }
    mutating func append(_ value: Element) {
        precondition(count < 4)
        switch count { case 0: a = value; case 1: b = value; case 2: c = value; default: d = value }
        count += 1
    }
    subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count)
        switch index { case 0: return a; case 1: return b; case 2: return c; default: return d }
    }
    var array: [Element] { (0..<count).map { self[$0] } }
}
extension JPEGLSInline4 where Element == JPEGLSFrameHeader.ComponentSpec {
    func containsID(_ id: UInt8) -> Bool {
        for index in 0..<count where self[index].id == id { return true }; return false
    }
}
internal struct JPEGLSFrameFields {
    let bitsPerSample: Int, height: Int, width: Int, componentCount: Int
    let components: JPEGLSInline4<JPEGLSFrameHeader.ComponentSpec>
    init(bitsPerSample: Int, height: Int, width: Int, componentCount: Int,
         components: JPEGLSInline4<JPEGLSFrameHeader.ComponentSpec>) {
        self.bitsPerSample = bitsPerSample; self.height = height; self.width = width
        self.componentCount = componentCount; self.components = components
    }
    init(_ legacy: JPEGLSFrameHeader) {
        bitsPerSample = legacy.bitsPerSample; height = legacy.height; width = legacy.width
        componentCount = legacy.componentCount
        var storage = JPEGLSInline4(repeating: JPEGLSFrameHeader.ComponentSpec(id: 0))
        for component in legacy.components { storage.append(component) }; components = storage
    }
    static func validate(bitsPerSample: Int, height: Int, width: Int, componentCount: Int,
                         actualComponentCount: Int) -> JPEGLSManagedFailure? {

        // Validate bits per sample
        guard bitsPerSample >= 2 && bitsPerSample <= 16 else {
            return JPEGLSManagedFailure(.invalidBitsPerSample, bitsPerSample)
        }
        
        // Validate dimensions.
        // Standard JPEG-LS SOF supports up to 65535 per dimension; dimensions
        // greater than 65535 use LSE type 4 (extended dimensions) per ITU-T.87 §5.1.1.4.
        // Maximum supported dimension is 2^32 – 1 (32-bit LSE type 4 encoding).
        guard width > 0 && height > 0 else {
            return JPEGLSManagedFailure(.invalidDimensions, width, height)
        }
        
        guard width <= 0xFFFF_FFFF && height <= 0xFFFF_FFFF else {
            return JPEGLSManagedFailure(.invalidDimensions, width, height)
        }
        
        // Validate component count
        guard componentCount >= 1 && componentCount <= 4 else {
            return JPEGLSManagedFailure(.invalidComponentCount, componentCount)
        }
        
        // Validate components array matches count
        guard actualComponentCount == componentCount else {
            return JPEGLSManagedFailure(.frameComponentMismatch, componentCount, actualComponentCount)
        }
        
        return nil
    }
}
internal struct JPEGLSScanFields {
    let componentCount: Int, near: Int, pointTransform: Int
    let interleaveMode: JPEGLSInterleaveMode
    let components: JPEGLSInline4<JPEGLSScanHeader.ComponentSelector>
    init(componentCount: Int, components: JPEGLSInline4<JPEGLSScanHeader.ComponentSelector>,
         near: Int, interleaveMode: JPEGLSInterleaveMode, pointTransform: Int) {
        self.componentCount = componentCount; self.components = components
        self.near = near; self.interleaveMode = interleaveMode; self.pointTransform = pointTransform
    }
    init(_ legacy: JPEGLSScanHeader) {
        componentCount = legacy.componentCount; near = legacy.near; pointTransform = legacy.pointTransform
        interleaveMode = legacy.interleaveMode
        var storage = JPEGLSInline4(repeating: JPEGLSScanHeader.ComponentSelector(id: 0))
        for component in legacy.components { storage.append(component) }; components = storage
    }
    static func validate(componentCount: Int, actualComponentCount: Int, near: Int,
                         interleaveMode: JPEGLSInterleaveMode, pointTransform: Int) -> JPEGLSManagedFailure? {

        // Validate component count
        guard componentCount >= 1 && componentCount <= 4 else {
            return JPEGLSManagedFailure(.invalidComponentCount, componentCount)
        }
        
        // Validate components array matches count
        guard actualComponentCount == componentCount else {
            return JPEGLSManagedFailure(.scanComponentMismatch, componentCount, actualComponentCount)
        }
        
        // Validate NEAR parameter
        guard near >= 0 && near <= 255 else {
            return JPEGLSManagedFailure(.invalidNearParameter, near)
        }
        
        // Validate interleave mode for component count
        guard interleaveMode.isValid(forComponentCount: componentCount) else {
            return JPEGLSManagedFailure(.scanInterleave, Int(interleaveMode.rawValue), componentCount)
        }
        
        // Validate point transform
        guard pointTransform >= 0 && pointTransform <= 15 else {
            return JPEGLSManagedFailure(.pointTransform, pointTransform)
        }
        
        return nil
    }
    func validate(against frameHeader: JPEGLSFrameFields) -> JPEGLSManagedFailure? {

        // Check that all component IDs exist in frame
        for index in 0..<componentCount {
            let component = components[index]
            guard frameHeader.components.containsID(component.id) else {
                return JPEGLSManagedFailure(.unknownScanComponent, Int(component.id))
            }
        }
        
        // For non-interleaved mode, scan must have exactly 1 component
        if interleaveMode == .none && componentCount != 1 {
            return JPEGLSManagedFailure(.noninterleavedCount, componentCount)
        }
        
        // For interleaved modes, all frame components should be in scan
        if interleaveMode != .none && componentCount != frameHeader.componentCount {
            return JPEGLSManagedFailure(.interleavedCount, frameHeader.componentCount, componentCount)
        }
        return nil
    }
}
