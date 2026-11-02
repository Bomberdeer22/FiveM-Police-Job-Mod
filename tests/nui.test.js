/* Drives the real NUI page in jsdom: formatting, menu/tab flow, drag mode,
   presets, staff give/take, price list and delta pills.
   Run with: npm test */

const path = require('path');
const { JSDOM } = require('jsdom');

const HTML = path.join(__dirname, '..', 'fk_economy', 'html', 'index.html');

const config = {
  resource: 'fk_economy',
  currency: { symbol: '$', decimals: 0, symbolFirst: true },
  accounts: [{ id: 'cash', label: 'Cash' }, { id: 'bank', label: 'Bank' }],
  limits: { minScale: 0.65, maxScale: 1.8, minOpacity: 0.25, maxOpacity: 1, maxPerAction: 1000000 },
  staff: { reasons: ['Payroll','Bonus'], quickAmounts: [100,500], enabled: false },
  key: 'F7', animations: false, tweenMs: 0, edgeSnapPx: 0, showDeltaFloat: true,
  items: {
    bodycam: { label: 'Body Camera', price: 250, category: 'Equipment', description: 'Records.' },
    coffee: { label: 'Coffee', price: 5, category: 'Consumables' },
  },
};

const calls = [];
const settings = { visible: true, x: 1, y: 78, scale: 1, opacity: 1, compact: false };

JSDOM.fromFile(HTML, {
  runScripts: 'dangerously',
  resources: 'usable',
  pretendToBeVisual: true,
  beforeParse(window) {
    window.fetch = (url, opts) => {
      calls.push({ url, body: opts && opts.body ? JSON.parse(opts.body) : null });
      return Promise.resolve({ json: () => Promise.resolve({ ok: true }) });
    };
    window.__config = config;
    window.__settings = settings;
  },
}).then((dom) => {
  const win = dom.window;
  const doc = win.document;
  const post = (payload) => win.postMessage(payload, '*');
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));

  const results = [];
  const check = (name, condition, extra = '') => {
    results.push({ name, ok: !!condition, extra });
  };

  return (async () => {
    await new Promise((r) => win.addEventListener('load', r));
    await wait(60);

    check('boot posts ready', calls.some((c) => c.url.endsWith('/ready')), JSON.stringify(calls.map(c=>c.url)));

    post({ action: 'init', config, settings });
    post({ action: 'state', balances: { cash: 1250, bank: 24500 }, staff: true });
    await wait(80);

    const rows = doc.querySelectorAll('.hud-row');
    check('hud has 2 rows', rows.length === 2, `got ${rows.length}`);
    const values = Array.from(doc.querySelectorAll('.hud-value')).map((n) => n.textContent);
    check('cash formatted', values[0] === '$1,250', values.join(' | '));
    check('bank formatted', values[1] === '$24,500', values.join(' | '));
    check('hud visible', !doc.getElementById('hud').classList.contains('is-hidden'));
    check('hud positioned by percent', doc.getElementById('hud').style.left === '1%', doc.getElementById('hud').style.left);

    // Staff tab should now be visible
    check('staff tab shown', doc.getElementById('tab-staff').style.display !== 'none', doc.getElementById('tab-staff').style.display);

    // Open menu through the "Lua" channel
    post({ action: 'menu', open: true });
    await wait(40);
    check('menu open class', doc.getElementById('menu').classList.contains('is-open'));
    check('hud not editable until drag mode', !doc.getElementById('hud').classList.contains('is-editing'));

    doc.getElementById('btn-move').click();
    await wait(30);
    check('drag mode enables dragging', doc.getElementById('hud').classList.contains('is-editing') && doc.body.classList.contains('is-dragging'));
    doc.getElementById('btn-drag-done').click();
    await wait(30);
    check('done exits drag mode', !doc.getElementById('hud').classList.contains('is-editing') && !doc.body.classList.contains('is-dragging'));

    // Switch to staff tab
    doc.querySelector('.tab[data-tab="staff"]').click();
    await wait(40);
    check('staff panel active', doc.querySelector('.panel[data-panel="staff"]').classList.contains('is-active'));
    check('hud not editable on staff tab', !doc.getElementById('hud').classList.contains('is-editing'));
    check('players requested', calls.some((c) => c.url.endsWith('/requestPlayers')));

    post({
      action: 'players',
      players: [
        { id: 1, name: 'Me <b>', isMe: true, balances: { cash: 1250, bank: 24500 } },
        { id: 2, name: 'Sarah Miller', isMe: false, balances: { cash: 780, bank: 12300 } },
      ],
    });
    await wait(60);
    const playerRows = doc.querySelectorAll('.player-row');
    check('players rendered', playerRows.length === 2, `got ${playerRows.length}`);
    check('player name escaped', playerRows[0].querySelector('.player-name').innerHTML.includes('&lt;b&gt;'));

    playerRows[1].click();
    await wait(20);
    check('target selected', doc.querySelector('.target-name').textContent === 'Sarah Miller', doc.querySelector('.target-name').textContent);
    check('target card populated', !doc.getElementById('target-card').classList.contains('empty'));

    // Account segments
    const segments = doc.querySelectorAll('#account-seg button');
    check('account segments built', segments.length === 2, `got ${segments.length}`);
    segments[1].click();
    await wait(20);

    // Amount + give
    doc.getElementById('amount').value = '750';
    calls.length = 0;
    doc.getElementById('btn-give').click();
    await wait(30);
    const action = calls.find((c) => c.url.endsWith('/staffAction'));
    check('staffAction sent', !!action, JSON.stringify(calls.map((c) => c.url)));
    if (action) {
      check('staffAction payload', action.body.mode === 'add' && action.body.amount === 750 && action.body.target === 2 && action.body.account === 'bank', JSON.stringify(action.body));
    }

    // Take needs confirmation
    calls.length = 0;
    doc.getElementById('btn-take').click();
    await wait(20);
    check('take asks for confirmation', doc.getElementById('btn-take').dataset.confirm === 'true' && !calls.some((c) => c.url.endsWith('/staffAction')));
    doc.getElementById('btn-take').click();
    await wait(30);
    const takeCall = calls.find((c) => c.url.endsWith('/staffAction'));
    check('take confirmed sends action', takeCall && takeCall.body.mode === 'remove', JSON.stringify(takeCall && takeCall.body));

    // Result toast
    post({ action: 'staffResult', result: { ok: true, message: 'Added $750 bank to Sarah Miller' } });
    await wait(40);
    check('toast shown', doc.querySelectorAll('.toast').length >= 1);

    // Prices tab
    doc.querySelector('.tab[data-tab="prices"]').click();
    await wait(30);
    check('price rows rendered', doc.querySelectorAll('.price-item').length === 2, `got ${doc.querySelectorAll('.price-item').length}`);
    check('price value formatted', doc.querySelector('.price-item-value').textContent === '$250' || doc.querySelector('.price-item-value').textContent === '$5');

    // HUD controls
    doc.querySelector('.tab[data-tab="hud"]').click();
    await wait(20);
    doc.querySelector('.preset[data-preset="br"]').click();
    await wait(400);
    check('preset writes settings', (() => {
      const save = calls.filter((c) => c.url.endsWith('/saveSettings')).pop();
      return save && typeof save.body.settings.x === 'number';
    })(), JSON.stringify(calls.filter((c) => c.url.endsWith('/saveSettings')).pop()));

    doc.getElementById('opt-compact').click();
    await wait(20);
    check('compact toggles class', doc.getElementById('hud').classList.contains('is-compact'));

    // Money change animation + delta
    post({ action: 'state', balances: { cash: 1500, bank: 24500 }, staff: true });
    await wait(60);
    check('cash updated', doc.querySelector('.hud-row[data-account="cash"] .hud-value').textContent === '$1,500', doc.querySelector('.hud-row[data-account="cash"] .hud-value').textContent);
    check('delta pill shown', doc.querySelectorAll('.delta-pill').length >= 1);

    // Closing
    post({ action: 'menu', open: false });
    await wait(30);
    check('menu closed', !doc.getElementById('menu').classList.contains('is-open'));

    // Reset
    doc.querySelector('.tab[data-tab="hud"]');
    post({ action: 'settings', settings: { visible: false, x: 2, y: 3, scale: 1.2, opacity: 0.5, compact: true } });
    await wait(30);
    check('hidden hud', doc.getElementById('hud').classList.contains('is-hidden'));
    check('scale applied', doc.documentElement.style.getPropertyValue('--scale') === '1.2', doc.documentElement.style.getPropertyValue('--scale'));

    const failures = results.filter((r) => !r.ok);
    for (const r of results) {
      console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.ok ? '' : '  -> ' + r.extra}`);
    }
    console.log(`\n${results.length - failures.length}/${results.length} checks passed`);
    process.exit(failures.length ? 1 : 0);
  })().catch((e) => { console.error('TEST ERROR', e); process.exit(1); });
});
