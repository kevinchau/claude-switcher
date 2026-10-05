import AppKit

/// The one window this app has: where it lives, what an account is, and the first thing to do.
///
/// It opens by itself on the first launch, and again whenever Claude Switcher is opened while
/// it is already running. macOS hides menu bar icons that do not fit, and an app with no Dock
/// icon and a hidden menu bar icon is otherwise unreachable — so the window also offers the
/// menu itself.
@MainActor
final class WelcomeWindowController: NSWindowController {

    struct Content {
        /// The account that is the Claude sign-in the user already had, if there is one.
        var defaultAccountLabel: String?
        /// Nobody has added a second account yet: adding one is the next step.
        var suggestsAddingAccount: Bool
        /// macOS 26 added System Settings › Menu Bar, which can keep an app's icon off the bar.
        var hasMenuBarSettings: Bool
    }

    struct Actions {
        var addAccount: @MainActor () -> Void
        /// Pops the status menu up under the given view.
        var showMenu: @MainActor (NSView) -> Void
    }

    static let menuBarSymbolName = "person.2.circle"

    /// Every row is exactly this wide, so the text wraps where the buttons end.
    private static let contentWidth: CGFloat = 440
    private static let symbolColumnWidth: CGFloat = 36
    private static let symbolSpacing: CGFloat = 12
    private let actions: Actions

    init(content: Content, actions: Actions) {
        self.actions = actions
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "Claude Switcher"
        window.isReleasedWhenClosed = false
        // It is the app's one handle when the menu bar icon is hidden: come to wherever the
        // user is, including over a full-screen app.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.contentView = makeContentView(content)
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    // MARK: - Content

    private func makeContentView(_ content: Content) -> NSView {
        let header = NSStackView(views: [
            label("Welcome to Claude Switcher", font: .systemFont(ofSize: 20, weight: .semibold)),
            label("Use more than one Claude account on this Mac, side by side.", color: .secondaryLabelColor),
        ])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4

        let points = NSStackView(views: [
            point(symbol: "menubar.arrow.up.rectangle", title: "It lives in the menu bar", body: menuBarText(content)),
            point(symbol: "person.2", title: "One Claude window per account", body: NSAttributedString(string: accountsText(content))),
            point(symbol: "folder", title: "Your Claude Code setup comes with you", body: NSAttributedString(string: sharedText)),
        ])
        points.orientation = .vertical
        points.alignment = .leading
        points.spacing = 18

        let showMenu = NSButton(title: "Show Menu", target: self, action: #selector(showMenu(_:)))
        showMenu.toolTip = "Opens Claude Switcher\u{2019}s menu right here \u{2014} the same one as in the menu bar."
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        let add = NSButton(title: "Add Account\u{2026}", target: self, action: #selector(addAccount(_:)))
        // Return goes to the next step: adding an account until there is a second one.
        (content.suggestsAddingAccount ? add : done).keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [showMenu, spacer, done, add])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let root = NSStackView(views: [header, points, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 24
        root.edgeInsets = NSEdgeInsets(top: 26, left: 30, bottom: 22, right: 30)
        NSLayoutConstraint.activate(
            [header, points, buttons].map { $0.widthAnchor.constraint(equalToConstant: Self.contentWidth) }
            + [root.widthAnchor.constraint(equalToConstant: Self.contentWidth + root.edgeInsets.left + root.edgeInsets.right)]
        )
        return root
    }

    /// "Look for the ◎ icon…" — with the icon itself in the sentence, so there is no guessing
    /// which one is meant.
    private func menuBarText(_ content: Content) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let text = NSMutableAttributedString(string: "Look for the ", attributes: attributes)
        if let symbol = NSImage(systemSymbolName: Self.menuBarSymbolName, accessibilityDescription: "Claude Switcher") {
            // A template image in an attachment draws black unless it is given a colour.
            let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize + 2, weight: .regular)
                .applying(.init(paletteColors: [.labelColor]))
            let attachment = NSTextAttachment()
            attachment.image = symbol.withSymbolConfiguration(configuration)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " icon", attributes: attributes))
        } else {
            text.append(NSAttributedString(string: "Claude Switcher icon", attributes: attributes))
        }
        var rest = " near the clock \u{2014} there is no Dock icon. Can\u{2019}t see it? macOS hides menu bar icons when the bar is full; quitting a menu bar app or two makes room."
        if content.hasMenuBarSettings {
            rest += " Also check System Settings \u{203A} Menu Bar \u{203A} Allow in the Menu Bar."
        }
        rest += " Opening Claude Switcher again always brings this window back."
        text.append(NSAttributedString(string: rest, attributes: attributes))
        return text
    }

    /// What VoiceOver reads for a body text: the attachment character an inline symbol leaves
    /// in the string says nothing, so it is replaced by the symbol's own description.
    private static func spoken(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                result += attachment.image?.accessibilityDescription ?? ""
            } else {
                result += text.attributedSubstring(from: range).string
            }
        }
        return result
    }

    private func accountsText(_ content: Content) -> String {
        var text = ""
        if let label = content.defaultAccountLabel {
            text += "The Claude sign-in you already have is here as \u{201C}\(label)\u{201D}. "
        }
        text += "Add another account and Claude opens a second window where you sign in to it \u{2014} a second Claude icon in the Dock is expected. Choose an account in the menu to jump to its window. Nothing is signed out; they all keep running."
        return text
    }

    /// Says what is NOT shared as plainly as what is: Claude keeps chats and the Code tab's
    /// session list per account. A session can be copied across; the lists cannot be merged.
    private let sharedText = "Skills, plugins, memory, settings and CLAUDE.md in ~/.claude are the same on every account, so when one runs out of usage you can keep working from another. Conversations are the exception: chats and the Code tab\u{2019}s session list stay with the account that started them \u{2014} though each account\u{2019}s Sessions menu can copy a Code session to another account. The bars in the menu show how much each account has used."

    // MARK: - Pieces

    private func label(_ string: String, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = Self.contentWidth
        return field
    }

    private func point(symbol: String, title: String, body: NSAttributedString) -> NSView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        image.contentTintColor = .controlAccentColor
        // Decoration: the title beside it says everything the picture does.
        image.setAccessibilityElement(false)
        image.cell?.setAccessibilityElement(false)
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: Self.symbolColumnWidth).isActive = true

        let bodyField = NSTextField(wrappingLabelWithString: "")
        if body.length > 0, body.attribute(.font, at: 0, effectiveRange: nil) != nil {
            bodyField.attributedStringValue = body
        } else {
            bodyField.stringValue = body.string
            bodyField.textColor = .secondaryLabelColor
        }
        bodyField.isSelectable = false
        bodyField.setAccessibilityValue(Self.spoken(body))
        bodyField.preferredMaxLayoutWidth = Self.contentWidth - Self.symbolColumnWidth - Self.symbolSpacing

        let titleField = label(title, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
        titleField.preferredMaxLayoutWidth = bodyField.preferredMaxLayoutWidth
        let text = NSStackView(views: [titleField, bodyField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let row = NSStackView(views: [image, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Self.symbolSpacing
        return row
    }

    // MARK: - Actions

    @objc private func addAccount(_ sender: NSButton) {
        actions.addAccount()
    }

    @objc private func showMenu(_ sender: NSButton) {
        actions.showMenu(sender)
    }

    @objc private func done(_ sender: NSButton) {
        close()
    }

    /// Esc. There is no main menu in this app, so no Close item to carry a shortcut either.
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
