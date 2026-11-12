import Foundation

/// The pages that the chat window shows before the chat page is ready.
enum StatusPage {
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let style = """
    :root { --bg:#f4f7fb; --card:#ffffff; --ink:#18243f; --muted:#5b6782; --line:#dbe3ee; --accent:#3d6df2;
            --bad:#c23a3a; --log:#0f1626; --logink:#c9d4e8; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#10151f; --card:#171e2c; --ink:#e6ecf7; --muted:#97a3bb; --line:#263044; --accent:#6c93ff;
              --bad:#ff7b7b; --log:#0a0f19; --logink:#b9c5da; }
    }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif;
           display:flex; min-height:100vh; align-items:center; justify-content:center; padding:32px 16px; }
    main { width:100%; max-width:760px; }
    h1 { font-size:20px; font-weight:600; margin:0 0 4px; display:flex; align-items:center; gap:10px; }
    p { color:var(--muted); margin:0 0 16px; }
    .spinner { width:16px; height:16px; border:2px solid var(--line); border-top-color:var(--accent); border-radius:50%;
               animation:spin .8s linear infinite; }
    @keyframes spin { to { transform:rotate(360deg); } }
    details { margin-top:8px; }
    summary { cursor:pointer; color:var(--muted); font-size:13px; }
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
    window.zeusSetLog = function(text){
      var pre = document.getElementById('log'); if (!pre) return;
      var atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 8;
      pre.textContent = text || '';
      if (atEnd) pre.scrollTop = pre.scrollHeight;
    };
    """

    static func failed(message: String, log: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>\(style)</style><script>\(script)</script></head>
        <body><main>
          <h1 class="bad">Zeus did not start</h1>
          <p>\(escape(message))</p>
          <pre id="log">\(escape(log.isEmpty ? "(no output)" : log))</pre>
          <div class="actions">
            <button class="primary" onclick="send('retry')">Try again</button>
            <button onclick="send('setup')">Run the Zeus setup</button>
            <button onclick="send('copy-log')">Copy the output</button>
          </div>
        </main>
        <script>var p=document.getElementById('log'); p.scrollTop=p.scrollHeight;</script>
        </body></html>
        """
    }
}
