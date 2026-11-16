import AppKit
import SwiftUI

/// Zeus > Developer > Developer Settings…: a small window in the Zeus theme with the developer options.
/// Each change shows at once in every open window.
final class DeveloperSettingsWindow: NSWindowController, NSWindowDelegate {
    private static var shared: DeveloperSettingsWindow?

    static func show() {
        let controller = shared ?? DeveloperSettingsWindow()
        shared = controller
        controller.showWindow(nil)
        Front.show(controller.window)
        Front.activate()
    }

    static func close() { shared?.close() }

    private init() {
        let hosting = NSHostingView(rootView: DeveloperSettingsView())
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Developer Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = LoaderPage.background
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        DeveloperSettingsWindow.shared = nil
    }
}

/// The settings, read from and written to Preferences.
private final class DeveloperSettingsModel: ObservableObject {
    @Published var modeSwitch = Preferences.showModeSwitch { didSet { Preferences.showModeSwitch = modeSwitch; changed() } }
    @Published var costEU = Preferences.showCostEU { didSet { Preferences.showCostEU = costEU; changed() } }
    @Published var costStandard = Preferences.showCostStandard { didSet { Preferences.showCostStandard = costStandard; changed() } }

    private func changed() {
        Trace.log("developer settings: switch=\(modeSwitch) costEU=\(costEU) costStandard=\(costStandard)")
        ModeSwitch.refresh()
    }
}

private struct DeveloperSettingsView: View {
    @StateObject private var model = DeveloperSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Developer Settings").font(.custom("PPObjectSans-Semibold", size: 20))
                Text("For testing Zeus. Consultants can leave these as they are.")
                    .foregroundStyle(DimText.color)
            }
            section("Claude mode") {
                SettingRow(title: "Show Standard | EU switch",
                           detail: "The switch in the tab strip, on a Mac with the EU workspace. In EU mode it always shows, so the way back is never hidden.",
                           isOn: $model.modeSwitch)
            }
            section("Cost") {
                SettingRow(title: "Show session and chat total in EU",
                           detail: "An estimate at Vertex AI EU prices, from Zeus Editor. It updates after each reply.",
                           isOn: $model.costEU)
                Divider().overlay(Self.line)
                SettingRow(title: "Show session and chat total in Standard",
                           detail: "The value at Anthropic API list prices. It is not a charge on the Claude subscription.",
                           isOn: $model.costStandard)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 520)
        .font(.custom("ObjectSans-Regular", size: 13))
        .foregroundStyle(Brand.foreground)
        .tint(Brand.accent)
        .background(Brand.background)
    }

    private static let line = Color(red: 26/255, green: 58/255, blue: 100/255)

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.custom("PPObjectSans-Semibold", size: 11))
                .tracking(0.8)
                .foregroundStyle(DimText.color)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Self.line))
        }
    }
}

private enum DimText {
    static let color = Color(red: 169/255, green: 189/255, blue: 213/255)
}

private struct SettingRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.custom("PPObjectSans-Semibold", size: 13.5))
                Text(detail)
                    .font(.custom("ObjectSans-Regular", size: 12))
                    .foregroundStyle(DimText.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }
}
