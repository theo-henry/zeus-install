import AppKit

/// The right end of the tab strip: the session cost, the green EU badge, and the Standard | EU switch (ported from #30, now app-wide).
/// The switch and the cost show as Developer Settings say; the EU badge shows on every window while the app is in EU mode.
final class ModeBarView: NSView {
    var onSwitch: ((ZeusMode) -> Void)?

    private let costLabel = NSTextField(labelWithString: "")
    private let badge = EUBadgeView()
    private let control = ModeSwitchView()
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        costLabel.font = NSFont(name: "ObjectSans-Regular", size: 12) ?? .systemFont(ofSize: 12)
        costLabel.textColor = BarColors.dimText
        costLabel.setAccessibilityLabel("Session cost")
        costLabel.lineBreakMode = .byTruncatingHead
        costLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.onPick = { [weak self] mode in self?.onSwitch?(mode) }
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [costLabel, badge, control] as [NSView] {
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    func update(mode: ZeusMode, showSwitch: Bool, cost: SessionCost?, switching: Bool) {
        control.selected = mode
        control.isEnabled = !switching
        control.isHidden = !showSwitch
        badge.isHidden = mode != .eu
        costLabel.isHidden = cost == nil
        costLabel.stringValue = cost?.label ?? ""
        costLabel.toolTip = cost?.tooltip
    }

    var costText: String { costLabel.isHidden ? "-" : costLabel.stringValue }
    var badgeShown: Bool { !badge.isHidden }
    var switchShown: Bool { !control.isHidden }
}

/// The EU badge: a green capsule with a shield and "EU", so that a window on Claude in the EU is plain to see.
final class EUBadgeView: NSView {
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
        let tick = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
            ? NSColor(srgbRed: 11/255, green: 37/255, blue: 69/255, alpha: 1) : NSColor.white
        let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .bold)
            .applying(.init(paletteColors: [tick, palette.ink]))
        return NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    init() {
        super.init(frame: .zero)
        toolTip = "EU mode: Claude runs on Google Cloud Vertex AI in the EU. Client data stays in the EU."
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("EU mode")
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 8 + 11 + 4 + ceil(attributedText.size().width) + 9, height: Self.height)
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = self.palette
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
            glyph.draw(in: NSRect(x: x + (11 - size.width) / 2, y: round((bounds.height - size.height) / 2), width: size.width, height: size.height))
            x += 11 + 4
        }
        attributedText.draw(at: NSPoint(x: x, y: capCentredTop(Self.font, in: bounds)))
    }
}

/// The Standard | EU switch, drawn like the tabs: the mode in use has the surface of a selected tab.
final class ModeSwitchView: NSView {
    var onPick: ((ZeusMode) -> Void)?
    var selected: ZeusMode = .standard { didSet { needsDisplay = true; setAccessibilityValue(selected.title) } }
    var isEnabled = true { didSet { needsDisplay = true } }
    private var hovered: ZeusMode? { didSet { if hovered != oldValue { needsDisplay = true } } }

    private static let font = NSFont(name: "ObjectSans-Regular", size: 12) ?? .systemFont(ofSize: 12)
    private static let selectedFont = NSFont(name: "PPObjectSans-Semibold", size: 12) ?? .boldSystemFont(ofSize: 12)
    private static let modes: [ZeusMode] = [.standard, .eu]
    private static let padding: CGFloat = 11

    init() {
        super.init(frame: .zero)
        toolTip = "Standard: your Claude login. EU: Claude in the EU (Vertex AI), for client data. A switch ends the open chats and starts new ones."
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Claude mode")
        setAccessibilityValue(selected.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func width(of mode: ZeusMode) -> CGFloat {
        ceil(NSAttributedString(string: mode.title, attributes: [.font: Self.selectedFont]).size().width) + Self.padding * 2
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.modes.map(width(of:)).reduce(4, +), height: 26)
    }

    private func segmentRect(_ mode: ZeusMode) -> NSRect {
        let first = width(of: .standard)
        return mode == .standard ? NSRect(x: 2, y: 2, width: first, height: bounds.height - 4)
            : NSRect(x: 2 + first, y: 2, width: width(of: .eu), height: bounds.height - 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = BarColors(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua)
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        colors.border.setStroke()
        track.lineWidth = 1
        track.stroke()
        for mode in Self.modes {
            let rect = segmentRect(mode)
            let isSelected = mode == selected
            if isSelected || (hovered == mode && isEnabled) {
                let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                (isSelected ? colors.selected : colors.hover).setFill()
                shape.fill()
                if isSelected {
                    colors.selectedBorder.setStroke()
                    shape.lineWidth = 1
                    shape.stroke()
                }
            }
            let font = isSelected ? Self.selectedFont : Self.font
            let color = isSelected ? colors.text : colors.dim
            let text = NSAttributedString(string: mode.title, attributes: [
                .font: font, .foregroundColor: isEnabled ? color : color.withAlphaComponent(0.5),
            ])
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

    private func mode(at event: NSEvent) -> ZeusMode? {
        let point = convert(event.locationInWindow, from: nil)
        return Self.modes.first { segmentRect($0).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) { hovered = mode(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let mode = mode(at: event), mode != selected else { return }
        onPick?(mode)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPick?(selected == .eu ? .standard : .eu)
        return true
    }
}

/// The top of a line of text in a flipped view, so that its capital letters sit in the middle of `rect`.
func capCentredTop(_ font: NSFont, in rect: NSRect) -> CGFloat {
    round(rect.midY + font.capHeight / 2 - font.ascender)
}

/// The colours of the mode bar: the tab colours of the Zeus chat theme, and their light counterparts.
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

    static let dimText = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? NSColor(srgbRed: 84/255, green: 104/255, blue: 130/255, alpha: 1) : TabColors.dimText
    }
}

/// The euro rate of the US dollar amounts that Zeus Editor reports: the European Central Bank's daily reference rate,
/// fetched at most once a day and kept in the settings. Until a rate is known, the cost shows in dollars.
enum EuroRate {
    private static let source = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

    /// US dollars for one euro, and the ECB date of the rate.
    static var current: (usdPerEuro: Double, date: String)? {
        // ZEUS_APP_EURO_RATE="1.05@2026-11-16" fixes the rate (for tests).
        if let fixed = ProcessInfo.processInfo.environment["ZEUS_APP_EURO_RATE"]?.split(separator: "@"), fixed.count == 2,
           let rate = Double(fixed[0]), rate > 0 { return (rate, String(fixed[1])) }
        let rate = Preferences.usdPerEuro
        guard rate > 0, let date = Preferences.usdPerEuroDate else { return nil }
        return (rate, date)
    }

    /// Fetches a new rate when the kept one is older than a day. No user data goes with the request.
    static func refresh() {
        if let fetched = Preferences.usdPerEuroFetchedAt, Date().timeIntervalSince(fetched) < 24 * 3600, current != nil { return }
        if ProcessInfo.processInfo.environment["ZEUS_APP_EURO_RATE"] != nil { return }
        var request = URLRequest(url: source, timeoutInterval: 10)
        request.setValue("Zeus", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let parsed = parse(String(decoding: data, as: UTF8.self)) else {
                Trace.log("euro rate: not fetched")
                return
            }
            DispatchQueue.main.async {
                Preferences.usdPerEuro = parsed.usdPerEuro
                Preferences.usdPerEuroDate = parsed.date
                Preferences.usdPerEuroFetchedAt = Date()
                Trace.log("euro rate: \(parsed.usdPerEuro) USD per EUR on \(parsed.date)")
                CostDisplay.refresh()
            }
        }.resume()
    }

    /// `<Cube time='2026-11-16'>` … `<Cube currency='USD' rate='1.0812'/>`
    static func parse(_ xml: String) -> (usdPerEuro: Double, date: String)? {
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
                  let range = Range(match.range(at: 1), in: xml) else { return nil }
            return String(xml[range])
        }
        guard let rate = first(#"currency=['"]USD['"]\s+rate=['"]([0-9.]+)['"]"#).flatMap(Double.init), rate > 0,
              let date = first(#"time=['"](\d{4}-\d{2}-\d{2})['"]"#) else { return nil }
        return (rate, date)
    }
}

/// The EU workspace (`~/Code/zeus-eu`): EU mode needs its own Zeus workspace. At each start the app clones it when it is missing,
/// from the same repo as `~/Code/zeus`, in the background; the switch shows when it is ready.
enum EUWorkspace {
    private static var running = false
    static var isCloning: Bool { running }

    static func ensure() {
        let target = ZeusMode.eu.workspace
        let manager = FileManager.default
        guard !running, !manager.fileExists(atPath: target),
              manager.fileExists(atPath: Paths.zeusDir + "/.git") else { return }
        running = true
        Trace.log("eu workspace: cloning into \(target)")
        DispatchQueue.global(qos: .utility).async {
            let result = clone(into: target)
            DispatchQueue.main.async {
                running = false
                Trace.log("eu workspace: \(result ?? "ready")")
                ModeSwitch.refresh()
            }
        }
    }

    /// Clones the repo of ~/Code/zeus, with its objects as a local reference (fast, and independent after `--dissociate`),
    /// into a hidden folder first, so that a half clone never looks like a workspace. Nil when done, else why not.
    private static func clone(into target: String) -> String? {
        var env = ShellEnvironment.make()
        // Never wait for a password: the clone runs in the background, with no one to answer.
        env["GIT_TERMINAL_PROMPT"] = "0"
        guard let remote = Shell.run("/usr/bin/env", ["git", "-C", Paths.zeusDir, "remote", "get-url", "origin"], environment: env, timeout: 15),
              remote.status == 0 else { return "not cloned: ~/Code/zeus has no origin" }
        let url = remote.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = url.range(of: #"[\w.-]+/[\w.-]+?(?=(\.git)?$)"#, options: .regularExpression).map { String(url[$0]) }
        let partial = (target as NSString).deletingLastPathComponent + "/.zeus-eu.partial"
        try? FileManager.default.removeItem(atPath: partial)
        let options = ["--reference-if-able", Paths.zeusDir, "--dissociate", "--quiet"]
        // `gh repo clone` uses the GitHub login of the Zeus setup; git with the same URL is the fallback.
        var run = slug.flatMap { Shell.run("/usr/bin/env", ["gh", "repo", "clone", $0, partial, "--"] + options, environment: env, timeout: 600) }
        if run?.status != 0 {
            try? FileManager.default.removeItem(atPath: partial)
            run = Shell.run("/usr/bin/env", ["git", "clone"] + options + [url, partial], environment: env, timeout: 600)
        }
        guard let run, run.status == 0, FileManager.default.fileExists(atPath: partial + "/scripts/zeus.py") else {
            try? FileManager.default.removeItem(atPath: partial)
            return "not cloned: \((run?.errors ?? "timed out").split(separator: "\n").last ?? "")"
        }
        do {
            try FileManager.default.moveItem(atPath: partial, toPath: target)
        } catch {
            try? FileManager.default.removeItem(atPath: partial)
            return "not cloned: \(error.localizedDescription)"
        }
        return nil
    }
}
