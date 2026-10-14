// Storage policies for synchronous codec kernels. Borrowed pointers never escape
// a decoder call. Public legacy APIs retain Array value/copy-on-write semantics.
import Foundation

internal struct JPEGLSReadBytes {
    private let owned: [UInt8]
    private let borrowed: UnsafeRawBufferPointer?
    init(data: Data) { owned = [UInt8](data); borrowed = nil }
    init(borrowing bytes: UnsafeRawBufferPointer) { owned = []; borrowed = bytes }
    var isBorrowed: Bool { borrowed != nil }
    var count: Int { borrowed?.count ?? owned.count }
    subscript(index: Int) -> UInt8 {
        if let borrowed { return borrowed[index] }
        return owned[index]
    }
    func copy(_ range: Range<Int>) -> Data {
        if let borrowed { return Data(borrowed[range]) }
        return Data(owned[range])
    }
}

/// Internal borrows are confined to one synchronous kernel; they are never
/// returned through a public context model. Owned storage preserves Array COW.
internal struct JPEGLSWorkingBuffer<Element: BitwiseCopyable & Sendable>: @unchecked Sendable {
    private var owned: [Element]
    private let borrowed: UnsafeMutableBufferPointer<Element>?
    init(repeating value: Element, count: Int,
         borrowing pointer: UnsafeMutableBufferPointer<Element>? = nil) {
        if let pointer {
            precondition(pointer.count == count)
            pointer.initialize(repeating: value)
            owned = []; borrowed = pointer
        } else {
            owned = Array(repeating: value, count: count); borrowed = nil
        }
    }
    subscript(index: Int) -> Element {
        get {
            if let borrowed { return borrowed[index] }
            return owned[index]
        }
        set {
            if let borrowed { borrowed[index] = newValue }
            else { owned[index] = newValue }
        }
    }
}
