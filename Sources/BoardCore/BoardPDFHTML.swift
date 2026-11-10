import Foundation

public enum BoardPDFTemplate: String, CaseIterable, Identifiable {
    case editorial, studio, minimal
    public var id: String { rawValue }
    public var title: String {
        switch self { case .editorial: return "Editorial"; case .studio: return "Studio"; case .minimal: return "Minimal" }
    }
    public var subtitle: String {
        switch self { case .editorial: return "Warm paper · thoughtful and inviting"; case .studio: return "Navy and blue · clear and structured"; case .minimal: return "Black and white · simple and print-friendly" }
    }
}

public enum BoardPDFHTML {
    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    private static func color(_ value: String?, fallback: String) -> String {
        guard let value, value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { return fallback }
        return value
    }
    private static func number(_ value: Double) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.isFinite ? value : 0) }
    private static func textColor(on hex: String) -> String {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0xFFF1B8
        func linear(_ c: Int) -> Double { let v = Double(c) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear((value >> 16) & 255) + 0.7152 * linear((value >> 8) & 255) + 0.0722 * linear(value & 255)
        return luminance > 0.179 ? "#272727" : "#ffffff"
    }

    /// Image values must be trusted data: image URLs prepared by the caller, never remote URLs.
    public static func render(board: Board, template: BoardPDFTemplate, images: [String: String] = [:]) -> String {
        let palette: (paper: String, ink: String, accent: String, muted: String, card: String, line: String, hero: String)
        switch template {
        case .editorial: palette = ("#fcf9f4", "#302927", "#b86442", "#776b65", "#ffffff", "#e8ded5", "#f4e6d7")
        case .studio: palette = ("#f4f7fb", "#17253e", "#355fa3", "#61708a", "#ffffff", "#dce4ef", "#e4edf9")
        case .minimal: palette = ("#ffffff", "#181818", "#222222", "#626262", "#ffffff", "#d5d5d5", "#f1f1f1")
        }
        let templateStyle: String
        switch template {
        case .editorial:
            templateStyle = ".hero h1 { font-family: Georgia, serif; font-weight: 600; } .note-card { border-left: 3px solid #d7a18b; }"
        case .studio:
            templateStyle = ".hero { background: #1d3152; color: #fff; } .hero .eyebrow { color: #a9c7f4; } .hero .summary { color: #d2ddef; } .notes { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; } .note-card { margin: 0; }"
        case .minimal:
            templateStyle = ".hero { padding: 10px 0 20px; background: transparent; border-radius: 0; border-bottom: 2px solid #222; } .section-head { border-bottom: 1px solid #222; padding-bottom: 6px; } .note-card { padding: 12px 0; border: 0; border-bottom: 1px solid #d5d5d5; border-radius: 0; } .canvas { border-radius: 0; }"
        }
        let notesByID = Dictionary(board.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let titleClass = board.title.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) } ? " class=\"thai-title\"" : ""
        let assetsByID = Dictionary(board.projectAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let noteCards = board.notes.enumerated().map { index, note in
            let groups = board.groups.filter { $0.memberIDs?.contains(note.id) == true }.map(\.title)
            let assets = (note.assetIDs ?? []).compactMap { assetsByID[$0] }
            let pics = (["legacy:\(note.id)"] + assets.map(\.id)).compactMap { id -> String? in
                guard let src = images[id] else { return nil }
                guard src.hasPrefix("data:image/") else { return "<p class=\"image-warning\">Image unavailable or exceeds the export limit.</p>" }
                return "<img class=\"attachment-image\" src=\"\(escape(src))\" alt=\"Attached image\">"
            }.joined()
            let attachments = assets.isEmpty ? "" : "<div class=\"attachments\"><span>FILES</span> " + assets.map { escape($0.name) }.joined(separator: " · ") + "</div>"
            let group = groups.isEmpty ? "" : "<div class=\"group-label\">" + groups.map(escape).joined(separator: " · ") + "</div>"
            return """
            <article class="note-card"><div class="note-head"><span class="note-number">\(String(format: "%02d", index + 1))</span>\(group)</div><div class="note-text">\(escape(note.text.isEmpty ? "Empty note" : note.text))</div>\(pics)\(attachments)</article>
            """
        }.joined(separator: "\n")
        let relations = board.connections.map { edge in
            let from = notesByID[edge.from]?.text ?? edge.from, to = notesByID[edge.to]?.text ?? edge.to
            let symbol = edge.effectiveDirection == .twoWay ? "↔" : edge.effectiveDirection == .oneWay ? "→" : "—"
            let label = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "<div class=\"relation\"><div class=\"relation-label\">\(escape(label.isEmpty ? "Relationship" : label))</div><div class=\"relation-nodes\">\(escape(short(from))) <span>\(symbol)</span> \(escape(short(to)))</div></div>"
        }.joined(separator: "\n")
        let emptyNotes = board.notes.isEmpty ? "<p class=\"empty\">No notes on this board yet.</p>" : noteCards
        let emptyRelations = board.connections.isEmpty ? "<p class=\"empty\">No connections on this board yet.</p>" : relations
        let wallpaperWarning = board.wallpaperAssetID.map { images[$0]?.hasPrefix("data:image/") == true ? "" : " Wallpaper image unavailable or exceeds the export limit." } ?? ""
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style>
        @page { size: A4; margin: 15mm; }
        * { box-sizing: border-box; } html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        body { margin: 0; color: \(palette.ink); background: \(palette.paper); font: 13px -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif; line-height: 1.55; }
        .document { padding: 28px 32px 44px; } .eyebrow { color: \(palette.accent); text-transform: uppercase; letter-spacing: .2em; font-size: 10px; font-weight: 800; }
        .hero { background: \(palette.hero); border-radius: 17px; padding: 30px 34px; margin-bottom: 28px; }
        h1 { font-size: 34px; line-height: 1.12; letter-spacing: -.035em; margin: 14px 0 12px; overflow-wrap: anywhere; }
        .summary { color: \(palette.muted); font-size: 12px; } .section-head { display: flex; align-items: baseline; gap: 12px; margin: 28px 0 12px; break-after: avoid; }
        .section-number { color: \(palette.accent); font-size: 10px; letter-spacing: .14em; font-weight: 800; }
        h2 { font-size: 19px; letter-spacing: -.025em; margin: 0; } .caption { color: \(palette.muted); font-size: 11px; margin: 9px 0 0; }
        .canvas { border: 1px solid \(palette.line); border-radius: 12px; background: #fff; padding: 12px; break-inside: avoid; }
        .canvas svg { display: block; width: 100%; height: auto; max-height: 450px; }
        .notes { display: block; } .note-card { background: \(palette.card); border: 1px solid \(palette.line); border-radius: 11px; padding: 16px 18px; margin: 0 0 10px; break-inside: avoid; }
        .note-head { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; } .note-number { color: \(palette.accent); font-weight: 800; font-size: 11px; letter-spacing: .08em; }
        .group-label { color: \(palette.muted); font-size: 10px; text-transform: uppercase; letter-spacing: .08em; }
        .note-text { white-space: pre-wrap; overflow-wrap: anywhere; font-size: 13px; } .attachment-image { display: block; max-width: 100%; max-height: 230px; object-fit: contain; object-position: left; margin-top: 12px; } .image-warning { color: \(palette.muted); font-size: 11px; }
        .attachments { border-top: 1px solid \(palette.line); padding-top: 9px; margin-top: 12px; color: \(palette.muted); font-size: 11px; overflow-wrap: anywhere; } .attachments span { font-weight: 800; letter-spacing: .1em; color: \(palette.accent); }
        .relation { padding: 11px 0; border-bottom: 1px solid \(palette.line); break-inside: avoid; } .relation-label { color: \(palette.accent); font-size: 10px; font-weight: 800; text-transform: uppercase; letter-spacing: .08em; }
        .relation-nodes { font-size: 13px; overflow-wrap: anywhere; } .relation-nodes span { color: \(palette.accent); font-weight: 800; padding: 0 6px; }
        .empty { color: \(palette.muted); font-size: 12px; } .footer { margin-top: 32px; padding-top: 12px; border-top: 1px solid \(palette.line); color: \(palette.muted); font-size: 10px; }
        @media screen { body { max-width: 820px; margin: 0 auto; } } @media print { .document { padding: 0; } }
        \(templateStyle)
        .hero h1.thai-title { font-family: -apple-system, 'Thonburi', sans-serif; font-weight: 400; letter-spacing: normal; }
        </style></head><body><main class="document"><header class="hero"><div class="eyebrow">CoThink Board &nbsp; / &nbsp; Board export</div><h1\(titleClass)>\(escape(board.title))</h1><div class="summary">\(board.notes.count) notes &nbsp; · &nbsp; \(board.connections.count) connections &nbsp; · &nbsp; \(board.groups.count) groups &nbsp; · &nbsp; Revision \(board.revision)</div></header>
        <div class="section-head"><span class="section-number">01</span><h2>Board at a glance</h2></div><div class="canvas">\(svg(board: board, images: images))</div><p class="caption">A visual overview of the board. Full note text and relationships follow below.\(wallpaperWarning)</p>
        <div class="section-head"><span class="section-number">02</span><h2>Notes &amp; context</h2></div><section class="notes">\(emptyNotes)</section>
        <div class="section-head"><span class="section-number">03</span><h2>Connections</h2></div><section>\(emptyRelations)</section><footer class="footer">Made with CoThink Board &nbsp; · &nbsp; \(escape(board.title))</footer></main></body></html>
        """
    }

    private static func short(_ value: String) -> String {
        let first = value.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "Empty note"
        return first.count > 80 ? String(first.prefix(77)) + "…" : first
    }

    public static func svg(board: Board, images: [String: String]) -> String {
        let notes = Dictionary(board.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The visual overview matches the canvas: subtrees under a folded note and
        // edges touching a hidden note are excluded. The text sections below stay complete.
        let hidden = board.hiddenNoteIDs()
        let points = board.connections.flatMap { edge -> [ConnectionPoint] in
            guard let a = notes[edge.from], let b = notes[edge.to], !hidden.contains(edge.from), !hidden.contains(edge.to) else { return [] }
            return edge.controlPoints(from: a, to: b)
        }
        let visibleNotes = board.notes.filter { !hidden.contains($0.id) }
        let minX = min(0, (visibleNotes.map(\.x) + board.groups.map(\.x) + points.map(\.x)).min() ?? 0) - 35
        let minY = min(0, (visibleNotes.map(\.y) + board.groups.map(\.y) + points.map(\.y)).min() ?? 0) - 35
        let right = max(500, (visibleNotes.map { $0.x + $0.width } + board.groups.map { $0.x + $0.width } + points.map(\.x)).max() ?? 0) + 35
        let bottom = max(280, (visibleNotes.map { $0.y + $0.height } + board.groups.map { $0.y + $0.height } + points.map(\.y)).max() ?? 0) + 35
        let bounds = visibleNotes.map { BoardRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } + board.groups.map { BoardRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } + points.map { BoardRect(x: $0.x, y: $0.y, width: 0, height: 0) }
        let extent = BoardRect.canvasExtent(containing: bounds)
        var background = ""
        if board.wallpaperColor != nil || board.wallpaperAssetID != nil {
            background = "<rect x=\"0\" y=\"0\" width=\"\(number(extent.width))\" height=\"\(number(extent.height))\" fill=\"\(color(board.wallpaperColor, fallback: "#FFFFFF"))\"/>"
        }
        if let id = board.wallpaperAssetID, let src = images[id], src.hasPrefix("data:image/") {
            background += "<image href=\"\(escape(src))\" x=\"0\" y=\"0\" width=\"\(number(extent.width))\" height=\"\(number(extent.height))\" preserveAspectRatio=\"xMidYMid slice\" opacity=\"\(number(board.wallpaperOpacity ?? 0.45))\"/>"
        }
        let groups = board.groups.map { g in
            "<rect x=\"\(number(g.x))\" y=\"\(number(g.y))\" width=\"\(number(g.width))\" height=\"\(number(g.height))\" rx=\"15\" fill=\"\(color(g.color, fallback: "#E6E9F5"))\" fill-opacity=\".38\" stroke=\"#a8acb5\" stroke-dasharray=\"7 5\"/><text x=\"\(number(g.x+13))\" y=\"\(number(g.y+22))\" fill=\"#59616c\" font-size=\"\(number(g.fontSize ?? 11))\" font-weight=\"700\">\(escape(short(g.title)))</text>"
        }.joined()
        // Mindmap tree edges: parentID links drawn as accent elbows with an arrowhead
        // at the child end, under the connection layer, matching the canvas z-order.
        let treeEdges = board.notes.compactMap { child -> String? in
            guard let parentID = child.parentID, let parent = notes[parentID] else { return nil }
            guard !hidden.contains(child.id) && !hidden.contains(parentID) else { return nil }
            let s = ConnectionPoint(x: parent.x + parent.width, y: parent.y + parent.height / 2)
            let e = ConnectionPoint(x: child.x, y: child.y + child.height / 2)
            let midX = (s.x + e.x) / 2
            let d = "M \(number(s.x)) \(number(s.y)) L \(number(midX)) \(number(s.y)) L \(number(midX)) \(number(e.y)) L \(number(e.x)) \(number(e.y))"
            let angle = atan2(e.y - e.y, e.x - midX), length = 10.0, wing = 5.0
            let bx = e.x - cos(angle) * length, by = e.y - sin(angle) * length
            let x1 = bx - sin(angle) * wing, y1 = by + cos(angle) * wing
            let x2 = bx + sin(angle) * wing, y2 = by - cos(angle) * wing
            let arrow = "<path d=\"M \(number(x1)) \(number(y1)) L \(number(e.x)) \(number(e.y)) L \(number(x2)) \(number(y2))\" fill=\"none\" stroke=\"#7A8BA8\" stroke-width=\"1.5\"/>"
            return "<path d=\"\(d)\" fill=\"none\" stroke=\"#7A8BA8\" stroke-width=\"1.5\"/>\(arrow)"
        }.joined()
        let edges = board.connections.compactMap { edge -> String? in
            guard let a = notes[edge.from], let b = notes[edge.to] else { return nil }
            guard !hidden.contains(edge.from) && !hidden.contains(edge.to) else { return nil }
            let start = ConnectionPoint(x: a.x+a.width/2, y: a.y+a.height/2), end = ConnectionPoint(x: b.x+b.width/2, y: b.y+b.height/2)
            let cp = edge.controlPoints(from: a, to: b)
            func boundary(_ c: ConnectionPoint, _ toward: ConnectionPoint, _ n: Note) -> ConnectionPoint {
                let dx = toward.x-c.x, dy = toward.y-c.y, len = max(0.001, hypot(dx,dy)), ux=dx/len, uy=dy/len
                let t = min(n.width/max(abs(ux),0.0001), n.height/max(abs(uy),0.0001))/2
                return ConnectionPoint(x:c.x+ux*t, y:c.y+uy*t)
            }
            let s=boundary(start, cp.first ?? end, a), e=boundary(end, cp.last ?? start, b)
            var d="M \(number(s.x)) \(number(s.y)) "
            if edge.effectiveRoute == .curved, let p=cp.first { d += "Q \(number(p.x)) \(number(p.y)) \(number(e.x)) \(number(e.y))" }
            else { d += cp.map { "L \(number($0.x)) \(number($0.y)) " }.joined() + "L \(number(e.x)) \(number(e.y))" }
            func arrowHead(_ tip: ConnectionPoint, toward: ConnectionPoint) -> String {
                let angle = atan2(tip.y - toward.y, tip.x - toward.x), length = 10.0, wing = 5.0
                let bx = tip.x - cos(angle) * length, by = tip.y - sin(angle) * length
                let x1 = bx - sin(angle) * wing, y1 = by + cos(angle) * wing
                let x2 = bx + sin(angle) * wing, y2 = by - cos(angle) * wing
                return "<path d=\"M \(number(x1)) \(number(y1)) L \(number(tip.x)) \(number(tip.y)) L \(number(x2)) \(number(y2))\" fill=\"none\" stroke=\"\(color(edge.strokeColor, fallback: "#737d8e"))\" stroke-width=\"\(number(edge.strokeWidth ?? 1.5))\"/>"
            }
            let arrows = (edge.effectiveDirection == .none ? "" : arrowHead(e, toward: cp.last ?? s)) + (edge.effectiveDirection == .twoWay ? arrowHead(s, toward: cp.first ?? e) : "")
            let dash = edge.strokeStyle == .dashed ? " stroke-dasharray=\"8 5\"" : edge.strokeStyle == .dotted ? " stroke-dasharray=\"1 4\"" : ""
            let labelPoint: ConnectionPoint
            if edge.effectiveRoute == .curved, let p=cp.first { labelPoint = ConnectionPoint(x:(s.x+2*p.x+e.x)/4,y:(s.y+2*p.y+e.y)/4) }
            else { let all=[s]+cp+[e]; let i=(all.count-1)/2; labelPoint=ConnectionPoint(x:(all[i].x+all[i+1].x)/2,y:(all[i].y+all[i+1].y)/2) }
            let label = edge.label.map { "<text x=\"\(number(labelPoint.x))\" y=\"\(number(labelPoint.y-5))\" text-anchor=\"middle\" font-size=\"\(number(edge.fontSize ?? 11))\" fill=\"#39414d\">\(escape(short($0)))</text>" } ?? ""
            return "<path d=\"\(d)\" fill=\"none\" stroke=\"\(color(edge.strokeColor, fallback: "#737d8e"))\" stroke-width=\"\(number(edge.strokeWidth ?? 1.5))\"\(dash)/>\(arrows)\(label)"
        }.joined()
        let cards = board.notes.filter { !hidden.contains($0.id) }.enumerated().map { index, n in
            let text = escape(String(short(n.text).prefix(40)))
            let fill = color(n.color, fallback: "#FFF1B8")
            let stroke = color(n.strokeColor, fallback: "#939aa4")
            let strokeAttrs = n.shape == nil ? "" : " stroke-width=\"\(number(n.strokeWidth ?? 1))\"\(n.strokeStyle == .dashed ? " stroke-dasharray=\"8 5\"" : n.strokeStyle == .dotted ? " stroke-dasharray=\"1 4\"" : "")"
            let labelFill = n.shape == .text ? "#272727" : textColor(on: fill)
            let fontSize = min(n.fontSize ?? 15, 22)
            let imageSource = (["legacy:\(n.id)"] + (n.assetIDs ?? [])).compactMap { images[$0] }.first { $0.hasPrefix("data:image/") }
            let image = imageSource.map { "<image href=\"\(escape($0))\" x=\"\(number(n.x+10))\" y=\"\(number(n.y+n.height*0.45))\" width=\"\(number(max(0,n.width-20)))\" height=\"\(number(max(0,n.height*0.45)))\" preserveAspectRatio=\"xMidYMid meet\"/>" } ?? ""
            let foldBadge = n.collapsed == true ? "<rect x=\"\(number(n.x+n.width-40))\" y=\"\(number(n.y+n.height-25))\" width=\"32\" height=\"18\" rx=\"9\" fill=\"#7A8BA8\"/><text x=\"\(number(n.x+n.width-24))\" y=\"\(number(n.y+n.height-12))\" text-anchor=\"middle\" font-size=\"11\" font-weight=\"700\" fill=\"#ffffff\">+\(board.children(of: n.id).count)</text>" : ""
            let card: String
            switch n.shape {
            case .line:
                let leftX = n.x, rightX = n.x + n.width
                card = "<line x1=\"\(number(n.lineFlipped == true ? rightX : leftX))\" y1=\"\(number(n.y))\" x2=\"\(number(n.lineFlipped == true ? leftX : rightX))\" y2=\"\(number(n.y+n.height))\" stroke=\"\(stroke)\"\(strokeAttrs)/>"
            case .ellipse:
                card = "<ellipse cx=\"\(number(n.x+n.width/2))\" cy=\"\(number(n.y+n.height/2))\" rx=\"\(number(n.width/2))\" ry=\"\(number(n.height/2))\" fill=\"\(fill)\" stroke=\"\(stroke)\"\(strokeAttrs)/>"
            case .diamond:
                card = "<polygon points=\"\(number(n.x+n.width/2)),\(number(n.y)) \(number(n.x+n.width)),\(number(n.y+n.height/2)) \(number(n.x+n.width/2)),\(number(n.y+n.height)) \(number(n.x)),\(number(n.y+n.height/2))\" fill=\"\(fill)\" stroke=\"\(stroke)\"\(strokeAttrs)/>"
            case .text:
                card = ""
            default:
                card = "<rect x=\"\(number(n.x))\" y=\"\(number(n.y))\" width=\"\(number(n.width))\" height=\"\(number(n.height))\" rx=\"\(n.shape == nil ? 9 : 6)\" fill=\"\(fill)\" stroke=\"\(stroke)\"\(strokeAttrs)/>"
            }
            let label = n.shape == .line || (n.shape != nil && n.text.isEmpty) ? "" :
                "<clipPath id=\"note-clip-\(index)\"><rect x=\"\(number(n.x+8))\" y=\"\(number(n.y+4))\" width=\"\(number(max(0,n.width-16)))\" height=\"\(number(max(0,n.height-8)))\"/></clipPath>" +
                (n.shape == nil || n.shape == .text
                    ? "<text clip-path=\"url(#note-clip-\(index))\" x=\"\(number(n.x+12))\" y=\"\(number(n.y+25))\" fill=\"\(labelFill)\" font-size=\"\(number(fontSize))\" font-weight=\"600\">\(text)</text>"
                    : "<text clip-path=\"url(#note-clip-\(index))\" x=\"\(number(n.x+n.width/2))\" y=\"\(number(n.y+n.height/2+fontSize*0.35))\" text-anchor=\"middle\" fill=\"\(labelFill)\" font-size=\"\(number(fontSize))\" font-weight=\"600\">\(text)</text>")
            return "\(card)\(label)\(image)\(foldBadge)"
        }.joined()
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(number(minX)) \(number(minY)) \(number(right-minX)) \(number(bottom-minY))\" role=\"img\" aria-label=\"Board overview\"><defs><marker id=\"arrow\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M 1 1 L 9 5 L 1 9\" fill=\"none\" stroke=\"#737d8e\" stroke-width=\"1.3\"/></marker></defs><g font-family=\"-apple-system, sans-serif\">\(background)\(groups)\(treeEdges)\(edges)\(cards)</g></svg>"
    }
}
