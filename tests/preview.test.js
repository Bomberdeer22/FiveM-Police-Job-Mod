/* Checks the dev preview harness (preview/) boots against the mock bridge.
   Run with: npm test */

const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const ROOT = path.join(__dirname, '..');
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

JSDOM.fromFile(path.join(ROOT, 'preview/index.html'), {
  runScripts: 'dangerously',
  resources: 'usable',
  pretendToBeVisual: true,
  url: 'http://localhost:8000/preview/',
  beforeParse(window) {
    window.fetch = (url) => {
      const rel = String(url).replace(/^\.\.\//, '').replace(/^\.\//, '');
      const file = path.join(ROOT, rel);
      try {
        const text = fs.readFileSync(file, 'utf8');
        return Promise.resolve({ ok: true, text: () => Promise.resolve(text) });
      } catch (e) {
        return Promise.reject(e);
      }
    };
  },
}).then(async (dom) => {
  const win = dom.window;
  const doc = win.document;
  const checks = [];
  const check = (name, cond, extra) => checks.push({ name, ok: !!cond, extra });

  await new Promise((r) => win.addEventListener('load', r));
  await wait(900);

  check('hud rendered in preview', doc.querySelectorAll('.hud-row').length === 2, doc.querySelectorAll('.hud-row').length);
  const values = Array.from(doc.querySelectorAll('.hud-value')).map((n) => n.textContent);
  check('demo balances shown ($1,250 / $24,500)', values[0] === '$1,250' && values[1] === '$24,500', values);

  const bar = doc.getElementById('demo-bar');
  check('demo toolbar present', !!bar);
  const buttons = bar ? Array.from(bar.querySelectorAll('button')) : [];
  check('toolbar has 5 buttons', buttons.length === 5, buttons.map((b) => b.textContent));

  buttons[0].click(); // Open menu
  await wait(250);
  check('menu opens from toolbar', doc.getElementById('menu').classList.contains('is-open'));
  check('staff tab visible in demo', doc.getElementById('tab-staff').style.display !== 'none');
  check('players loaded', doc.querySelectorAll('.player-row').length === 5, doc.querySelectorAll('.player-row').length);

  // Staff: select Sarah Miller (id 2) and give $500
  const row = Array.from(doc.querySelectorAll('.player-row')).find((r) => r.textContent.includes('Sarah Miller'));
  row.click();
  await wait(100);
  doc.querySelector('.tab[data-tab="staff"]').click();
  await wait(100);
  doc.getElementById('amount').value = '500';
  row.click();
  doc.getElementById('btn-give').click();
  await wait(300);
  check('staff give produced a toast/result', doc.querySelectorAll('.toast').length >= 1, doc.body.textContent.includes('Sarah'));

  // Taking more than they have should fail
  doc.getElementById('amount').value = '999999';
  doc.getElementById('btn-take').click();
  await wait(50);
  doc.getElementById('btn-take').click();
  await wait(300);
  check('over-withdraw rejected in demo', doc.querySelectorAll('.toast.error').length >= 1, Array.from(doc.querySelectorAll('.toast')).map((t) => t.className));

  // Price list
  doc.querySelector('.tab[data-tab="prices"]').click();
  await wait(100);
  check('price list renders', doc.querySelectorAll('.price-item').length === 14, doc.querySelectorAll('.price-item').length);

  // HUD drag mode
  doc.querySelector('.tab[data-tab="hud"]').click();
  await wait(50);
  doc.getElementById('btn-move').click();
  await wait(120);
  check('drag mode entered', doc.body.classList.contains('is-dragging') && doc.getElementById('hud').classList.contains('is-editing'));
  doc.getElementById('btn-drag-done').click();
  await wait(120);
  check('drag mode exited', !doc.body.classList.contains('is-dragging'));
  doc.querySelector('.preset[data-preset="tr"]').click();
  await wait(350);
  const hud = doc.getElementById('hud');
  check('preset moved hud to right', parseFloat(hud.style.left) > 40, hud.style.left);

  // Close menu via button
  doc.getElementById('close-btn').click();
  await wait(200);
  check('menu closes', !doc.getElementById('menu').classList.contains('is-open'));

  const failures = checks.filter((c) => !c.ok);
  checks.forEach((c) => console.log(`${c.ok ? 'PASS' : 'FAIL'}  ${c.name}${c.ok ? '' : ' -> ' + JSON.stringify(c.extra)}`));
  console.log(`\n${checks.length - failures.length}/${checks.length} preview checks passed`);
  process.exit(failures.length ? 1 : 0);
}).catch((e) => { console.error('PREVIEW TEST ERROR', e); process.exit(1); });
