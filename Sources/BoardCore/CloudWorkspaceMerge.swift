import Foundation

enum CloudWorkspaceMerge {
    private static let collections: Set<String> = ["boards", "lists", "notes", "groups", "connections", "assets"]

    // A missing field is distinct from a JSON null. Arrays of canvas objects merge
    // by ID; coordinate pairs, reminder snapshots and ordered ID lists stay atomic.
    static func merge(base: CloudJSON?, mac: CloudJSON?, web: CloudJSON?, field: String = "workspace",
                      path: String = "workspace", preference: CloudConflictChoice?) throws -> CloudJSON? {
        if field == "desk", base == nil, mac != nil, web != nil {
            return try merge(base: .object([:]), mac: mac, web: web, field: field, path: path, preference: preference)
        }
        if field == "editedAt", case .number(let left) = mac, case .number(let right) = web {
            return .number(max(left, right))
        }
        if mac == web { return mac }
        if mac == base { return web }
        if web == base { return mac }
        if case .object(let b) = base, case .object(let m) = mac, case .object(let w) = web {
            var result = [String: CloudJSON]()
            for key in Set(b.keys).union(m.keys).union(w.keys) {
                result[key] = try merge(base: b[key], mac: m[key], web: w[key], field: key, path: "\(path).\(key)", preference: preference)
            }
            return .object(result)
        }
        if collections.contains(field), case .array(let b) = base, case .array(let m) = mac, case .array(let w) = web {
            let before = try CloudJSON.index(b), left = try CloudJSON.index(m), right = try CloudJSON.index(w)
            var merged = [String: CloudJSON]()
            for id in Set(before.keys).union(left.keys).union(right.keys) {
                let item = right[id] ?? left[id] ?? before[id]
                let name = item?["title"]?.text ?? item?["text"]?.text ?? id
                merged[id] = try merge(base: before[id], mac: left[id], web: right[id], field: "item", path: "“\(name.prefix(60))”", preference: preference)
            }
            let original = b.compactMap { $0["id"]?.text }, macOrder = m.compactMap { $0["id"]?.text }, webOrder = w.compactMap { $0["id"]?.text }
            let common = Set(original).intersection(macOrder).intersection(webOrder).intersection(merged.keys)
            let bCommon = original.filter(common.contains), mCommon = macOrder.filter(common.contains), wCommon = webOrder.filter(common.contains)
            let macReordered = bCommon != mCommon, webReordered = bCommon != wCommon
            if macReordered && webReordered && mCommon != wCommon && preference == nil { throw CloudSyncError.conflict("\(field) order") }
            let macFirst = macReordered && (!webReordered || preference == .mac)
            let preferred = macFirst ? macOrder : webOrder
            let additional = macFirst ? webOrder : macOrder
            // Insert newly added objects after their nearest surviving predecessor,
            // retaining their order even when both sides inserted at the same position.
            var order = preferred.filter { merged[$0] != nil }
            var placed = Set(order)
            var previous: String?
            for id in additional where merged[id] != nil {
                if placed.insert(id).inserted {
                    let index = previous.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                    order.insert(id, at: index)
                }
                previous = id
            }
            return .array(order.compactMap { merged[$0] })
        }
        if let preference { return preference == .mac ? mac : web }
        throw CloudSyncError.conflict(path)
    }

    // Only patch fields the native app actually changed. This retains _access,
    // creation dates, web-only icons and future fields exactly as received.
    static func applying(from old: CloudJSON?, to new: CloudJSON?, on raw: CloudJSON?, field: String = "workspace") throws -> CloudJSON? {
        if old == new { return raw }
        if case .object(let o) = old, case .object(let n) = new, case .object(var result) = raw {
            for key in Set(o.keys).union(n.keys) where o[key] != n[key] {
                result[key] = try applying(from: o[key], to: n[key], on: result[key], field: key)
            }
            return .object(result)
        }
        if collections.contains(field), case .array(let oldItems) = old, case .array(let newItems) = new {
            let originals = try CloudJSON.index(oldItems)
            let existing = try CloudJSON.index(raw?.items ?? [])
            return .array(try newItems.map { item in
                guard let id = item["id"]?.text else { throw CloudSyncError.invalidWorkspace }
                return try applying(from: originals[id], to: item, on: existing[id], field: "item") ?? item
            })
        }
        return new
    }
}
