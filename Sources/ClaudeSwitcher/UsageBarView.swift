import AppKit
import ClaudeSwitcherCore

/// The usage rows drawn under a profile in the menu: a label, a bar, the percentage, and a
/// short trailing note ("resets by 9:13 PM", "2 h ago").
///
/// A plain frame-based view drawn in one `draw(_:)`: `NSMenu` sizes a view item from its
/// frame and stretches it to the menu's width through the autoresizing mask. Colours are
/// semantic and resolved at draw time, so light and dark menus both come out right.
final class UsageBarView: NSView {

    struct Row: Equatable, Sendable {
        let label: String
        /// `nil` renders as an em dash: the period has ended and the number is stale.
        let percent: Int?
        let level: UsageLevel
        let trailing: String?
        /// The estimate, when above the recorded value: drawn as a lighter segment from the
        /// recorded value up to it. The percentage column keeps showing what was recorded.
        var estimate: Int? = nil
    }

    /// Where item titles start in a menu with a state column, so the rows line up with the
    /// profile label above them.
    private static let titleInset: CGFloat = 21
    private static let rightInset: CGFloat = 14
    private static let rowHeight: CGFloat = 16
    private static let labelWidth: CGFloat = 40
    private static let barWidth: CGFloat = 70
    private static let barHeight: CGFloat = 6
    private static let percentWidth: CGFloat = 36
    /// The lighter estimate segment: the bar's own colour at this alpha.
    static let estimateAlpha: CGFloat = 0.4
    /// Where the trailing note starts: inset, label, bar, gap, percentage — 175 pt, leaving the
    /// note room for "resets by Sat 10:09 PM (est.)".
    static let trailingOrigin: CGFloat = titleInset + labelWidth + barWidth + 8 + percentWidth

    private(set) var rows: [Row]

    /// At least `width`, and wide enough for the longest note on one line: a menu is as wide as
    /// its widest item, so a note is never cut — a clipped "(est.)" would drop the hedge.
    init(rows: [Row], width: CGFloat = 300) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: max(width, Self.width(for: rows)), height: Self.height(for: rows.count)))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func height(for count: Int) -> CGFloat { CGFloat(count) * rowHeight + 6 }

    private static var noteAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.menuFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style]
    }

    /// The width that shows every row's note in full.
    static func width(for rows: [Row]) -> CGFloat {
        let note = rows.compactMap(\.trailing).map { ($0 as NSString).size(withAttributes: noteAttributes).width }.max() ?? 0
        return (trailingOrigin + note + rightInset).rounded(.up)
    }

    /// New values for the same number of rows, redrawn in place (a menu that is open keeps its
    /// layout). Returns `false` when the view has to be replaced: another number of rows, or a
    /// note that needs more width than the view has.
    @discardableResult
    func update(rows newRows: [Row]) -> Bool {
        guard newRows.count == rows.count, Self.width(for: newRows) <= frame.width else { return false }
        guard newRows != rows else { return true }
        rows = newRows
        needsDisplay = true
        return true
    }

    /// Vibrancy would blend the accent colour into the menu material; keep the bars solid.
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.menuFont(ofSize: 11)
        let label: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let number: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let note = Self.noteAttributes

        // Rows are laid out top-down; AppKit's origin is bottom-left.
        for (index, row) in rows.enumerated() {
            let top = bounds.height - 3 - CGFloat(index + 1) * Self.rowHeight
            let baseline = top + (Self.rowHeight - font.capHeight) / 2 - 1
            var x = Self.titleInset

            (row.label as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: label)
            x += Self.labelWidth

            let track = NSRect(x: x, y: top + (Self.rowHeight - Self.barHeight) / 2, width: Self.barWidth, height: Self.barHeight)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
            let color = Self.color(for: row.level)
            // The estimate first, lighter, so the recorded fill covers its start: what shows is
            // the segment from the recorded value to the estimate.
            if let estimate = row.estimate, estimate > (row.percent ?? 0) {
                color.withAlphaComponent(Self.estimateAlpha).setFill()
                NSBezierPath(roundedRect: Self.fill(track, percent: estimate), xRadius: 3, yRadius: 3).fill()
            }
            if let percent = row.percent, percent > 0 {
                color.setFill()
                NSBezierPath(roundedRect: Self.fill(track, percent: percent), xRadius: 3, yRadius: 3).fill()
            }
            x += Self.barWidth + 8

            let text = row.percent.map { "\($0)%" } ?? "\u{2014}"
            (text as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: number)
            x += Self.percentWidth

            if let trailing = row.trailing {
                let available = bounds.width - Self.rightInset - x
                if available > 40 {
                    (trailing as NSString).draw(in: NSRect(x: x, y: baseline - 2, width: available, height: Self.rowHeight),
                                                withAttributes: note)
                }
            }
        }
    }

    private static func fill(_ track: NSRect, percent: Int) -> NSRect {
        NSRect(x: track.minX, y: track.minY, width: max(barHeight, track.width * CGFloat(min(percent, 100)) / 100),
               height: track.height)
    }

    private static func color(for level: UsageLevel) -> NSColor {
        switch level {
        case .normal: return .controlAccentColor
        case .warning: return .systemOrange
        case .limit: return .systemRed
        }
    }
}
