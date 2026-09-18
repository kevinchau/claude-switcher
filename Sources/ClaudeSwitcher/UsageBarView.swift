import AppKit
import ClaudeSwitcherCore

/// The usage rows drawn under a profile in the menu: a label, a bar, the percentage, and a
/// short trailing note ("resets by 9:13 PM", "2 h ago").
///
/// A plain frame-based view drawn in one `draw(_:)`: `NSMenu` sizes a view item from its
/// frame and stretches it to the menu's width through the autoresizing mask. Colours are
/// semantic and resolved at draw time, so light and dark menus both come out right.
final class UsageBarView: NSView {

    struct Row: Sendable {
        let label: String
        /// `nil` renders as an em dash: the period has ended and the number is stale.
        let percent: Int?
        let level: UsageLevel
        let trailing: String?
    }

    /// Where item titles start in a menu with a state column, so the rows line up with the
    /// profile label above them.
    private static let titleInset: CGFloat = 21
    private static let rightInset: CGFloat = 14
    private static let rowHeight: CGFloat = 16
    private static let labelWidth: CGFloat = 40
    private static let barWidth: CGFloat = 90
    private static let barHeight: CGFloat = 6
    private static let percentWidth: CGFloat = 36

    private let rows: [Row]

    init(rows: [Row], width: CGFloat = 300) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * Self.rowHeight + 6))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Vibrancy would blend the accent colour into the menu material; keep the bars solid.
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.menuFont(ofSize: 11)
        let label: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let number: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let note: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor]

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
            if let percent = row.percent, percent > 0 {
                let fill = NSRect(x: track.minX, y: track.minY,
                                  width: max(Self.barHeight, track.width * CGFloat(min(percent, 100)) / 100),
                                  height: track.height)
                Self.color(for: row.level).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
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

    private static func color(for level: UsageLevel) -> NSColor {
        switch level {
        case .normal: return .controlAccentColor
        case .warning: return .systemOrange
        case .limit: return .systemRed
        }
    }
}
