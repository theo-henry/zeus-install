import Foundation

/// The pages that the chat window shows before the chat page is ready.
enum StatusPage {
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let style = """
    \(Brand.fontCSS)
    :root { color-scheme:dark; --bg:#0b2545; --card:#0d2a4e; --ink:#f1f6f9; --muted:#c7dbe6; --line:#1a3a64; --accent:#3772ff;
            --bad:#ff6b72; --log:#071d38; --logink:#a9bdd5; }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.5 "Object Sans", -apple-system, sans-serif;
           display:flex; min-height:100vh; align-items:center; justify-content:center; padding:32px 16px; }
    main { width:100%; max-width:760px; }
    h1 { font-size:20px; font-weight:600; margin:0 0 4px; display:flex; align-items:center; gap:10px; }
    p { color:var(--muted); margin:0 0 16px; }
    ::selection { background:#24477a; }
    :focus-visible { outline:2px solid #5b8cff; outline-offset:3px; }
    @media(prefers-reduced-motion:reduce) { *, *::before, *::after { animation:none!important; transition:none!important; } }
    pre { background:var(--log); color:var(--logink); font:12px/1.45 ui-monospace, Menlo, monospace; padding:12px 14px;
          border-radius:8px; max-height:340px; overflow:auto; white-space:pre-wrap; word-break:break-word; margin:8px 0 0; }
    .bad { color:var(--bad); }
    .actions { display:flex; gap:8px; margin-top:18px; flex-wrap:wrap; }
    button { font:inherit; padding:7px 14px; border-radius:7px; border:1px solid var(--line); background:var(--card);
             color:var(--ink); cursor:pointer; }
    button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
    """

    private static let script = """
    function send(m){ window.webkit.messageHandlers.zeusApp.postMessage(m); }
    """

    /// An empty page in the colour of the loading screen, for the moment between two sessions of a tab.
    static let blank = "<!doctype html><html><head><meta charset=\"utf-8\"><style>html,body{margin:0;height:100%;background:#0b2545}</style></head><body></body></html>"

    /// The page of a session that did not start. A failed EU start says that nothing started on Apolix,
    /// and has no setup button: the Zeus setup does not repair the Google Cloud sign-in.
    static func failed(message: String, log: String, host: ClaudeHost = .apolix) -> String {
        let title = host == .eu ? "Zeus did not start on EU" : "Zeus did not start"
        let note = host == .eu
            ? "<p>Nothing started on Apolix instead. To work on Apolix, pick it with the host switch in the title bar.</p>"
            : ""
        let setup = host == .eu ? "" : "<button onclick=\"send('setup')\">Run the Zeus setup</button>"
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>\(style)</style><script>\(script)</script></head>
        <body><main>
          <h1 class="bad">\(title)</h1>
          <p>\(escape(message))</p>
          \(note)
          <pre id="log">\(escape(log.isEmpty ? "(no output)" : log))</pre>
          <div class="actions">
            <button class="primary" onclick="send('retry')">Try again</button>
            \(setup)
            <button onclick="send('copy-log')">Copy the output</button>
          </div>
        </main>
        <script>var p=document.getElementById('log'); p.scrollTop=p.scrollHeight;</script>
        </body></html>
        """
    }
}
