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
    .launch { text-align:center; max-width:480px; }
    .mark { width:104px; height:104px; margin:0 auto 28px; animation:charge 2.4s ease-in-out infinite alternate; }
    .mark svg { width:100%; height:100%; }
    .launch h1 { display:block; font-size:28px; letter-spacing:-.02em; }
    .launch p { margin:12px 0 28px; }
    .track { height:2px; background:var(--line); overflow:hidden; margin-bottom:14px; }
    .track span { display:block; height:100%; width:28%; background:#5b8cff; animation:check 1.6s ease-in-out infinite; }
    .steps { display:flex; justify-content:space-between; color:#a9bdd5; font-size:12px; margin-bottom:24px; }
    .launch details { text-align:left; }
    @keyframes charge { to { filter:drop-shadow(0 0 18px #3772ff88); } }
    @keyframes check { from { transform:translateX(-100%); } to { transform:translateX(460%); } }
    @media(prefers-reduced-motion:reduce) { *, *::before, *::after { animation:none!important; transition:none!important; } }
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
      const step = document.getElementById('step');
      if(step && /claude|chat:|starting session/i.test(text)) step.textContent = 'Connecting your session';
      if (atEnd) pre.scrollTop = pre.scrollHeight;
    };
    """

    static func starting(log: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>\(style)</style><script>\(script)</script></head>
        <body><main class="launch">
          <div class="mark" aria-hidden="true">\(Brand.logo)</div>
          <h1>Starting Zeus</h1>
          <p id="step" role="status">Checking for updates</p>
          <div class="track" role="progressbar" aria-label="Starting Zeus"><span></span></div>
          <div class="steps"><span>Update</span><span>Connect</span><span>Ready</span></div>
          <details><summary>Show startup output</summary><pre id="log">\(escape(log))</pre></details>
        </main></body></html>
        """
    }

    /// The body of an async function that the chat page runs once after the startup page.
    /// Arguments: left, top, size (the startup logo in page points), logo (SVG text), and reduce
    /// (the system Reduce motion setting, which the app reads).
    /// It draws the logo where the startup page showed it, resolves once that frame is on screen
    /// (the app then fades out the startup page), and breaks the logo into particles that drift
    /// out over the chat landing page. The chat is usable at once: the layer takes no input.
    static let arrivalScript = """
    if (reduce) return false;
    const W = innerWidth, H = innerHeight, dpr = devicePixelRatio || 1;
    const canvas = document.createElement('canvas');
    canvas.width = W * dpr; canvas.height = H * dpr;
    canvas.setAttribute('aria-hidden', 'true');
    canvas.style.cssText = 'position:fixed;inset:0;width:100vw;height:100vh;z-index:2147483647;pointer-events:none';
    document.documentElement.append(canvas);
    const ctx = canvas.getContext('2d');
    ctx.scale(dpr, dpr);
    const image = new Image();
    image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(logo);
    const loaded = await new Promise((resolve) => {
      image.onload = () => resolve(true);
      image.onerror = () => resolve(false);
      setTimeout(() => resolve(image.complete && image.naturalWidth > 0), 400);
    });
    if (!loaded) { canvas.remove(); return false; }
    const px = Math.max(1, Math.round(size * dpr));
    const off = document.createElement('canvas');
    off.width = off.height = px;
    off.getContext('2d').drawImage(image, 0, 0, px, px);
    const data = off.getContext('2d').getImageData(0, 0, px, px).data;
    const step = 2, grain = step / dpr * 1.35, particles = [];
    const cx = left + size / 2, cy = top + size / 2;
    for (let y = 0; y < px; y += step) for (let x = 0; x < px; x += step) {
      const i = (y * px + x) * 4;
      if (data[i + 3] < 120) continue;
      const sx = left + x / dpr, sy = top + y / dpr;
      const angle = Math.atan2(sy - cy, sx - cx) + (Math.random() - 0.5) * 1.2;
      const reach = 60 + Math.random() * Math.min(W, H) * 0.42;
      particles.push({ sx, sy, dx: Math.cos(angle) * reach, dy: Math.sin(angle) * reach * 0.7 + 90 * Math.random(),
        color: `rgb(${data[i]},${data[i + 1]},${data[i + 2]})`,
        delay: 0.08 + ((sx - left) / size) * 0.22 + Math.random() * 0.12 });
    }
    const draw = (t) => {
      ctx.clearRect(0, 0, W, H);
      ctx.globalCompositeOperation = 'lighter';
      for (const p of particles) {
        const k = Math.min(1, Math.max(0, (t - p.delay) / (1 - p.delay)));
        const e = 1 - Math.pow(1 - k, 3);
        ctx.globalAlpha = (1 - k) * (k > 0 ? 0.95 : 1);
        ctx.fillStyle = p.color;
        const g = grain * (1 - k * 0.55);
        ctx.fillRect(p.sx + p.dx * e, p.sy + p.dy * e, g, g);
      }
    };
    draw(0);
    const start = performance.now() + 120, duration = 1100;
    const frame = (now) => {
      const t = (now - start) / duration;
      if (t >= 1) { canvas.remove(); return; }
      draw(Math.max(0, t));
      requestAnimationFrame(frame);
    };
    await new Promise((resolve) => requestAnimationFrame(() => { resolve(); requestAnimationFrame(frame); }));
    return true;
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
