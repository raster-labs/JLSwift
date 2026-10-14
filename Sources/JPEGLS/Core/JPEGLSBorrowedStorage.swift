// Storage policies for synchronous codec kernels. Borrowed pointers never escape
// a decoder call. Public legacy APIs retain Array value/copy-on-write semantics.
import Foundation

internal enum JPEGLSReadBytes {
    case owned([UInt8])
    case borrowed(UnsafeRawBufferPointer)
    init(data: Data) { self = .owned([UInt8](data)) }
    init(borrowing bytes: UnsafeRawBufferPointer) { self = .borrowed(bytes) }
    var isBorrowed: Bool { if case .borrowed = self { return true }; return false }
    var count: Int { switch self { case .owned(let b): return b.count; case .borrowed(let b): return b.count } }
    subscript(index: Int) -> UInt8 {
        switch self { case .owned(let b): return b[index]; case .borrowed(let b): return b[index] }
    }
    func copy(_ range: Range<Int>) -> Data {
        switch self { case .owned(let b): return Data(b[range]); case .borrowed(let b): return Data(b[range]) }
    }
}

/// Internal borrows are confined to one synchronous kernel; they are never
/// returned through a public context model. Owned storage preserves Array COW.
internal struct JPEGLSWorkingBuffer<Element: BitwiseCopyable & Sendable>: @unchecked Sendable {
    private var owned: [Element]?
    private let borrowed: UnsafeMutableBufferPointer<Element>?
    init(repeating value: Element, count: Int,
         borrowing pointer: UnsafeMutableBufferPointer<Element>? = nil) {
        if let pointer {
            precondition(pointer.count == count)
            pointer.initialize(repeating: value)
            owned = nil; borrowed = pointer
        } else {
            owned = Array(repeating: value, count: count); borrowed = nil
        }
    }
    subscript(index: Int) -> Element {
        get {
            if let borrowed { return borrowed[index] }
            return owned![index]
        }
        set {
            if let borrowed { borrowed[index] = newValue }
            else { owned![index] = newValue }
        }
    }
}
