import Foundation
import Observation
import SwiftData

/// App-wide list of cue types (timeline lanes / export groups), kept as JSON in UserDefaults.
/// A point with a nil or unknown `typeID` belongs to `CuePointType.defaultID`, which always exists.
@Observable
final class CuePointTypeStore {
    static let shared = CuePointTypeStore()
    static let key = "cuePoints.types"

    private(set) var types: [CuePointType]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([CuePointType].self, from: data), !saved.isEmpty {
            types = Self.ensuringDefault(saved)
        } else {
            // Save straight away: the built-in types other than the default get fresh ids each
            // launch, so points tagged with them would be orphaned if the seed weren't stored.
            types = CuePointType.defaults
            persist()
        }
    }

    var visible: [CuePointType] { types.filter { !$0.hidden } }

    /// The type a point belongs to (nil / deleted type → the default type).
    func type(for id: UUID?) -> CuePointType {
        if let id, let t = types.first(where: { $0.id == id }) { return t }
        return types.first(where: { $0.id == CuePointType.defaultID }) ?? CuePointType.defaults[0]
    }

    /// Resolved id: nil or unknown ids map to the default type.
    func resolvedID(_ id: UUID?) -> UUID { type(for: id).id }

    // MARK: Editing

    @discardableResult
    func add(name: String? = nil, colorHex: String? = nil) -> CuePointType {
        let palette = CuePointColor.allCases.map(\.rawValue)
        let colour = colorHex ?? palette.first(where: { c in !types.contains(where: { $0.colorHex == c }) }) ?? palette[types.count % palette.count]
        let t = CuePointType(name: uniqueName(name ?? "Type \(types.count + 1)"), colorHex: colour,
                             ma3Sequence: (types.map(\.ma3Sequence).max() ?? 0) + 1)
        types.append(t); persist()
        return t
    }

    func rename(_ id: UUID, to name: String) { update(id) { $0.name = name } }
    func recolour(_ id: UUID, to hex: String) { update(id) { $0.colorHex = hex } }
    func setHidden(_ id: UUID, _ on: Bool) { update(id) { $0.hidden = on } }
    func setLocked(_ id: UUID, _ on: Bool) { update(id) { $0.locked = on } }
    func setSequence(_ id: UUID, _ n: Int) { update(id) { $0.ma3Sequence = max(0, n) } }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        var t = types
        // IndexSet move without SwiftUI's helper (keeps this file UI-free).
        let moving = fromOffsets.map { t[$0] }
        let before = fromOffsets.filter { $0 < toOffset }.count
        for i in fromOffsets.sorted(by: >) { t.remove(at: i) }
        t.insert(contentsOf: moving, at: max(0, min(t.count, toOffset - before)))
        types = t; persist()
    }

    /// Removes a type. Its points (in every track) move to the default type. The default type stays.
    func delete(_ id: UUID, context: ModelContext?) {
        guard id != CuePointType.defaultID, types.contains(where: { $0.id == id }) else { return }
        if let context {
            let target: UUID? = id
            let d = FetchDescriptor<CuePoint>(predicate: #Predicate { $0.typeID == target })
            for p in (try? context.fetch(d)) ?? [] { p.typeID = nil }
            try? context.save()
        }
        types.removeAll { $0.id == id }
        persist()
    }

    /// Back to the four built-in types (points of removed types fall back to the default).
    func resetToDefaults() { types = CuePointType.defaults; persist() }

    // MARK: Private

    private func update(_ id: UUID, _ change: (inout CuePointType) -> Void) {
        guard let i = types.firstIndex(where: { $0.id == id }) else { return }
        change(&types[i]); persist()
    }

    private func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while types.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(types) { defaults.set(data, forKey: Self.key) }
    }

    private static func ensuringDefault(_ list: [CuePointType]) -> [CuePointType] {
        list.contains(where: { $0.id == CuePointType.defaultID }) ? list : [CuePointType.defaults[0]] + list
    }
}
