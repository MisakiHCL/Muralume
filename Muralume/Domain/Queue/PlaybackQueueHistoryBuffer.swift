struct PlaybackQueueLocation<Item: Sendable>: Sendable {
    let item: Item
    let roundNumber: Int
    let position: Int
}

struct PlaybackQueueHistoryBuffer<Element: Sendable>: Sendable {
    private var storage: [Element?]
    private var startIndex = 0
    private(set) var count = 0

    var isEmpty: Bool {
        count == 0
    }

    var elements: [Element] {
        elements(in: 0..<count)
    }

    func suffixElements(maximumCount: Int) -> [Element] {
        guard maximumCount > 0 else {
            return []
        }
        let lowerBound = max(0, count - maximumCount)
        return elements(in: lowerBound..<count)
    }

    private func elements(in offsets: Range<Int>) -> [Element] {
        offsets.map { offset in
            guard let element = storage[storageIndex(for: offset)] else {
                preconditionFailure("History buffer storage is inconsistent")
            }
            return element
        }
    }

    var last: Element? {
        guard count > 0 else {
            return nil
        }
        return storage[storageIndex(for: count - 1)]
    }

#if DEBUG
    var storageIdentityForTesting: UInt {
        storage.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return 0
            }
            return UInt(bitPattern: baseAddress)
        }
    }
#endif

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        if count < storage.count {
            storage[storageIndex(for: count)] = element
            count += 1
            return
        }

        storage[startIndex] = element
        startIndex = (startIndex + 1) % storage.count
    }

    mutating func popLast() -> Element? {
        guard count > 0 else {
            return nil
        }

        let index = storageIndex(for: count - 1)
        let element = storage[index]
        storage[index] = nil
        count -= 1

        if count == 0 {
            startIndex = 0
        }
        return element
    }

    mutating func removeAll(
        where shouldRemove: (Element) -> Bool
    ) {
        let retainedElements = elements.filter {
            !shouldRemove($0)
        }
        replaceElements(with: retainedElements)
    }

    mutating func mapElements(
        _ transform: (Element) -> Element
    ) {
        replaceElements(with: elements.map(transform))
    }

    mutating func ensureCapacity(_ minimumCapacity: Int) {
        guard minimumCapacity > storage.count else {
            return
        }

        let retainedElements = elements
        storage = Array(repeating: nil, count: minimumCapacity)
        startIndex = 0
        count = 0
        for element in retainedElements {
            append(element)
        }
    }

    private mutating func replaceElements(with elements: [Element]) {
        storage = Array(repeating: nil, count: storage.count)
        startIndex = 0
        count = 0
        for element in elements {
            append(element)
        }
    }

    private func storageIndex(for offset: Int) -> Int {
        (startIndex + offset) % storage.count
    }
}
