// A string-keyed map that keeps insertion order.
//
// The web app iterates `Object.values(model.diagrams)` everywhere — to validate,
// to list occurrences, to write the file — so the order diagrams were added in
// is observable in its output. A Swift Dictionary would scramble it. Keys are
// told apart by code units, as a JavaScript property name is, not by Swift's
// canonical equivalence.

public struct OrderedMap<Value> {
    private var order: [String] = []
    private var storage: [JSStringKey: Value] = [:]

    public init() {}

    public var count: Int { order.count }
    public var isEmpty: Bool { order.isEmpty }
    public var keys: [String] { order }
    public var values: [Value] { order.map { storage[JSStringKey($0)]! } }

    public func contains(_ key: String) -> Bool { storage[JSStringKey(key)] != nil }

    /// Assigning a new key appends it; assigning an existing key keeps its
    /// place; assigning nil removes it — as with a JavaScript object property.
    public subscript(key: String) -> Value? {
        get { storage[JSStringKey(key)] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: JSStringKey(key)) == nil { order.append(key) }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> Value? {
        guard let old = storage.removeValue(forKey: JSStringKey(key)) else { return nil }
        order.removeAll { jsStrictEquals($0, key) }
        return old
    }
}

extension OrderedMap: Sequence {
    public func makeIterator() -> AnyIterator<(key: String, value: Value)> {
        var i = 0
        let order = self.order
        let storage = self.storage
        return AnyIterator {
            guard i < order.count else { return nil }
            defer { i += 1 }
            return (order[i], storage[JSStringKey(order[i])]!)
        }
    }
}

extension OrderedMap: Equatable where Value: Equatable {
    public static func == (a: OrderedMap, b: OrderedMap) -> Bool {
        a.order.elementsEqual(b.order, by: { jsStrictEquals($0, $1) }) && a.storage == b.storage
    }
}

extension OrderedMap: Hashable where Value: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(order)
        for key in order { hasher.combine(storage[JSStringKey(key)]!) }
    }
}

extension OrderedMap: Sendable where Value: Sendable {}
