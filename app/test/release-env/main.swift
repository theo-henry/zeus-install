import Foundation

// The parts of EUMode.swift that Environment.swift uses.
enum ZeusMode { case standard, eu }
struct EUProfile {
    var workspace: String
    var editorStateDir: String
    static func load() -> EUProfile { EUProfile(workspace: Paths.home + "/Code/zeus-eu", editorStateDir: Paths.home + "/.zeus/eu/editor") }
}

// Prints what Environment.swift makes of ZEUS_EDITOR_STATE_DIR and ZEUS_APP_TRACE.
print("value=\(DebugEnvironment.value("ZEUS_APP_TRACE") ?? "-")")
print("editor=\(Paths.editorStateDir(for: .standard))")
print("command-editor=\(ShellEnvironment.make()["ZEUS_EDITOR_STATE_DIR"] ?? "-")")
