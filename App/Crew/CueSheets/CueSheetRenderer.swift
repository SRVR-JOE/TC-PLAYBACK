import UIKit

/// Per-role printed cue sheet: US Letter, a title block, then every cue of the track in TC
/// order. The role's own rows are printed black with a light band; everyone else's in grey,
/// so an operator can still see what's going on around their cues.
struct CueSheetRenderer {
    struct Row: Equatable {
        var timecode: String
        var lane: String
        var number: String
        var name: String
        var detail: String
        var highlighted: Bool
    }

    static let pageSize = CGSize(width: 612, height: 792)  // US Letter, points
    let margin: CGFloat = 40
    let rowHeight: CGFloat = 18
    let titleBlockHeight: CGFloat = 64
    let headerHeight: CGFloat = 20
    let footerHeight: CGFloat = 20

    /// Rows that fit on page 1 (title block) and on following pages.
    var rowsOnFirstPage: Int { Int((Self.pageSize.height - 2 * margin - titleBlockHeight - headerHeight - footerHeight) / rowHeight) }
    var rowsPerPage: Int { Int((Self.pageSize.height - 2 * margin - headerHeight - footerHeight) / rowHeight) }

    func pageCount(rows: Int) -> Int {
        guard rows > rowsOnFirstPage else { return 1 }
        return 1 + Int((Double(rows - rowsOnFirstPage) / Double(rowsPerPage)).rounded(.up))
    }

    /// Builds rows from cues: all lanes, TC order, `role`'s rows highlighted.
    static func rows(cues: [CrewCue], role: CrewRole, lanes: [CuePointType], clock: CuePointClock) -> [Row] {
        let laneName = Dictionary(lanes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return cues.sorted(by: CrewCue.timeOrder).map { c in
            var detail: [String] = []
            if let cam = c.camera { detail.append("Cam \(cam)") }
            if !c.shotSize.isEmpty { detail.append(c.shotSize) }
            if !c.shotNote.isEmpty { detail.append(c.shotNote) }
            return Row(timecode: clock.timecode(at: c.time).description, lane: laneName[c.laneID] ?? "Cue",
                       number: c.shotNumber.isEmpty ? c.cueID : c.shotNumber, name: c.name,
                       detail: detail.joined(separator: " · "), highlighted: role.matches(c))
        }
    }

    func render(title: String, track: String, roleName: String, rows: [Row]) -> Data {
        let bounds = CGRect(origin: .zero, size: Self.pageSize)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "\(title) – \(roleName)",
                               kCGPDFContextCreator as String: "TC Playback"]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        let pages = pageCount(rows: rows.count)
        let cols: [(String, CGFloat)] = [("Timecode", 86), ("Lane", 80), ("No.", 44), ("Name", 150), ("Detail", 0)]
        let width = Self.pageSize.width - 2 * margin
        let fixed = cols.reduce(0) { $0 + $1.1 }
        let widths = cols.map { $0.1 == 0 ? width - fixed : $0.1 }

        let body = UIFont.systemFont(ofSize: 9)
        let bodyBold = UIFont.systemFont(ofSize: 9, weight: .semibold)
        let small = UIFont.systemFont(ofSize: 8)
        let grey = UIColor(white: 0.55, alpha: 1)
        let band = UIColor(white: 0.9, alpha: 1)

        func draw(_ s: String, in r: CGRect, font: UIFont, color: UIColor) {
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
            (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p], context: nil)
        }

        return renderer.pdfData { ctx in
            var i = 0
            for page in 0..<pages {
                ctx.beginPage()
                var y = margin
                if page == 0 {
                    draw(title, in: CGRect(x: margin, y: y, width: width, height: 22), font: .systemFont(ofSize: 16, weight: .semibold), color: .black)
                    draw("Track: \(track)", in: CGRect(x: margin, y: y + 24, width: width, height: 14), font: body, color: .black)
                    draw("Cue sheet for \(roleName)", in: CGRect(x: margin, y: y + 38, width: width, height: 14), font: bodyBold, color: .black)
                    y += titleBlockHeight
                }
                var x = margin
                for (n, c) in cols.enumerated() {
                    draw(c.0, in: CGRect(x: x + 2, y: y + 5, width: widths[n] - 4, height: 12), font: bodyBold, color: .black)
                    x += widths[n]
                }
                UIColor.black.setFill()
                ctx.fill(CGRect(x: margin, y: y + headerHeight - 1, width: width, height: 0.5))
                y += headerHeight
                let capacity = page == 0 ? rowsOnFirstPage : rowsPerPage
                for _ in 0..<capacity where i < rows.count {
                    let r = rows[i]
                    if r.highlighted { band.setFill(); ctx.fill(CGRect(x: margin, y: y, width: width, height: rowHeight)) }
                    let font = r.highlighted ? bodyBold : body
                    let color = r.highlighted ? UIColor.black : grey
                    x = margin
                    for (n, text) in [r.timecode, r.lane, r.number, r.name, r.detail].enumerated() {
                        draw(text, in: CGRect(x: x + 2, y: y + 4, width: widths[n] - 4, height: rowHeight - 4), font: font, color: color)
                        x += widths[n]
                    }
                    y += rowHeight; i += 1
                }
                draw("\(title) · \(roleName) · Page \(page + 1) of \(pages)",
                     in: CGRect(x: margin, y: Self.pageSize.height - margin - 10, width: width, height: 12), font: small, color: grey)
            }
        }
    }
}
