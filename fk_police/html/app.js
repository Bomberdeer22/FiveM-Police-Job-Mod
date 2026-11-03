/* LSPD MDT front end.
   Thin on purpose: every lookup and every action round-trips through Lua
   (fk_police:server:*) so the page cannot invent a record, a fine or a payout. */
(() => {
  'use strict';

  const mdt = document.getElementById('mdt');
  const officerLine = document.getElementById('officer');
  const dutyPill = document.getElementById('duty');
  const results = document.getElementById('results');
  const callsBody = document.getElementById('calls-body');
  const chargesBody = document.getElementById('charges-body');
  const backupBody = document.getElementById('backup-body');

  const state = { status: null, charges: [], calls: [], lastKind: null };

  const post = (event, data = {}) => {
    if (typeof fetch !== 'function') return Promise.resolve();

    return fetch(`https://${window.GetParentResourceName ? window.GetParentResourceName() : 'fk_police'}/${event}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data),
    }).catch(() => {});
  };

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  const flagList = (flags) => {
    const wrap = el('div');
    (flags || []).forEach((flag) => {
      const isBad = /stolen|warrant|suspended|no licence/i.test(flag);
      wrap.appendChild(el('span', isBad ? 'flag bad' : 'flag', flag));
    });
    return wrap;
  };

  function showTab(name) {
    document.querySelectorAll('.tab').forEach((tab) => {
      tab.classList.toggle('is-active', tab.dataset.tab === name);
    });
    document.querySelectorAll('.panel').forEach((panel) => {
      panel.classList.toggle('is-active', panel.id === `panel-${name}`);
    });
  }

  function renderStatus(status) {
    if (!status) return;

    state.status = status;
    officerLine.textContent = `${status.rank} · ${status.xp} XP · ${status.callsign || ''}`
      + ` · ${status.citations} citations · ${status.arrests} arrests`;
    dutyPill.textContent = status.onDuty ? 'ON DUTY' : 'OFF DUTY';
    dutyPill.classList.toggle('on', status.onDuty === true);
  }

  function renderCalls(calls) {
    state.calls = Array.isArray(calls) ? calls : [];
    callsBody.innerHTML = '';

    if (state.calls.length === 0) {
      callsBody.appendChild(el('p', 'hint', 'No callout on the board. Dispatch will call you.'));
      return;
    }

    state.calls.forEach((call) => {
      const card = el('div', 'call');
      card.appendChild(el('h2', null, `${call.code || 'CALL'} — ${call.label || 'Callout'}`));
      card.appendChild(el('p', null, call.coords
        ? `Scene: ${call.coords.x.toFixed(0)}, ${call.coords.y.toFixed(0)} · ${call.xp || 0} XP`
        : `Accepted · ${call.xp || 0} XP`));

      const row = el('div', 'row');
      const accept = el('button', null, 'Accept');
      accept.addEventListener('click', () => post('callout', { action: 'accept' }));
      const decline = el('button', 'ghost', 'Decline');
      decline.addEventListener('click', () => post('callout', { action: 'decline' }));

      row.append(accept, decline);
      card.appendChild(row);
      callsBody.appendChild(card);
    });
  }

  function renderCharges(charges) {
    state.charges = Array.isArray(charges) ? charges : [];
    chargesBody.innerHTML = '';

    state.charges.forEach((charge) => {
      const row = el('tr');
      row.appendChild(el('td', null, charge.id));
      row.appendChild(el('td', null, charge.label));
      row.appendChild(el('td', null, `$${charge.fine}`));
      row.appendChild(el('td', null, charge.jail ? `${charge.jail}s` : '—'));
      row.appendChild(el('td', null, charge.type || ''));
      chargesBody.appendChild(row);
    });
  }

  function renderBackup() {
    const kinds = [
      ['code2', 'Code 2 — no lights'],
      ['code3', 'Code 3 — lights and sirens'],
      ['air', 'Air support'],
      ['k9', 'K9 unit'],
      ['swat', 'SWAT / NOOSE'],
      ['ems', 'Ambulance'],
      ['fire', 'Fire department'],
    ];

    backupBody.innerHTML = '';
    kinds.forEach(([kind, label]) => {
      const button = el('button', null, label);
      button.addEventListener('click', () => post('backup', { kind }));
      backupBody.appendChild(button);
    });
  }

  function renderResults(result) {
    results.innerHTML = '';

    if (!result || result.ok !== true) {
      const reason = result && result.reason === 'off_duty'
        ? 'Go on duty first.'
        : 'That lookup did not go through.';
      results.appendChild(el('p', 'hint', reason));
      return;
    }

    const list = result.results || [];

    if (list.length === 0) {
      results.appendChild(el('p', 'hint', 'No record found.'));
      return;
    }

    list.forEach((record) => {
      const card = el('div', 'card');

      if (result.kind === 'vehicle') {
        card.appendChild(el('h2', null, `${record.plate} — ${record.model}`));
        card.appendChild(el('p', null, `Owner: ${record.owner}`));
        card.appendChild(el('p', null, `Registration: ${record.registration} · Insurance: ${record.insurance}`));
        card.appendChild(flagList(record.flags));
        if ((record.ownerFlags || []).length) card.appendChild(flagList(record.ownerFlags));
      } else {
        card.appendChild(el('h2', null, record.name));
        card.appendChild(el('p', null, `DOB: ${record.dob || 'unknown'} · Licence: ${record.license}`));
        card.appendChild(flagList(record.flags));
      }

      results.appendChild(card);
    });
  }

  function open(payload) {
    mdt.classList.remove('is-hidden');
    mdt.setAttribute('aria-hidden', 'false');

    renderStatus(payload.status);
    renderCharges(payload.charges);
    renderCalls(payload.calls);
    renderBackup();
    results.innerHTML = '';

    const input = document.getElementById('query-people');
    if (input) setTimeout(() => input.focus(), 30);
  }

  function close() {
    mdt.classList.add('is-hidden');
    mdt.setAttribute('aria-hidden', 'true');
  }

  // --- wiring --------------------------------------------------------------

  document.querySelectorAll('.tab').forEach((tab) => {
    tab.addEventListener('click', () => showTab(tab.dataset.tab));
  });

  document.getElementById('close').addEventListener('click', () => {
    post('close');
    close();
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      post('close');
      close();
    }
  });

  document.getElementById('form-people').addEventListener('submit', (event) => {
    event.preventDefault();
    const query = document.getElementById('query-people').value;
    state.lastKind = 'person';
    post('search', { kind: 'person', query });
  });

  document.getElementById('form-vehicles').addEventListener('submit', (event) => {
    event.preventDefault();
    const query = document.getElementById('query-vehicles').value;
    state.lastKind = 'vehicle';
    post('search', { kind: 'vehicle', query });
  });

  window.addEventListener('message', (event) => {
    const data = event.data || {};

    if (data.action === 'open') return open(data);
    if (data.action === 'close') return close();
    if (data.action === 'results') return renderResults(data.result);
    if (data.action === 'status') return renderStatus(data.status);
    if (data.action === 'callout') return renderCalls(data.calls || []);

    return undefined;
  });

  // Also usable outside the game (preview/debug): window.mdt.open({ ... }).
  window.mdt = { open, close, renderResults, renderStatus, renderCalls, state, post };
})();
