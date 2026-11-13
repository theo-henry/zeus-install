import AppKit

/// The cost of a window's session, as the chat page reports it (zeus-editor, docs/chat.md, "Session cost").
/// The editor computes it from the session transcripts and a price table; no message goes to Claude for it.
struct SessionCost: Equatable {
    var host: String
    var currency: String
    /// The whole session of the window on this host, across /clear and new chats.
    var total: Double
    /// The chat that runs now.
    var chat: Double
    var calls: Int
    var input: Int
    var cacheRead: Int
    var cacheWrite: Int
    var output: Int
    /// Calls of models without a price in the table; they are not in the amounts.
    var unpricedCalls: Int
    var unpricedModels: [String]
    /// US dollars for one euro, when the editor converted list prices in dollars; nil otherwise.
    var usdPerEuro: Double?

    /// From the JSON text of a "cost:" message of the chat page; nil when it is not a cost report.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = object["total"] as? Double, total.isFinite, total >= 0 else { return nil }
        let tokens = object["tokens"] as? [String: Any] ?? [:]
        func count(_ value: Any?) -> Int { max(0, (value as? NSNumber)?.intValue ?? 0) }
        host = object["host"] as? String ?? ""
        currency = object["currency"] as? String ?? "USD"
        self.total = total
        chat = max(0, (object["chat"] as? Double) ?? 0)
        calls = count(object["calls"])
        input = count(tokens["input"])
        cacheRead = count(tokens["cache_read"])
        cacheWrite = count(tokens["cache_write_5m"]) + count(tokens["cache_write_1h"])
        output = count(tokens["output"])
        unpricedCalls = count(object["unpriced_calls"])
        unpricedModels = (object["unpriced_models"] as? [String] ?? []).prefix(5).map { String($0.prefix(60)) }
        usdPerEuro = (object["usd_per_eur"] as? Double).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func amount(_ value: Double, _ currency: String) -> String {
        let symbol = currency == "EUR" ? "€" : currency == "USD" ? "$" : currency + " "
        return symbol + String(format: "%.2f", value)
    }

    private static func tokens(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// The label in the title bar, such as "≈ €1.84". A "+" says that some calls have no price.
    var label: String {
        "≈ " + SessionCost.amount(total, currency) + (unpricedCalls > 0 ? "+" : "")
    }

    /// The tooltip: the chat that runs now, the tokens, and what the figure means on this host.
    func tooltip(on host: ClaudeHost) -> String {
        var lines = [
            "This tab’s session on \(host.title): \(label)",
            "The chat that runs now: ≈ \(SessionCost.amount(chat, currency))",
            "Tokens in \(calls) model calls: \(SessionCost.tokens(input)) input, \(SessionCost.tokens(cacheRead)) cache read, "
                + "\(SessionCost.tokens(cacheWrite)) cache write, \(SessionCost.tokens(output)) output",
        ]
        if unpricedCalls > 0 {
            lines.append("\(unpricedCalls) calls have no price and are not in the amount: \(unpricedModels.joined(separator: ", "))")
        }
        let rate = usdPerEuro.map { String(format: " Converted at $%.2f for €1.", $0) } ?? ""
        switch host {
        case .eu:
            lines.append("An estimate from Google Cloud list prices.\(rate) The real bill is in Google Cloud billing, which shows later.")
        case .apolix:
            lines.append("The value at Anthropic API list prices.\(rate) It is not a charge: the subscription is not billed per token.")
        }
        return lines.joined(separator: "\n")
    }
}

/// The right end of the tab strip: the session cost, the EU pill, and the Apolix | EU switch of the selected tab.
/// The switch and the cost show as Developer Settings say; the EU pill shows on every EU tab.
final class HostBarView: NSView {
    /// Called when the consultant picks the other host. The switch shows the old host until `update` says otherwise.
    var onSwitch: ((ClaudeHost) -> Void)?

    private let costLabel = NSTextField(labelWithString: "")
    private let pill = EUPillView()
    private let control = HostSwitchView()
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        costLabel.font = NSFont(name: "ObjectSans-Regular", size: 12) ?? .systemFont(ofSize: 12)
        costLabel.textColor = BarColors.dimText
        costLabel.setAccessibilityLabel("Session cost")
        costLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.onPick = { [weak self] host in self?.onSwitch?(host) }

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [costLabel, pill, control] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(view)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(host: .apolix, showSwitch: false, cost: nil, showCost: false, switching: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows the state of the selected tab. `cost` is nil until the chat page has reported one.
    /// While `switching`, the switch waits for the switch that runs.
    func update(host: ClaudeHost, showSwitch: Bool, cost: SessionCost?, showCost: Bool, switching: Bool) {
        control.selected = host
        control.isEnabled = !switching
        control.isHidden = !showSwitch
        pill.isHidden = host != .eu
        let shown = showCost ? cost : nil
        costLabel.isHidden = shown == nil
        costLabel.stringValue = shown?.label ?? ""
        costLabel.toolTip = shown?.tooltip(on: host)
        isHidden = control.isHidden && pill.isHidden && costLabel.isHidden
    }

    #if DEBUG
    var costText: String { costLabel.isHidden ? "-" : costLabel.stringValue }
    #endif
}

/// The EU pill: a green capsule with a shield and "EU", so that a tab on Claude in the EU is plain to see.
/// Drawn by hand so that it stays crisp at the height of the tabs, in the dark and the light appearance.
final class EUPillView: NSView {
    private static let font = NSFont(name: "PPObjectSans-Semibold", size: 11) ?? .systemFont(ofSize: 11, weight: .semibold)
    private static let height: CGFloat = 22
    private static let text = "EU"

    private struct Palette { let fill: NSColor; let stroke: NSColor; let ink: NSColor }

    private var palette: Palette {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
        }
        return dark
            ? Palette(fill: rgb(38, 201, 129, 0.16), stroke: rgb(52, 211, 141, 0.55), ink: rgb(110, 231, 175))
            : Palette(fill: rgb(220, 245, 232), stroke: rgb(22, 150, 92, 0.45), ink: rgb(10, 122, 72))
    }

    private var attributedText: NSAttributedString {
        NSAttributedString(string: Self.text, attributes: [.font: Self.font, .foregroundColor: palette.ink, .kern: 0.6])
    }

    private var glyph: NSImage? {
        // The tick in the colour of the title bar, the shield in the green of the text.
        let tick = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
            ? NSColor(srgbRed: 11/255, green: 37/255, blue: 69/255, alpha: 1) : NSColor.white
        let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .bold)
            .applying(.init(paletteColors: [tick, palette.ink]))
        return NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    init() {
        super.init(frame: .zero)
        toolTip = "This tab runs on \(ClaudeHost.eu.summary). Client data stays in the EU."
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("EU host")
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let textWidth = ceil(attributedText.size().width)
        return NSSize(width: 8 + 11 + 4 + textWidth + 9, height: Self.height)
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = self.palette
        // A half-point inset puts the one-point outline on the pixel grid.
        let outline = bounds.insetBy(dx: 0.5, dy: 0.5)
        let capsule = NSBezierPath(roundedRect: outline, xRadius: outline.height / 2, yRadius: outline.height / 2)
        palette.fill.setFill()
        capsule.fill()
        palette.stroke.setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        var x: CGFloat = 8
        if let glyph {
            let size = glyph.size
            let rect = NSRect(x: x + (11 - size.width) / 2, y: round((bounds.height - size.height) / 2), width: size.width, height: size.height)
            glyph.draw(in: rect)
            x += 11 + 4
        }
        attributedText.draw(at: NSPoint(x: x, y: capCentredTop(Self.font, in: bounds)))
    }
}

/// The Apolix | EU switch in the tab strip, drawn like the tabs: the picked host has the surface of a selected tab.
final class HostSwitchView: NSView {
    var onPick: ((ClaudeHost) -> Void)?
    var selected: ClaudeHost = .apolix { didSet { needsDisplay = true; updateAccessibility() } }
    var isEnabled = true { didSet { needsDisplay = true } }
    private var hovered: ClaudeHost? { didSet { if hovered != oldValue { needsDisplay = true } } }

    private static let font = NSFont(name: "ObjectSans-Regular", size: 12) ?? .systemFont(ofSize: 12)
    private static let selectedFont = NSFont(name: "PPObjectSans-Semibold", size: 12) ?? .boldSystemFont(ofSize: 12)
    private static let hosts: [ClaudeHost] = [.apolix, .eu]
    private static let padding: CGFloat = 11

    init() {
        super.init(frame: .zero)
        toolTip = "The Claude host of this tab. A switch starts a new session in the tab."
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Claude host")
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func width(of host: ClaudeHost) -> CGFloat {
        ceil(NSAttributedString(string: host.title, attributes: [.font: Self.selectedFont]).size().width) + Self.padding * 2
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.hosts.map(width(of:)).reduce(4, +), height: 26)
    }

    private func segmentRect(_ host: ClaudeHost) -> NSRect {
        let first = width(of: .apolix)
        return host == .apolix ? NSRect(x: 2, y: 2, width: first, height: bounds.height - 4)
            : NSRect(x: 2 + first, y: 2, width: width(of: .eu), height: bounds.height - 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = BarColors(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua)
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        colors.border.setStroke()
        track.lineWidth = 1
        track.stroke()
        for host in Self.hosts {
            let rect = segmentRect(host)
            let isSelected = host == selected
            if isSelected || (hovered == host && isEnabled) {
                let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                (isSelected ? colors.selected : colors.hover).setFill()
                shape.fill()
                if isSelected {
                    colors.selectedBorder.setStroke()
                    shape.lineWidth = 1
                    shape.stroke()
                }
            }
            let color = isSelected ? colors.text : colors.dim
            let text = NSAttributedString(string: host.title, attributes: [
                .font: isSelected ? Self.selectedFont : Self.font,
                .foregroundColor: isEnabled ? color : color.withAlphaComponent(0.5),
            ])
            let font = isSelected ? Self.selectedFont : Self.font
            text.draw(at: NSPoint(x: round(rect.midX - text.size().width / 2), y: capCentredTop(font, in: rect)))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    private func host(at event: NSEvent) -> ClaudeHost? {
        let point = convert(event.locationInWindow, from: nil)
        return Self.hosts.first { segmentRect($0).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) { hovered = host(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let host = host(at: event), host != selected else { return }
        onPick?(host)
    }

    private func updateAccessibility() {
        setAccessibilityValue(selected.title)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPick?(selected == .eu ? .apolix : .eu)
        return true
    }
}

/// The top of a line of text in a flipped view, so that its capital letters sit in the middle of `rect`
/// (the line box has room for descenders, which would push capitals up).
func capCentredTop(_ font: NSFont, in rect: NSRect) -> CGFloat {
    round(rect.midY + font.capHeight / 2 - font.ascender)
}

/// The colours of the host bar: the tab colours of the Zeus chat theme on a dark title bar, and their light
/// counterparts when the chat page is light.
struct BarColors {
    let border, selected, selectedBorder, hover, text, dim: NSColor

    init(dark: Bool) {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
        if dark {
            (border, selected, selectedBorder, hover, text, dim) =
                (TabColors.border, TabColors.selected, TabColors.selectedBorder, TabColors.hover, TabColors.text, TabColors.dimText)
        } else {
            (border, selected, selectedBorder, hover, text, dim) =
                (rgb(201, 214, 228), rgb(255, 255, 255), rgb(176, 193, 214), rgb(228, 236, 244), rgb(11, 37, 69), rgb(84, 104, 130))
        }
    }

    /// The cost label follows the appearance of the window.
    static let dimText = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? NSColor(srgbRed: 84/255, green: 104/255, blue: 130/255, alpha: 1) : TabColors.dimText
    }
}
