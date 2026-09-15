/* Burn — web demo. A Mac desktop drawn in the page, with Burn running on it.
 *
 * The desktop, the menu bar and the Claude Code session behind everything are drawn here; Burn's panel, Settings
 * and launchers are re-made in HTML from the app's own rules — the pace maths, the alert rules, the card tints —
 * over a clock that runs at sixty times speed, so an afternoon of plan limits goes by in a few minutes. What a
 * page cannot do (open your Terminal, sign you in, launch at login) is said so, not faked. */
(() => {
  const params = new URLSearchParams(location.search);
  const embedded = params.has('embed');
  document.documentElement.classList.toggle('embedded', embedded);
  const SPEED = Math.max(1, Number(params.get('speed')) || 60);
  const POSTER_BELOW = 640;
  const W = 1280, H = 800;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const h = (tag, attrs = {}, ...kids) => {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'class') el.className = v; else if (k === 'html') el.innerHTML = v; else if (k.startsWith('on')) el.addEventListener(k.slice(2), v); else el.setAttribute(k, v);
    }
    for (const kid of kids) if (kid != null) el.append(kid);
    return el;
  };

  // ── poster or page: chosen from the width at hand, one way only ───────────────────────────────────────────────
  let showing = null;
  function choose() {
    const wide = document.documentElement.clientWidth >= POSTER_BELOW;
    if (showing === 'page' || (showing === 'poster' && !wide)) return;
    showing = wide ? 'page' : 'poster';
    document.body.innerHTML = '';
    wide ? page() : poster();
  }
  function poster() {
    document.body.append(h('figure', { class: 'poster' },
      h('img', { src: 'poster.png', width: 1280, height: 800, alt: "Burn's panel open on a Mac desktop: a row per account with a bar per window, a pace tick on each bar, a yellow reset on the window that won't last, and a Claude Code session running behind it." }),
      h('figcaption', { html: 'This is Burn on a Mac. The demo behind this picture wants a pointer and a keyboard — open this page on a Mac to try it, or <a href="../">get Burn</a> and press ⌥Space.' })));
  }

  // ── the accounts: the calm review set, plus a rate per window so time can pass ───────────────────────────────
  const GLYPH = {
    claude: '<svg viewBox="0 0 16 16"><path d="M8 2v12M2 8h12M3.8 3.8l8.4 8.4M12.2 3.8l-8.4 8.4"/></svg>',
    gpt: '<svg viewBox="0 0 16 16"><path d="M8 1.8l5.4 3.1v6.2L8 14.2l-5.4-3.1V4.9z"/></svg>',
    grok: '<svg viewBox="0 0 16 16"><path d="M11.5 3.5l-7 9"/></svg>',
    cursor: '<svg viewBox="0 0 16 16"><path d="M8 2l5.2 3v6L8 14l-5.2-3V5z M8 8l5.2-3M8 8v6M8 8L2.8 5"/></svg>',
    copilot: '<svg viewBox="0 0 16 16"><path d="M8 2.5c.6 2.8 2.2 4.4 5 5-2.8.6-4.4 2.2-5 5-.6-2.8-2.2-4.4-5-5 2.8-.6 4.4-2.2 5-5z" fill="#fff" stroke="none"/></svg>',
  };
  const HOUR = 3600, DAY = 86400;
  const win = (id, title, kind, length, used, rate, resetIn, extra = {}) => ({ id, title, kind, length, used, rate, resetIn, prev: used, ...extra });
  const accounts = [
    { id: 'personal', vendor: 'claude', tile: 'claude', label: 'Personal', plan: 'Max 5× · $100/mo', identity: 'you@example.com', typical: 6, app: 'Claude',
      windows: [win('session', 'Session', 'session', 5 * HOUR, 68, 28, 129 * 60), win('weekly', 'Weekly', 'weekly', 7 * DAY, 63, 2.2, 1.3 * DAY)] },
    { id: 'studio', vendor: 'claude', tile: 'claude', label: 'Studio', plan: 'Team · Max 5× · $150/mo', identity: 'you@studio.example', typical: 9, app: 'Claude',
      windows: [win('session', 'Session', 'session', 5 * HOUR, 31, 6, 133 * 60), win('weekly', 'Weekly', 'weekly', 7 * DAY, 44, 0.4, 4.6 * DAY), win('fable', 'Fable', 'model', 7 * DAY, 12, 0.2, 4.6 * DAY)] },
    { id: 'chatgpt', vendor: 'codex', tile: 'gpt', label: 'ChatGPT', plan: 'Plus · Codex quota · $20/mo', identity: 'you@example.com', typical: 8, app: 'ChatGPT', foot: '2 reset credits',
      windows: [win('session', 'Session', 'session', 5 * HOUR, 42, 16, 244 * 60), win('weekly', 'Weekly', 'weekly', 7 * DAY, 66, 0.25, 4.8 * DAY)] },
    { id: 'grok', vendor: 'grok', tile: 'grok', label: 'Grok', plan: 'SuperGrok · weekly pool · $30/mo', identity: 'you@example.com', app: 'Grok',
      windows: [win('pool', 'Weekly', 'weekly', 7 * DAY, 7, 0.3, 2.2 * DAY)] },
    { id: 'cursor', vendor: 'cursor', tile: 'cursor', label: 'Cursor', plan: 'Pro+ · included usage · $60/mo', identity: 'you@example.com', app: 'Cursor',
      windows: [win('monthly', 'Monthly', 'monthly', 30 * DAY, 51, 0.15, 15 * DAY)] },
    { id: 'copilot', vendor: 'copilot', tile: 'copilot', label: 'Copilot', plan: 'Pro · monthly · $10/mo', identity: '@you', app: 'GitHub Copilot',
      windows: [win('premium', 'Premium', 'monthly', 30 * DAY, 22, 0.05, 15 * DAY)] },
  ];
  const settings = {
    notify: true, threshold: 85, notifyReset: true, notifyPace: true, notifySurge: true, surgeMultiple: 3, quiet: false,
    paceTicks: true, vendorStatus: true, poll: 180, appearance: 'dark', menuText: false,
    hidden: new Set(), installed: new Set(),
  };

  // ── time: the viewer's clock, then sixty times faster ─────────────────────────────────────────────────────────
  const simStart = new Date();
  let simNow = new Date(simStart);
  // Burn has been watching for twenty minutes when the demo starts, so the pace verdicts are in from the first frame.
  const historyStart = new Date(simStart.getTime() - 20 * 60 * 1000);
  for (const a of accounts) for (const w of a.windows) { w.resetAt = new Date(simStart.getTime() + w.resetIn * 1000); w.periodStart = new Date(w.resetAt.getTime() - w.length * 1000); }

  const fmtClock = d => d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  const countdown = (to, from) => {
    const s = Math.max(0, (to - from) / 1000), hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60);
    return hh ? `${hh}h ${mm}m` : `${mm}m`;
  };
  /** A countdown while it is today, a weekday and time within the week, a date beyond that — the app's `Relative`. */
  const when = (date, from = simNow) => {
    const d = (date - from) / 1000;
    if (d < 20 * HOUR) return countdown(date, from);
    if (d < 6.5 * DAY) return date.toLocaleDateString('en-US', { weekday: 'short' }) + ' ' + fmtClock(date);
    return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  };
  const whenIn = (date, from = simNow) => (date - from) / 1000 < 20 * HOUR ? 'in ' + countdown(date, from) : when(date, from);
  const rateText = r => r < 10 ? `${r.toFixed(1)} %/h` : `${Math.round(r)} %/h`;
  const multipleText = m => m >= 10 ? `${Math.round(m)}×` : (m.toFixed(1).replace(/\.0$/, '') + '×');

  // ── the pace maths, as in Pace.swift ──────────────────────────────────────────────────────────────────────────
  function pace(w, now = simNow) {
    const sinceStart = (now - Math.max(w.periodStart, historyStart)) / 1000;
    const expected = clamp((1 - (w.resetAt - now) / 1000 / w.length) * 100, 0, 100);
    if (sinceStart < 15 * 60) return { verdict: 'early', expected, rate: w.rate };
    if (w.rate <= 0.05) return { verdict: 'stalled', expected, rate: 0 };
    const runOut = new Date(now.getTime() + Math.max(0, 100 - w.used) / w.rate * HOUR * 1000);
    const early = (w.resetAt - runOut) / 1000;
    const fast = w.used < 100 && early > Math.max(30 * 60, w.length * 0.1);
    return { verdict: fast ? 'fast' : 'onPace', expected, rate: w.rate, runOut, shortfall: fast ? early : null };
  }
  const multipleOf = (a, w) => (w.kind === 'session' && a.typical && w.rate > 0) ? w.rate / a.typical : null;
  const surging = (a, w, p) => { const m = multipleOf(a, w); return !!m && p.verdict !== 'early' && p.verdict !== 'stalled' && w.rate >= 10 && m >= settings.surgeMultiple; };
  const pooled = a => a.windows.filter(w => w.kind !== 'model');
  const tone = a => pooled(a).some(w => w.used >= 85) ? 'warn' : pooled(a).some(w => pace(w).verdict === 'fast') ? 'amber' : '';
  const barColor = used => used >= 85 ? 'var(--red)' : used >= 60 ? 'var(--amber)' : 'var(--green)';
  const visible = () => accounts.filter(a => !settings.hidden.has(a.id));
  /** The menu bar's account: the fullest pooled window among the visible cards. */
  const primary = () => visible().map(a => ({ a, w: pooled(a).reduce((m, w) => !m || w.used > m.used ? w : m, null) })).filter(x => x.w).sort((x, y) => y.w.used - x.w.used)[0] || null;

  // ── the page ─────────────────────────────────────────────────────────────────────────────────────────────────
  let ui = {};
  function page() {
    document.body.append(
      h('div', { class: 'intro' },
        h('h1', {}, h('img', { src: '../assets/burn-midnight.svg', alt: '' }), 'Burn', h('span', {}, 'web demo')),
        h('p', { html: 'A Mac desktop drawn in the page, with Burn running on it. The clock runs at sixty times speed. <a href="../">Get the app →</a>' })),
      h('div', { class: 'stage-box' }, h('div', { class: 'stage', id: 'stage', 'data-theme': 'dark' })),
      h('div', { class: 'outro' },
        h('span', { html: 'Click the ring — or press <kbd>⌥ Space</kbd>, the app\'s hotkey. Hover a row for its menu, a reset time for the pace, the ring for what the menu bar knows. The gear opens Settings.' }),
        h('span', { html: 'Numbers are the app\'s review fixtures; the pace, alert and tint rules are the app\'s own. <b>What a page can\'t do — open your Terminal, sign you in — it says so.</b>' })));
    const stage = $('#stage');
    stage.append(scene(), menubar(), panel(), settingsWindow(), launcherWindow(), h('div', { class: 'notifs', id: 'notifs' }), h('div', { class: 'tip', id: 'tip' }), h('div', { class: 'toast', id: 'toast' }));
    ui = { stage, box: $('.stage-box'), tip: $('#tip'), toast: $('#toast'), notifs: $('#notifs'), panel: $('#panel'), settings: $('#settings'), launch: $('#launch'), tray: $('#tray') };
    fit(); addEventListener('resize', fit);
    if (settings.appearance === 'system') applyTheme();
    matchMedia('(prefers-color-scheme: light)').addEventListener('change', applyTheme);
    wire();
    renderAll();
    requestAnimationFrame(loop);
    transcript();
    // The ring is small and the panel is the point: once the desktop is on screen, point at the ring, then open it —
    // unless the viewer has already found it.
    new IntersectionObserver(([e], io) => { if (e.isIntersecting) { io.disconnect(); introduce(); } }, { threshold: .4 }).observe(stage);
  }
  let touched = false;
  function introduce() {
    setTimeout(() => { if (touched) return; ui.tray.classList.add('pulse'); ui.stage.classList.add('hinting'); }, 350);
    setTimeout(() => { ui.tray.classList.remove('pulse'); if (!touched) openPanel(true); }, 1200);
  }
  function fit() {
    if (!ui.box) return;
    const r = ui.box.getBoundingClientRect();
    const k = embedded ? Math.min(r.width / W, r.height / H) : r.width / W;
    ui.stage.style.setProperty('--k', k);
    // Letterbox in a frame with a different shape.
    ui.stage.style.left = ((r.width - W * k) / 2) + 'px';
    ui.stage.style.top = ((r.height - H * k) / 2) + 'px';
  }

  // the desktop: a Claude Code session, which is where the burn comes from
  function scene() {
    return h('div', { class: 'win term', id: 'term' },
      h('div', { class: 'bar' }, h('span', { class: 'dots' }, h('i'), h('i'), h('i')), h('span', { class: 'title' }, 'claude-personal — 100×32')),
      h('div', { class: 'body', id: 'transcript' }),
      h('div', { class: 'status' }, h('span', { class: 'seg', id: 'statusline' }), h('span', {}, '· main'), h('span', { class: 'tokens', id: 'tokens' })));
  }
  // ── the Claude Code session: prompts typed, thinking that ticks tokens, streamed prose, tools with results ─────
  const SPIN = ['✻', '✽', '✾', '✿', '❀', '❁', '✼'];
  const VERBS = ['Thinking', 'Percolating', 'Simmering', 'Brewing', 'Cogitating', 'Mustering'];
  const TASKS = [
    [['user', 'tidy the launcher install so a rename rewrites the shim in place'],
     ['think', 2600, 380],
     ['say', 'I\'ll look at how shims are written today, then make a rename rewrite the shim rather than add a second one.'],
     ['tool', 'Read', 'Sources/Burn/Store/Launchers.swift', 'Read 212 lines', 9800],
     ['think', 1800, 420],
     ['diff', 'Sources/Burn/Store/Launchers.swift', '14 additions and 6 removals', [
       [41, ' ', 'static func install(_ account: AccountSnapshot) throws -> String {'],
       [42, '-', '    let path = binDirectory.appendingPathComponent(slug(account.label))'],
       [42, '+', '    let name = slug(account.label)'],
       [43, '+', '    if let old = Preferences.shared.installedLaunchers[account.id], old != name { remove(old) }'],
       [44, '+', '    let path = binDirectory.appendingPathComponent(name)'],
     ]],
     ['bash', 'swift test 2>&1 | tail -1', ['Executed 35 tests, with 0 failures (0 unexpected) in 0.014 seconds']],
     ['say', 'Done. Renaming an account now rewrites its command in place — `claude-studio` becomes `claude-studio-co` and the old shim is gone.']],
    [['user', 'add a test for the rename'],
     ['think', 2100, 360],
     ['tool', 'Read', 'Tests/BurnTests/LaunchersTests.swift', 'Read 48 lines', 3100],
     ['diff', 'Tests/BurnTests/LaunchersTests.swift', '11 additions', [
       [19, '+', 'func testRenameRewritesTheShim() throws {'],
       [20, '+', '    try Launchers.install(studio)'],
       [21, '+', '    try Launchers.install(renamed(studio, "Studio Co"))'],
       [22, '+', '    XCTAssertFalse(FileManager.default.fileExists(atPath: bin("claude-studio")))'],
       [23, '+', '    XCTAssertTrue(FileManager.default.fileExists(atPath: bin("claude-studio-co")))'],
       [24, '+', '}'],
     ]],
     ['bash', 'swift test --filter LaunchersTests 2>&1 | tail -1', ['Executed 4 tests, with 0 failures (0 unexpected) in 0.003 seconds']],
     ['say', 'Added `testRenameRewritesTheShim`; the suite passes.']],
    [['user', 'commit'],
     ['think', 1400, 300],
     ['bash', 'git add -A && git commit -m "Launcher shims follow renames"', ['[main 4c1e2d9] Launcher shims follow renames', ' 2 files changed, 25 insertions(+), 6 deletions(-)']],
     ['say', 'Committed as 4c1e2d9.']],
  ];
  const tokens = { up: 41_200, down: 3_800 };
  const fmtTokens = n => n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(Math.round(n));
  function transcript() {
    const body = $('#transcript'), tally = $('#tokens');
    const wait = ms => new Promise(r => setTimeout(r, ms));
    const scroll = () => { body.scrollTop = body.scrollHeight; };
    const bump = () => { tally.textContent = `↑ ${fmtTokens(tokens.up)} ↓ ${fmtTokens(tokens.down)}`; };
    const line = (cls, text = '') => { const el = h('div', { class: cls }, text); body.append(el); scroll(); return el; };
    const stream = async (el, text, prefix = '', cps = 70) => {
      for (let i = 0; i < text.length;) {
        const n = 1 + Math.floor(Math.random() * 5);
        i += n; el.textContent = prefix + text.slice(0, i);
        tokens.down += n / 4; bump(); scroll();
        await wait(1000 / cps * n + (Math.random() < .08 ? 120 : 0));
      }
    };
    const spin = async (ms, perTick, verb = VERBS[Math.floor(Math.random() * VERBS.length)]) => {
      const el = line('s'); const t0 = performance.now(); let i = 0;
      while (performance.now() - t0 < ms) {
        el.textContent = `${SPIN[i++ % SPIN.length]} ${verb}… (${Math.floor((performance.now() - t0) / 1000)}s · ↑ ${fmtTokens(tokens.up)} tokens · esc to interrupt)`;
        tokens.up += perTick * (0.6 + Math.random() * 0.8); bump();
        await wait(90);
      }
      el.remove();
    };
    (async () => {
      // pick up mid-session — the prompt already asked, the model already thinking — so tokens burn from the first second
      line('u', '> what does the panel do when a vendor is down?');
      line('a', '● It checks the status page every five minutes and puts a chip on the rows an incident affects, then backs off.');
      bump();
      let first = true;
      for (let round = 0; ; round++) {
        for (const task of TASKS) {
          if (!first) await wait(2200 + Math.random() * 1500);
          for (const step of task) {
            const [kind] = step;
            if (kind === 'user') {
              if (first) { line('u', '> ' + step[1]); first = false; await wait(250); }
              else { const el = line('u', '> '); await stream(el, step[1], '> ', 34); tokens.up += 40; await wait(500); }
            }
            if (kind === 'think') await spin(step[1], step[2]);
            if (kind === 'say') { const el = line('a', '● '); await stream(el, step[1], '● '); await wait(400); }
            if (kind === 'tool') {
              line('a', `● ${step[1]}(${step[2]})`);
              await spin(900 + Math.random() * 700, 140, step[1] === 'Read' ? 'Reading' : 'Working');
              tokens.up += step[4]; bump();
              line('t', `  ⎿  ${step[3]}`); await wait(500);
            }
            if (kind === 'diff') {
              line('a', `● Update(${step[1]})`);
              await spin(700, 260, 'Editing');
              line('t', `  ⎿  Updated ${step[1]} with ${step[2]}`);
              for (const [n, sign, text] of step[3]) { line('d' + (sign === '+' ? ' add' : sign === '-' ? ' del' : ''), `      ${String(n).padStart(3)} ${sign} ${text}`); tokens.down += 12; bump(); await wait(140); }
              await wait(500);
            }
            if (kind === 'bash') {
              line('a', `● Bash(${step[1]})`);
              await spin(1200 + Math.random() * 900, 90, 'Running');
              for (const out of step[2]) { line(out.includes('0 failures') ? 'g' : 't', `  ⎿  ${out}`); await wait(260); }
              tokens.up += 900; bump(); await wait(500);
            }
          }
        }
        // a new conversation keeps the window readable: the old one scrolls off, the tally carries on
        await wait(3000);
        if (body.childElementCount > 80) [...body.children].slice(0, body.childElementCount - 30).forEach(el => el.remove());
      }
    })();
  }

  function menubar() {
    return h('div', { class: 'menubar' },
      h('span', { class: 'apple', html: '<svg viewBox="0 0 17 20" width="13" height="15" aria-hidden="true"><path fill="currentColor" d="M14.1 10.6c0-2.3 1.9-3.4 2-3.5-1.1-1.6-2.8-1.8-3.4-1.8-1.4-.1-2.8.9-3.5.9s-1.8-.8-3-.8C4.7 5.4 3.2 6.3 2.4 7.7.6 10.8 2 15.4 3.7 17.9c.8 1.2 1.8 2.6 3.1 2.5 1.2 0 1.7-.8 3.2-.8s1.9.8 3.2.8c1.3 0 2.2-1.2 3-2.4.9-1.4 1.3-2.7 1.4-2.8-.1 0-3.5-1.4-3.5-4.6zM11.8 3.8c.7-.8 1.1-2 1-3.1-1 0-2.2.7-2.9 1.5-.6.7-1.2 1.9-1 3 1.1.1 2.2-.6 2.9-1.4z"/></svg>' }), h('span', { class: 'appname' }, 'Terminal'),
      h('span', { class: 'menus' }, ...['Shell', 'Edit', 'View', 'Window', 'Help'].map(m => h('span', {}, m))),
      h('span', { class: 'right' },
        h('span', { class: 'speed', title: 'The demo\'s clock runs at ' + SPEED + '× — an hour every minute' }, SPEED + '×'),
        h('button', { class: 'tray', id: 'tray', type: 'button', 'aria-haspopup': 'true', 'aria-expanded': 'false', 'data-tip': 'tray',
          html: '<svg viewBox="0 0 16 16"><circle class="trk" cx="8" cy="8" r="6"/><circle class="arc" id="arc" cx="8" cy="8" r="6" stroke-dasharray="37.7" stroke-dashoffset="37.7"/></svg><span class="pctText" id="pctText"></span>' }),
        h('span', { class: 'mi' }, 'wifi'), h('span', { class: 'mi' }, 'battery_full'),
        h('span', { class: 'clock', id: 'clock' })),
      h('div', { class: 'hint', id: 'hint', html: 'Burn lives in the menu bar — <b>click the ring</b>, or press <kbd>⌥ Space</kbd>' }));
  }

  function sparkPath(a) {
    const s = a.windows.find(w => w.kind === 'session'); if (!s) return null;
    const peak = 40 + (a.label.length * 23) % 50, phase = a.label.length * 4000;
    let d = '';
    for (let i = 0; i <= 64; i += 2) {
      const t = simStart.getTime() / 1000 - (64 - i) / 64 * DAY + phase;
      const y = 15 - Math.min(100, (t % s.length) / s.length * peak * 1.4) / 100 * 14;
      d += (i ? 'L' : 'M') + i + ' ' + y.toFixed(1) + ' ';
    }
    return d;
  }

  function panel() {
    const mark = '<svg class="mark" viewBox="180 139 624 719" aria-hidden="true"><defs><linearGradient id="pm" x1="317" y1="766" x2="703" y2="245" gradientUnits="userSpaceOnUse"><stop stop-color="#BD0029"/><stop offset=".38" stop-color="#E20C29"/><stop offset=".76" stop-color="#FA3435"/><stop offset="1" stop-color="#FF583F"/></linearGradient></defs><path d="M 480,326 C 350,319 242,416 238,550 C 233,694 344,800 483,800 C 632,800 746,692 746,551 C 746,512 740,479 729,449" stroke="url(#pm)" stroke-width="116" stroke-linecap="round" fill="none"/><path d="M 679,139 C 669,191 720,216 727,261 C 735,303 705,337 674,367 C 668,331 628,319 624,279 C 618,232 654,188 679,139 Z" fill="url(#pm)"/></svg>';
    const el = h('div', { class: 'panel', id: 'panel', role: 'dialog', 'aria-label': 'Burn' },
      h('div', { class: 'ph', html: mark }, h('b', {}, 'burn'),
        h('button', { type: 'button', id: 'refresh', title: 'Refresh', html: '<i class="mi">refresh</i>' }),
        h('button', { type: 'button', id: 'gear', title: 'Settings', html: '<i class="mi">settings</i>' })));
    for (const a of accounts) {
      const spark = sparkPath(a);
      const card = h('div', { class: 'acct', id: 'acct-' + a.id, 'data-id': a.id },
        h('div', { class: 'ah' },
          h('span', { class: 'tile ' + a.tile, html: GLYPH[a.tile] }),
          h('span', { class: 'nm' }, a.label), h('span', { class: 'pl', id: 'pl-' + a.id }, a.plan),
          h('span', { class: 'chip', id: 'chip-' + a.id, 'data-tip': 'chip', 'data-id': a.id, html: '<i class="mi">local_fire_department</i><span></span>' }),
          spark ? h('svg', { class: 'spark', viewBox: '0 0 64 16', html: `<path d="${spark}"/>` }) : null,
          h('span', { class: 'rowmenu' },
            a.vendor === 'claude' ? h('button', { type: 'button', title: 'Open Terminal with this account', 'data-act': 'terminal', html: '<i class="mi">terminal</i>' }) : h('button', { type: 'button', title: 'Open ' + a.app, 'data-act': 'app', html: '<i class="mi">open_in_new</i>' }),
            a.vendor === 'claude' ? h('button', { type: 'button', title: 'Copy the command', 'data-act': 'copy', html: '<i class="mi">content_copy</i>' }) : null,
            h('button', { type: 'button', title: 'Hide this account', 'data-act': 'hide', html: '<i class="mi">visibility_off</i>' }))));
      for (const w of a.windows) {
        card.append(h('div', { class: 'line' },
          h('span', { class: 'lbl' }, w.title),
          h('div', { class: 'meter', 'data-tip': 'meter', 'data-id': a.id, 'data-w': w.id }, h('i', { id: `fill-${a.id}-${w.id}` }), w.kind === 'model' ? null : h('span', { class: 'tk', id: `tk-${a.id}-${w.id}` })),
          h('span', { class: 'pct', id: `pct-${a.id}-${w.id}` }),
          h('span', { class: 'reset', id: `reset-${a.id}-${w.id}`, 'data-tip': 'reset', 'data-id': a.id, 'data-w': w.id, html: '<i class="mi">schedule</i><span></span>' })));
      }
      if (a.foot) card.append(h('div', { class: 'foot' }, a.foot));
      el.append(card);
    }
    el.append(h('div', { class: 'empty', id: 'empty', hidden: '' }, 'Every account is hidden — Settings → Accounts shows them again.'));
    return el;
  }

  function settingsWindow() {
    const sw = (key, onchange) => { const b = h('button', { type: 'button', class: 'sw' + (settings[key] ? ' on' : ''), role: 'switch', 'aria-checked': String(!!settings[key]) }); b.addEventListener('click', () => { settings[key] = !settings[key]; b.classList.toggle('on', settings[key]); b.setAttribute('aria-checked', String(settings[key])); onchange && onchange(settings[key]); renderAll(); }); return b; };
    const sel = (key, options, onchange) => { const s = h('select', { class: 'sel' }); for (const [v, t] of options) s.append(h('option', { value: v, ...(String(settings[key]) === String(v) ? { selected: '' } : {}) }, t)); s.addEventListener('change', () => { settings[key] = isNaN(s.value) ? s.value : Number(s.value); onchange && onchange(settings[key]); renderAll(); }); return s; };
    const seg = (key, options, onchange) => { const box = h('span', { class: 'seg' }); for (const [v, t] of options) { const b = h('button', { type: 'button', class: settings[key] === v ? 'on' : '' }, t); b.addEventListener('click', () => { settings[key] = v; $$('button', box).forEach(x => x.classList.toggle('on', x === b)); onchange && onchange(v); renderAll(); }); box.append(b); } return box; };
    const row = (label, control, small) => h('div', { class: 'srow' }, h('span', { class: 'l' }, label, small ? h('small', {}, small) : null), control);

    const general = h('div', { class: 'page on', id: 'page-general' },
      h('div', { class: 'sec' }, 'Refresh'),
      row('Check every', sel('poll', [[60, '1 min'], [180, '3 min'], [300, '5 min'], [600, '10 min']])),
      row('Pace ticks on the bars', sw('paceTicks')),
      row('Vendor status', sw('vendorStatus'), 'Anthropic, OpenAI, Cursor and GitHub status pages, every five minutes'),
      row('Launch at login', h('button', { type: 'button', class: 'sw', disabled: '', title: 'Only the app can register itself with macOS', style: 'opacity:.4;cursor:default' })),
      h('div', { class: 'sec' }, 'Notifications'),
      row('Notify me', sw('notify')),
      row('Nearly out at', sel('threshold', [[60, '60 %'], [75, '75 %'], [85, '85 %'], [95, '95 %']])),
      row('When a low window resets', sw('notifyReset')),
      row('When a window will run out before it resets', sw('notifyPace')),
      row('When usage is unusually high', h('span', { style: 'display:flex;gap:8px;align-items:center' }, sel('surgeMultiple', [[2, '2× my usual'], [3, '3× my usual'], [5, '5× my usual']]), sw('notifySurge'))),
      row('Quiet hours', h('span', { style: 'display:flex;gap:8px;align-items:center' }, h('span', { style: 'color:#8b93a1;font-size:12px' }, '10 PM to 7 AM'), sw('quiet'))),
      h('p', { class: 'note' }, 'Banners are quiet while the panel would tell you the same thing anyway: the same window, the same reset period. "Unusual" is measured against your own week — here, Personal\'s typical busy hour is 6 %/h.'));
    const appearance = h('div', { class: 'page', id: 'page-appearance' },
      h('div', { class: 'sec' }, 'Appearance'),
      row('Theme', seg('appearance', [['dark', 'Dark'], ['light', 'Light'], ['system', 'System']], applyTheme)),
      row('Menu bar shows', seg('menuText', [[false, 'Ring'], [true, 'Ring + percent']])),
      row('Hotkey', h('kbd', { style: 'font:600 12px var(--mono);background:rgba(255,255,255,.1);border-radius:5px;padding:2px 7px' }, '⌥ Space'), 'Record a different one in the app'),
      h('p', { class: 'note' }, 'The ring shows the fullest window across your accounts; pin more rings from the Accounts tab in the app.'));
    const accountsPage = h('div', { class: 'page', id: 'page-accounts' }, h('div', { class: 'sec' }, 'Accounts'));
    for (const a of accounts) {
      const shown = h('button', { type: 'button', class: 'sw' + (settings.hidden.has(a.id) ? '' : ' on'), role: 'switch', id: 'shown-' + a.id });
      shown.addEventListener('click', () => { settings.hidden.has(a.id) ? settings.hidden.delete(a.id) : settings.hidden.add(a.id); renderAll(); });
      const install = a.vendor === 'claude' ? h('button', { type: 'button', class: 'ghost', id: 'install-' + a.id }) : null;
      if (install) install.addEventListener('click', () => { settings.installed.add(a.id); toast(`Installed ~/.local/bin/claude-${a.id} — a two-line shim that runs Claude Code as ${a.label}.`); renderAll(); });
      accountsPage.append(h('div', { class: 'acc-row' }, h('span', { class: 'tile ' + a.tile, html: GLYPH[a.tile] }), h('span', { class: 'nm2' }, a.label), h('span', { class: 'sub' }, a.plan),
        h('span', { class: 'st' }, install, h('span', {}, 'Shown'), shown)));
    }
    accountsPage.append(h('div', { class: 'srow' }, h('span', { class: 'l' }, 'Add an account', h('small', {}, 'Claude, ChatGPT, Grok, Gemini, Cursor, Copilot')), h('button', { type: 'button', class: 'ghost', onclick: () => toast('Signing in opens the vendor\'s own login on your Mac — not something a web page can do.') }, 'Sign in…')),
      h('p', { class: 'note' }, 'The ⋯ menu on a row in the app also renames an account, sets the real plan price, and installs its claude-<name> command.'));
    const usage = h('div', { class: 'page', id: 'page-usage' },
      h('div', { class: 'sec' }, 'Usage'),
      h('div', { class: 'srow' }, h('span', { class: 'l' }, 'Personal', h('small', {}, 'Session 28 %/h · out 3:41 PM · 4.7× usual   Weekly 2.2 %/h · on pace'))),
      h('div', { class: 'srow' }, h('span', { class: 'l' }, 'API-priced', h('small', {}, '$310 today · 4× typical   $412 · 7 d   $1,380 · 30 d   13.8× the plan'))),
      h('p', { class: 'note' }, 'In the app this tab charts 90 days of your own history — every sample Burn took — under each account, with the pace of each window and what the last week and month would have cost at API list prices. The demo has no history to show, so it stops here.'));
    const tabs = h('span', { class: 'tabs' });
    for (const [id, icon, title] of [['general', 'tune', 'General'], ['appearance', 'palette', 'Appearance'], ['accounts', 'group', 'Accounts'], ['usage', 'insights', 'Usage']]) {
      tabs.append(h('button', { type: 'button', class: id === 'general' ? 'on' : '', 'data-tab': id, html: `<i class="mi">${icon}</i>${title}` }));
    }
    const el = h('div', { class: 'win settings', id: 'settings', role: 'dialog', 'aria-label': 'Burn Settings' },
      h('div', { class: 'bar' }, h('span', { class: 'dots' }, h('button', { type: 'button', title: 'Close', 'data-act': 'close-settings' }), h('i'), h('i')), tabs),
      general, appearance, accountsPage, usage);
    tabs.addEventListener('click', e => {
      const b = e.target.closest('button[data-tab]'); if (!b) return;
      $$('button', tabs).forEach(x => x.classList.toggle('on', x === b));
      $$('.page', el).forEach(p => p.classList.toggle('on', p.id === 'page-' + b.dataset.tab));
    });
    return el;
  }

  function launcherWindow() {
    return h('div', { class: 'win launch', id: 'launch' },
      h('button', { type: 'button', class: 'close', title: 'Close', 'data-act': 'close-launch' }),
      h('div', { class: 'bar' }, h('span', { class: 'dots', style: 'visibility:hidden' }, h('i'), h('i'), h('i')), h('span', { class: 'title', id: 'launch-title' }, 'Terminal')),
      h('div', { class: 'body', id: 'launch-body' }));
  }

  // ── rendering ─────────────────────────────────────────────────────────────────────────────────────────────────
  function renderAll() {
    const now = simNow;
    $('#clock').textContent = now.toLocaleDateString('en-US', { weekday: 'short' }) + ' ' + fmtClock(now);
    let anyShown = false;
    for (const a of accounts) {
      const card = $('#acct-' + a.id);
      const hidden = settings.hidden.has(a.id);
      card.classList.toggle('gone', hidden);
      if (!hidden) anyShown = true;
      card.classList.remove('warn', 'amber'); const t = tone(a); if (t) card.classList.add(t);
      let best = 0;
      for (const w of a.windows) {
        const p = pace(w);
        $(`#fill-${a.id}-${w.id}`).style.width = w.used + '%';
        $(`#fill-${a.id}-${w.id}`).style.background = barColor(w.used);
        $(`#pct-${a.id}-${w.id}`).textContent = Math.round(w.used) + '%';
        const tk = $(`#tk-${a.id}-${w.id}`);
        if (tk) { tk.style.left = p.expected + '%'; tk.classList.toggle('in', p.expected < w.used - 0.5); tk.style.display = settings.paceTicks ? '' : 'none'; }
        const r = $(`#reset-${a.id}-${w.id}`);
        r.lastElementChild.textContent = when(w.resetAt);
        r.classList.toggle('fast', p.verdict === 'fast');
        if (surging(a, w, p)) best = Math.max(best, multipleOf(a, w));
      }
      const chip = $('#chip-' + a.id);
      chip.classList.toggle('on', best > 0);
      if (best > 0) chip.lastElementChild.textContent = multipleText(best) + ' usual';
      const shown = $('#shown-' + a.id); if (shown) { shown.classList.toggle('on', !hidden); shown.setAttribute('aria-checked', String(!hidden)); }
      const install = $('#install-' + a.id); if (install) { const done = settings.installed.has(a.id); install.textContent = done ? `claude-${a.id} installed` : `Install claude-${a.id}`; install.disabled = done; }
    }
    $('#empty').hidden = anyShown;
    // the menu bar: the fullest window, as a ring
    const pr = primary();
    const arc = $('#arc'), C = 37.7;
    if (pr) { arc.style.strokeDashoffset = C * (1 - pr.w.used / 100); arc.style.stroke = barColor(pr.w.used); $('#pctText').textContent = settings.menuText ? Math.round(pr.w.used) + '%' : ''; }
    else { arc.style.strokeDashoffset = C; $('#pctText').textContent = ''; }
    // the status line in the Claude Code session runs as Personal
    const me = accounts[0], s = me.windows[0], wk = me.windows[1], sp = pace(s);
    const mark = s.used >= 85 ? 'r' : sp.verdict === 'fast' ? 'y' : '';
    $('#statusline').innerHTML = `◐ Personal · <span class="${mark}">${Math.round(s.used)}%</span> · ${countdown(s.resetAt, now)} · wk ${Math.round(wk.used)}%`;
    ui.notifs.classList.toggle('aside', ui.panel.classList.contains('on'));
  }
  function applyTheme() {
    const light = settings.appearance === 'light' || (settings.appearance === 'system' && matchMedia('(prefers-color-scheme: light)').matches);
    ui.stage.dataset.theme = light ? 'light' : 'dark';
  }

  // ── time passes ───────────────────────────────────────────────────────────────────────────────────────────────
  let last = performance.now(), acc = 0;
  function loop(t) {
    const dt = Math.min(0.1, (t - last) / 1000); last = t;
    if (!document.hidden) { step(dt * SPEED); acc += dt; }
    if (acc >= 0.25) { acc = 0; renderAll(); }
    requestAnimationFrame(loop);
  }
  function step(seconds) {
    simNow = new Date(simNow.getTime() + seconds * 1000);
    for (const a of accounts) for (const w of a.windows) {
      w.prev = w.used;
      w.used = Math.min(100, w.used + w.rate * seconds / HOUR);
      while (simNow >= w.resetAt) {
        const was = w.used;
        w.used = Math.min(100, w.rate * 0.1 + (simNow - w.resetAt) / 1000 * w.rate / HOUR);
        w.periodStart = new Date(w.resetAt); w.resetAt = new Date(w.resetAt.getTime() + w.length * 1000);
        if (w.kind !== 'model' && settings.notify && settings.notifyReset && was >= 60 && w.used <= was - 40) notify(a, `${a.label} has room again`, `${w.title} reset · ${Math.round(w.used)} % used`, `${a.id}|${w.id}|reset|${+w.resetAt}`);
      }
    }
    alerts();
  }

  // ── the alert rules, as in Alerts.swift ───────────────────────────────────────────────────────────────────────
  const delivered = new Set();
  let armed = false;
  function alerts() {
    if (!settings.notify || !armed) return;
    const hr = simNow.getHours();
    if (settings.quiet && (hr >= 22 || hr < 7)) return;
    for (const a of visible()) for (const w of pooled(a)) {
      const period = +w.resetAt, p = pace(w);
      if (w.prev < settings.threshold && w.used >= settings.threshold)
        notify(a, `${a.label} ${w.title.toLowerCase()} nearly out`, `${Math.round(w.used)} % used · resets ${whenIn(w.resetAt)}`, `${a.id}|${w.id}|critical|${period}`);
      if (settings.notifyPace && p.verdict === 'fast' && w.used >= 50)
        notify(a, `${a.label} ${w.title.toLowerCase()} runs out before it resets`, `${rateText(w.rate)} at this pace · out ${whenIn(p.runOut)} · resets ${whenIn(w.resetAt)}`, `${a.id}|${w.id}|pace|${period}`);
      if (settings.notifySurge && surging(a, w, p))
        notify(a, `${a.label} ${w.title.toLowerCase()} is burning ${multipleText(multipleOf(a, w))} your usual`, `${rateText(w.rate)} now · ${rateText(a.typical)} is typical · resets ${whenIn(w.resetAt)}`, `${a.id}|${w.id}|surge|${period}`);
    }
  }
  // Banners arrive one at a time, a beat apart, so a burst of verdicts reads as a sequence rather than a pile.
  const queue = [];
  let lastShown = 0;
  function notify(a, title, body, key) {
    if (delivered.has(key)) return; delivered.add(key);
    queue.push({ title, body });
    drain();
  }
  function drain() {
    if (!queue.length) return;
    const gap = 1400 - (performance.now() - lastShown);
    if (gap > 0) { setTimeout(drain, gap); return; }
    const { title, body } = queue.shift(); lastShown = performance.now();
    const el = h('div', { class: 'notif', role: 'status' }, h('img', { src: '../assets/burn-midnight.svg', alt: '' }),
      h('div', {}, h('b', {}, 'Burn'), h('span', { class: 'nt' }, title), h('span', { class: 'nb' }, body)), h('span', { class: 'when' }, 'now'));
    el.addEventListener('click', () => { dismiss(el); openPanel(true); });
    ui.notifs.append(el);
    setTimeout(() => dismiss(el), 7000);
    if (queue.length) setTimeout(drain, 1400);
  }
  function dismiss(el) { if (!el.isConnected) return; el.classList.add('out'); setTimeout(() => el.remove(), 450); }
  let toastTimer;
  function toast(text, undo) {
    ui.toast.innerHTML = ''; ui.toast.append(text);
    if (undo) ui.toast.append(h('button', { type: 'button', onclick: () => { undo(); hideToast(); } }, 'Undo'));
    ui.toast.classList.add('on'); clearTimeout(toastTimer); toastTimer = setTimeout(hideToast, undo ? 6000 : 3600);
  }
  function hideToast() { ui.toast.classList.remove('on'); }

  // ── interactions ──────────────────────────────────────────────────────────────────────────────────────────────
  function openPanel(open) {
    if (open) { ui.stage.classList.remove('hinting'); ui.tray.classList.remove('pulse'); if (!armed) { armed = true; lastShown = performance.now() - 1000; } }
    ui.panel.classList.toggle('on', open);
    ui.tray.setAttribute('aria-expanded', String(open));
    ui.notifs.classList.toggle('aside', open);
  }
  function openSettings(open) { ui.settings.classList.toggle('on', open); }
  function wire() {
    ui.tray.addEventListener('click', e => { e.stopPropagation(); touched = true; openPanel(!ui.panel.classList.contains('on')); });
    addEventListener('keydown', e => {
      if (e.altKey && (e.code === 'Space')) { e.preventDefault(); touched = true; openPanel(!ui.panel.classList.contains('on')); }
      if (e.key === 'Escape') { if (ui.launch.classList.contains('on')) ui.launch.classList.remove('on'); else if (ui.settings.classList.contains('on')) openSettings(false); else openPanel(false); }
    });
    // the panel hides when you click elsewhere, like the app's
    ui.stage.addEventListener('mousedown', e => { if (!e.target.closest('.panel, .tray, .notifs, .settings, .launch')) openPanel(false); });
    ui.panel.addEventListener('mousedown', e => e.stopPropagation());
    $('#refresh').addEventListener('click', e => { const b = e.currentTarget; b.classList.add('spin'); setTimeout(() => b.classList.remove('spin'), 650); renderAll(); });
    $('#gear').addEventListener('click', () => openSettings(!ui.settings.classList.contains('on')));
    ui.settings.addEventListener('click', e => { if (e.target.closest('[data-act="close-settings"]')) openSettings(false); });
    ui.launch.addEventListener('click', e => { if (e.target.closest('[data-act="close-launch"]')) ui.launch.classList.remove('on'); });
    ui.panel.addEventListener('click', e => {
      const b = e.target.closest('button[data-act]'); if (!b) return;
      const card = b.closest('.acct'), a = accounts.find(x => x.id === card.dataset.id);
      if (b.dataset.act === 'terminal') launch(a);
      if (b.dataset.act === 'copy') { navigator.clipboard?.writeText(`claude-${a.id}`).catch(() => {}); notice(a, `Copied claude-${a.id} — paste to start`); }
      if (b.dataset.act === 'app') toast(`On your Mac this opens ${a.app} — a web page can't.`);
      if (b.dataset.act === 'hide') { settings.hidden.add(a.id); renderAll(); toast(`${a.label} hidden — Settings → Accounts shows it again.`, () => { settings.hidden.delete(a.id); renderAll(); }); }
    });
    // tooltips: the reset's pace sentence, the ring's account, the chip's reason
    let tipTimer;
    ui.stage.addEventListener('mouseover', e => {
      const t = e.target.closest('[data-tip]'); if (!t) return;
      clearTimeout(tipTimer);
      tipTimer = setTimeout(() => showTip(t), 350);
    });
    ui.stage.addEventListener('mouseout', e => { if (e.target.closest('[data-tip]')) { clearTimeout(tipTimer); ui.tip.classList.remove('on'); } });
  }
  function notice(a, text) {
    const pl = $('#pl-' + a.id); pl.textContent = text; pl.classList.add('notice');
    setTimeout(() => { pl.textContent = a.plan; pl.classList.remove('notice'); }, 2400);
  }
  function tipText(t) {
    const a = accounts.find(x => x.id === t.dataset.id), w = a && a.windows.find(x => x.id === t.dataset.w);
    switch (t.dataset.tip) {
      case 'tray': { const pr = primary(); if (!pr) return 'Burn — no accounts shown'; const p = pace(pr.w); return `${pr.a.label} · ${pr.w.title.toLowerCase()} ${Math.round(pr.w.used)} % · resets ${whenIn(pr.w.resetAt)}` + (p.verdict === 'fast' ? ` · ${rateText(p.rate)}, runs out before it resets` : ''); }
      case 'meter': return `${Math.round(w.used)} % used` + (w.kind === 'model' ? ' — a separate weekly limit for this model' : '');
      case 'chip': { const s = a.windows[0]; return `${s.title} at ${rateText(s.rate)}; ${rateText(a.typical)} is typical for this account`; }
      case 'reset': {
        const p = pace(w), parts = [`Resets ${when(w.resetAt)}`];
        if (p.verdict === 'stalled') parts.push('nothing used lately');
        if (p.verdict === 'onPace') parts.push(`${rateText(p.rate)} — lasts until the reset at this pace`);
        if (p.verdict === 'fast') parts.push(`at ${rateText(p.rate)} it runs out ${when(p.runOut)}, ${countdown(new Date(simNow.getTime() + p.shortfall * 1000), simNow)} before it resets`);
        if (p.verdict !== 'early') parts.push(`even pace would be ${Math.round(p.expected)} %`);
        const m = multipleOf(a, w); if (m && p.verdict !== 'early' && p.verdict !== 'stalled') parts.push(`${multipleText(m)} your usual ${rateText(a.typical)}`);
        return parts.join(' · ');
      }
    }
    return '';
  }
  function showTip(t) {
    const text = tipText(t); if (!text) return;
    ui.tip.textContent = text;
    const k = Number(ui.stage.style.getPropertyValue('--k')) || 1;
    const sr = ui.stage.getBoundingClientRect(), tr = t.getBoundingClientRect();
    ui.tip.style.left = '0px'; ui.tip.style.top = '0px'; ui.tip.classList.add('on');
    const tw = ui.tip.offsetWidth, th = ui.tip.offsetHeight;
    let x = (tr.left - sr.left) / k + (tr.width / k - tw) / 2, y = (tr.bottom - sr.top) / k + 8;
    x = clamp(x, 8, W - tw - 8); if (y + th > H - 8) y = (tr.top - sr.top) / k - th - 8;
    ui.tip.style.left = x + 'px'; ui.tip.style.top = y + 'px';
  }
  function launch(a) {
    const cmd = `claude-${a.id}`;
    $('#launch-title').textContent = `${cmd} — 80×24`;
    const body = $('#launch-body'); body.innerHTML = '';
    ui.launch.classList.add('on');
    const line = (cls, text) => body.append(h('div', { class: cls }, text));
    (async () => {
      const typed = h('div', {}, h('span', { class: 'g' }, '$ '), h('span', { id: 'typed' }), h('span', { class: 'cur' })); body.append(typed);
      const target = $('#typed', typed);
      for (let i = 1; i <= cmd.length; i++) { target.textContent = cmd.slice(0, i); await new Promise(r => setTimeout(r, 55)); }
      await new Promise(r => setTimeout(r, 350)); typed.lastElementChild.remove();
      line('t', `# Installed by Burn — Claude Code as ${a.label}`);
      line('t', `# CLAUDE_CONFIG_DIR=~/.claude-${a.id} claude`);
      await new Promise(r => setTimeout(r, 500));
      body.append(h('div', { class: 'welcome' }, h('div', {}, '✻ Welcome to Claude Code!'), h('div', { class: 't' }, `${a.identity} (${a.label}) · cwd: ~/Projects`)));
      await new Promise(r => setTimeout(r, 300));
      body.append(h('div', {}, h('span', { class: 'g' }, '> '), h('span', { class: 'cur' })));
    })();
  }

  choose();
  addEventListener('resize', choose);
  // ?debug exposes the clock, so a script (or a curious person) can advance it: __burn.step(900) is fifteen minutes.
  if (params.has('debug')) window.__burn = { step: s => { step(s); renderAll(); }, render: renderAll, accounts, settings };
})();
