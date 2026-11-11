import CAudioTap
import Foundation

// Values shared between an audio thread and everything else. Audio threads
// must never wait: these are plain atomic loads and stores.

final class AtomicInt: @unchecked Sendable {
    private let cell: OpaquePointer
    init(_ value: Int = 0) { cell = SSAtomicCellCreate(Int64(value)) }
    deinit { SSAtomicCellDestroy(cell) }
    var value: Int {
        get { Int(SSAtomicCellLoad(cell)) }
        set { SSAtomicCellStore(cell, Int64(newValue)) }
    }
    @discardableResult
    func add(_ delta: Int) -> Int { Int(SSAtomicCellAdd(cell, Int64(delta))) }
}

final class AtomicBool: @unchecked Sendable {
    private let cell: OpaquePointer
    init(_ value: Bool = false) { cell = SSAtomicCellCreate(value ? 1 : 0) }
    deinit { SSAtomicCellDestroy(cell) }
    var value: Bool {
        get { SSAtomicCellLoad(cell) != 0 }
        set { SSAtomicCellStore(cell, newValue ? 1 : 0) }
    }
}

final class AtomicFloat: @unchecked Sendable {
    private let cell: OpaquePointer
    init(_ value: Float = 0) { cell = SSAtomicCellCreate(Int64(value.bitPattern)) }
    deinit { SSAtomicCellDestroy(cell) }
    var value: Float {
        get { Float(bitPattern: UInt32(truncatingIfNeeded: SSAtomicCellLoad(cell))) }
        set { SSAtomicCellStore(cell, Int64(newValue.bitPattern)) }
    }
}
