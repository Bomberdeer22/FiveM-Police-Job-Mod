/* LSPD MDT + HUD front end.
   Thin on purpose: every lookup and every action round-trips through Lua
   (fk_police:server:*) so the page cannot invent a record, a fine or a payout. */
(() => {
  'use strict';

  const mdt = document.getElementById('mdt');
  const hud = document.getElementById('hud');
  const results = document.getElementById('results');

  const state = { status: null, charges: [], calls: [], bundle: null, lastKind: null, open: false };

  const post = (event, data = {}) => {
    if (typeof fetch !== 'function') return Promise.resolve();

    const resource = typeof window.GetParentResourceName === 'function'
      ? window.GetParentResourceName()
      : 'fk_police';

    return fetch(`https://${resource}/${event}`, {
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

  const money = (value) => `$${Math.round(Number(value) || 0).toLocaleString('en-GB')}`;

  const duration = (seconds) => {
    const total = Math.max(0, Math.floor(Number(seconds) || 0));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);

    if (hours > 0) return `${hours}h ${String(minutes).padStart(2, '0')}m`;
    if (minutes > 0) return `${minutes}m ${String(total % 60).padStart(2, '0')}s`;

    return `${total}s`;
  };

  const date = (seconds) => {
    if (!seconds) return '—';

    const when = new Date(Number(seconds) * 1000);

    if (Number.isNaN(when.getTime())) return '—';

    return when.toISOString().slice(0, 10);
  };

  const byId = (id) => document.getElementById(id);

  function flagList(flags) {
    const wrap = el('div');

    (flags || []).forEach((flag) => {
      const isBad = /stolen|warrant|suspended|overdue|no licence|expired/i.test(String(flag));
      wrap.appendChild(el('span', isBad ? 'flag bad' : 'flag', String(flag)));
    });

    return wrap;
  }

  function showTab(name) {
    document.querySelectorAll('.tab').forEach((tab) => {
      tab.classList.toggle('is-active', tab.dataset.tab === name);
    });

    document.querySelectorAll('.panel').forEach((panel) => {
      panel.classList.toggle('is-active', panel.id === `panel-${name}`);
    });
  }

  // ---------------------------------------------------------------- status

  function renderStatus(status) {
    if (!status) return;

    state.status = status;

    byId('officer').textContent = `${status.rank} · ${status.xp} XP · ${status.callsign || ''}`
      + ` · ${status.citations} citations · ${status.arrests} arrests`;

    const duty = byId('duty');
    duty.textContent = status.onDuty ? 'ON DUTY' : 'OFF DUTY';
    duty.classList.toggle('on', status.onDuty === true);
  }

  // ----------------------------------------------------------------- calls

  function renderCalls(calls) {
    state.calls = Array.isArray(calls) ? calls : [];

    const body = byId('calls-body');
    body.innerHTML = '';

    if (state.calls.length === 0) {
      body.appendChild(el('p', 'hint', 'No callout on the board. Dispatch will call you.'));
      return;
    }

    state.calls.forEach((call) => {
      const card = el('div', 'card');
      card.appendChild(el('h2', null, `${call.code || 'CALL'} — ${call.label || 'Callout'}`));
      card.appendChild(el('p', null, call.coords
        ? `Scene: ${call.coords.x.toFixed(0)}, ${call.coords.y.toFixed(0)} · ${call.xp || 0} XP`
        : `Accepted · ${call.xp || 0} XP`));

      if (call.suspects) card.appendChild(el('p', null, `${call.suspects} suspect(s) reported`));

      const row = el('div', 'row');
      const accept = el('button', null, 'Accept');
      accept.addEventListener('click', () => post('callout', { action: 'accept' }));
      const decline = el('button', 'ghost', 'Decline');
      decline.addEventListener('click', () => post('callout', { action: 'decline' }));

      row.append(accept, decline);
      card.appendChild(row);
      body.appendChild(card);
    });
  }

  // --------------------------------------------------------------- charges

  function renderCharges(charges) {
    state.charges = Array.isArray(charges) ? charges : [];

    const body = byId('charges-body');
    body.innerHTML = '';

    state.charges.forEach((charge) => {
      const row = el('tr');
      row.appendChild(el('td', null, charge.id));
      row.appendChild(el('td', null, charge.label));
      row.appendChild(el('td', null, money(charge.fine)));
      row.appendChild(el('td', null, charge.jail ? `${charge.jail}s` : '—'));
      row.appendChild(el('td', null, charge.type || ''));
      body.appendChild(row);
    });

    renderChargeChips();
  }

  function renderChargeChips() {
    const wrap = byId('report-charges');

    if (!wrap) return;

    wrap.innerHTML = '';

    state.charges.forEach((charge) => {
      const label = el('label', 'chip-toggle');
      const box = el('input');
      box.type = 'checkbox';
      box.value = charge.id;
      box.dataset.charge = charge.id;
      label.append(box, el('span', null, charge.label));
      wrap.appendChild(label);
    });
  }

  // ---------------------------------------------------------------- results

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

        if (record.impounded) card.appendChild(el('p', null, 'On the impound lot.'));

        (record.bolos || []).forEach((bolo) => {
          card.appendChild(el('p', null, `BOLO ${bolo.id}: ${bolo.reason}`));
        });

        if ((record.ownerFines || {}).owed) {
          card.appendChild(el('p', null, `Owner owes ${money(record.ownerFines.owed)} in fines.`));
        }

        if ((record.ownerFlags || []).length) card.appendChild(flagList(record.ownerFlags));
      } else {
        card.appendChild(el('h2', null, record.name));
        card.appendChild(el('p', null, `DOB: ${record.dob || 'unknown'} · Licence: ${record.license}`));
        card.appendChild(flagList(record.flags));

        (record.bolos || []).forEach((bolo) => {
          card.appendChild(el('p', null, `BOLO ${bolo.id}: ${bolo.reason}`));
        });

        if ((record.fines || {}).owed) {
          card.appendChild(el('p', null,
            `Owes ${money(record.fines.owed)} (${record.fines.count} fine(s), ${record.fines.overdue} overdue).`));
        }

        const row = el('div', 'row');
        const warrant = el('button', 'small', 'Issue warrant');
        warrant.addEventListener('click', () => post('warrantIssue', {
          person: record.name,
          charge: (record.flags.find((flag) => /WARRANT/.test(flag)) || '').replace(/^WARRANT: /, '') || 'assault',
          days: 30,
        }));
        const bolo = el('button', 'small ghost', 'Flag person');
        bolo.addEventListener('click', () => post('bolo', {
          kind: 'person',
          value: record.name,
          reason: 'Person of interest',
          minutes: 120,
        }));

        row.append(warrant, bolo);
        card.appendChild(row);
      }

      results.appendChild(card);
    });
  }

  // ------------------------------------------------------------------- MDT

  function renderBoloList(bolos) {
    const wrap = byId('bolo-list');
    wrap.innerHTML = '';

    if ((bolos || []).length === 0) {
      wrap.appendChild(el('p', 'hint', 'No BOLOs on the board.'));
      return;
    }

    bolos.forEach((bolo) => {
      const card = el('div', 'card');
      card.appendChild(el('h2', null, `${bolo.kind === 'person' ? 'Person' : 'Vehicle'}: ${bolo.value}`));
      card.appendChild(el('p', null, bolo.reason));
      card.appendChild(el('p', null,
        `${bolo.active ? 'Active' : (bolo.expired ? 'Expired' : 'Cleared')} · ${bolo.id}`));

      if (bolo.active) {
        const row = el('div', 'row');
        const clear = el('button', 'small danger', 'Clear');
        clear.addEventListener('click', () => post('boloClear', { id: bolo.id }));
        row.appendChild(clear);
        card.appendChild(row);
      }

      wrap.appendChild(card);
    });
  }

  function renderWarrantList(warrants) {
    const wrap = byId('warrant-list');

    if (!wrap) return;

    wrap.innerHTML = '';

    if ((warrants || []).length === 0) {
      wrap.appendChild(el('p', 'hint', 'No warrants out.'));
      return;
    }

    warrants.forEach((warrant) => {
      const card = el('div', 'card');
      card.appendChild(el('h2', null, `${warrant.person} — ${warrant.charge}`));
      card.appendChild(el('p', null,
        `${warrant.active ? 'Active' : 'Inactive'} · ${warrant.id}${warrant.auto ? ' · court sweep' : ''}`));

      if (warrant.active) {
        const row = el('div', 'row');
        const revoke = el('button', 'small ghost', 'Revoke');
        revoke.addEventListener('click', () => post('warrantRevoke', { id: warrant.id }));
        row.appendChild(revoke);
        card.appendChild(row);
      }

      wrap.appendChild(card);
    });
  }

  function renderReports(reports) {
    const wrap = byId('report-list');
    wrap.innerHTML = '';

    if ((reports || []).length === 0) {
      wrap.appendChild(el('p', 'hint', 'No reports filed yet.'));
      return;
    }

    reports.forEach((report) => {
      const card = el('div', 'card');
      card.appendChild(el('h2', null, `${report.title}`));
      card.appendChild(el('p', null,
        `${report.kind} · ${report.id} · ${(report.at || '').slice(0, 10)}`));

      if ((report.subjects || []).length) {
        card.appendChild(el('p', null, `Subjects: ${report.subjects.join(', ')}`));
      }

      if (report.plate) card.appendChild(el('p', null, `Plate: ${report.plate}`));
      if ((report.charges || []).length) card.appendChild(flagList(report.charges));

      wrap.appendChild(card);
    });
  }

  function renderFines(fines) {
    const totals = (fines && fines.totals) || {};
    byId('fines-totals').textContent = totals.count
      ? `${totals.count} fine(s) · ${money(totals.owed)} outstanding · ${totals.overdue} overdue`
      : 'No fines on the ledger.';

    const body = byId('fines-body');
    body.innerHTML = '';

    ((fines && fines.list) || []).forEach((fine) => {
      const row = el('tr');
      row.appendChild(el('td', null, fine.id));
      row.appendChild(el('td', null, fine.person || 'unknown'));
      row.appendChild(el('td', null, money(fine.owed)));
      row.appendChild(el('td', null, date(fine.dueAt)));
      row.appendChild(el('td', null, fine.overdue ? 'overdue' : fine.status));

      const actions = el('td');
      actions.className = 'row';

      if (fine.status === 'unpaid') {
        const collect = el('button', 'small', 'Collect');
        collect.addEventListener('click', () => post('fineCollect', { id: fine.id, amount: fine.owed }));
        const waive = el('button', 'small ghost', 'Waive');
        waive.addEventListener('click', () => post('fineWaive', { id: fine.id }));
        actions.append(collect, waive);
      }

      row.appendChild(actions);
      body.appendChild(row);
    });
  }

  function renderImpounds(impounds) {
    const wrap = byId('impound-list');
    wrap.innerHTML = '';

    if ((impounds || []).length === 0) {
      wrap.appendChild(el('p', 'hint', 'The impound lot is empty.'));
      return;
    }

    impounds.forEach((entry) => {
      const card = el('div', 'card');
      card.appendChild(el('h2', null, `${entry.plate} — ${entry.model || 'unknown'}`));
      card.appendChild(el('p', null, `${entry.reason || 'seized'} · fee ${money(entry.fee)} · ${entry.id}`));
      card.appendChild(el('p', null, entry.released ? `Released ${entry.releasedAt || ''}` : 'On the lot'));

      if (!entry.released) {
        const row = el('div', 'row');
        const release = el('button', 'small', 'Release');
        release.addEventListener('click', () => post('impoundRelease', { id: entry.id }));
        row.appendChild(release);
        card.appendChild(row);
      }

      wrap.appendChild(card);
    });
  }

  function renderShift(shift) {
    const cards = byId('shift-cards');
    cards.innerHTML = '';

    const push = (label, value) => {
      const stat = el('div', 'stat');
      stat.appendChild(el('span', null, label));
      stat.appendChild(el('b', null, String(value)));
      cards.appendChild(stat);
    };

    if (!shift || !shift.active) {
      push('Shift', 'off duty');
      push('Citations', 0);
      push('Arrests', 0);
      push('Callouts', 0);
      return;
    }

    push('Shift length', duration(shift.seconds));
    push('Citations', shift.counters.citations);
    push('Arrests', shift.counters.arrests);
    push('Callouts', shift.counters.callouts);
    push('Reports', shift.counters.reports);
    push('Pay so far', money(shift.projected && shift.projected.pay));
  }

  function renderShifts(shifts) {
    const body = byId('shift-body');
    body.innerHTML = '';

    (shifts || []).forEach((shift) => {
      const row = el('tr');
      row.appendChild(el('td', null, shift.id));
      row.appendChild(el('td', null, duration(shift.seconds)));
      row.appendChild(el('td', null, shift.citations));
      row.appendChild(el('td', null, shift.arrests));
      row.appendChild(el('td', null, shift.callouts));
      row.appendChild(el('td', null, money(shift.pay)));
      body.appendChild(row);
    });
  }

  function renderPursuits(pursuits) {
    const body = byId('pursuit-body');
    body.innerHTML = '';

    (pursuits || []).forEach((pursuit) => {
      const row = el('tr');
      row.appendChild(el('td', null, pursuit.id));
      row.appendChild(el('td', null, duration(pursuit.seconds)));
      row.appendChild(el('td', null, pursuit.outcome));
      row.appendChild(el('td', null, pursuit.plate || '—'));
      body.appendChild(row);
    });
  }

  function renderMedals(medals) {
    const list = byId('medal-list');
    list.innerHTML = '';

    if (!medals || medals.length === 0) {
      list.appendChild(el('div', 'row', 'No medals yet. 500 XP earns the first one.'));
      return;
    }

    medals.forEach((medal) => {
      const row = el('div', 'row');
      row.appendChild(el('b', null, medal.label));
      row.appendChild(el('span', null, medal.blurb || `${medal.xp} XP`));
      list.appendChild(row);
    });
  }

  function renderVerdicts(verdicts) {
    const body = byId('verdict-body');
    body.innerHTML = '';

    (verdicts || []).forEach((verdict) => {
      const row = el('tr');
      row.appendChild(el('td', null, verdict.id));
      row.appendChild(el('td', null, verdict.person || '—'));
      row.appendChild(el('td', null, verdict.booking || '—'));
      row.appendChild(el('td', null, verdict.outcome || '—'));
      row.appendChild(el('td', null, verdict.refund ? money(verdict.refund) : '—'));
      body.appendChild(row);
    });
  }

  function renderEvidence(evidence) {
    const body = byId('evidence-body');
    body.innerHTML = '';

    (evidence || []).forEach((item) => {
      const row = el('tr');
      const labels = (item.items || []).map((seized) => `${seized.label || seized.id} x${seized.qty || 1}`);

      row.appendChild(el('td', null, item.id));
      row.appendChild(el('td', null, item.person || '—'));
      row.appendChild(el('td', null, labels.join(', ') || '—'));
      row.appendChild(el('td', null, item.kind || '—'));
      row.appendChild(el('td', null, item.at || '—'));
      body.appendChild(row);
    });
  }

  function renderBackup(backup) {
    const grid = byId('backup-grid');

    if (!grid) return;

    grid.innerHTML = '';

    Object.entries(backup || {}).forEach(([kind, option]) => {
      if (!option || typeof option !== 'object' || !option.units) return;

      const button = el('button', 'small ghost', option.label || kind);
      button.addEventListener('click', () => post('backup', { kind }));
      grid.appendChild(button);
    });
  }

  function renderBundle(bundle) {
    if (!bundle) return;

    state.bundle = bundle;

    renderStatus(bundle.status);
    renderCharges(bundle.charges || state.charges);
    renderCalls(bundle.callout ? [bundle.callout] : []);
    renderBackup(bundle.backup);
    renderBoloList(bundle.bolos);
    renderWarrantList(bundle.warrants);
    renderReports(bundle.reports);
    renderFines(bundle.fines);
    renderImpounds(bundle.impounds);
    renderShift(bundle.shift);
    renderShifts(bundle.shifts);
    renderPursuits(bundle.pursuits);
    renderMedals(bundle.status && bundle.status.medals);
    renderVerdicts(bundle.verdicts);
    renderEvidence(bundle.evidence);

    if (bundle.department) {
      byId('fund').textContent = `${bundle.department.label || 'Court fund'} ${money(bundle.department.balance)}`;
    }
  }

  function open(payload) {
    state.open = true;
    mdt.classList.remove('is-hidden');
    mdt.setAttribute('aria-hidden', 'false');

    renderStatus(payload.status);
    renderCharges(payload.charges);
    renderCalls(payload.calls);
    results.innerHTML = '';

    const input = byId('query-people');
    if (input) setTimeout(() => input.focus(), 30);
  }

  function close() {
    state.open = false;
    mdt.classList.add('is-hidden');
    mdt.setAttribute('aria-hidden', 'true');
  }

  function renderHud(payload) {
    if (!payload) return;

    const visible = payload.onDuty === true && !state.open;

    hud.classList.toggle('is-hidden', !visible);
    hud.setAttribute('aria-hidden', String(!visible));

    if (!visible) return;

    byId('hud-rank').textContent = `${payload.rank || 'Cadet'} · ${payload.xp || 0} XP`;
    byId('hud-xp').style.width = `${Math.max(0, Math.min(100, Number(payload.percent) || 0))}%`;
    byId('hud-shift').textContent = payload.shiftSeconds
      ? duration(payload.shiftSeconds)
      : (payload.shift && payload.shift.seconds ? duration(payload.shift.seconds) : '');

    const calloutBox = byId('hud-callout');

    if (payload.callout) {
      calloutBox.classList.remove('is-hidden');
      byId('callout-code').textContent = payload.callout.code || 'CALL';
      byId('callout-label').textContent = payload.callout.label || '';
      byId('callout-distance').textContent = payload.callout.distance !== undefined
        ? `${payload.callout.distance} m`
        : '';
    } else {
      calloutBox.classList.add('is-hidden');
    }

    const radarBox = byId('hud-radar');

    if (payload.radar && payload.radar.speed) {
      radarBox.classList.remove('is-hidden');
      byId('radar-speed').textContent = payload.radar.speed;
      byId('radar-plate').textContent = payload.radar.plate || '—';
      byId('radar-alert').classList.toggle('is-hidden', payload.radar.alert !== true);
    } else {
      radarBox.classList.add('is-hidden');
    }

    const backup = byId('hud-backup');

    if (payload.backup && payload.backup.kind) {
      backup.classList.remove('is-hidden');
      const eta = payload.backup.remaining !== undefined ? payload.backup.remaining : payload.backup.eta;
      backup.textContent = `${payload.backup.kind} backup · ${eta || 0}s`;
    } else {
      backup.classList.add('is-hidden');
    }

    const pursuitChip = byId('hud-pursuit');

    if (payload.pursuit) {
      pursuitChip.classList.remove('is-hidden');
      pursuitChip.textContent = `PURSUIT ${duration(payload.pursuit.seconds)}`;
    } else {
      pursuitChip.classList.add('is-hidden');
    }

    const custody = byId('hud-custody');

    if (payload.custody) {
      custody.classList.remove('is-hidden');
      custody.textContent = `CUSTODY ${duration(payload.custody.seconds)}`;
    } else {
      custody.classList.add('is-hidden');
    }

    byId('hud-bodycam').classList.toggle('is-hidden', payload.bodycam !== true);
  }

  // ----------------------------------------------------------------- wiring

  document.querySelectorAll('.tab').forEach((tab) => {
    tab.addEventListener('click', () => showTab(tab.dataset.tab));
  });

  byId('close').addEventListener('click', () => {
    post('close');
    close();
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && state.open) {
      post('close');
      close();
    }
  });

  byId('form-people').addEventListener('submit', (event) => {
    event.preventDefault();
    state.lastKind = 'person';
    post('search', { kind: 'person', query: byId('query-people').value });
  });

  byId('form-vehicles').addEventListener('submit', (event) => {
    event.preventDefault();
    state.lastKind = 'vehicle';
    post('search', { kind: 'vehicle', query: byId('query-vehicles').value });
  });

  byId('form-bolo').addEventListener('submit', (event) => {
    event.preventDefault();
    post('bolo', {
      kind: byId('bolo-kind').value,
      value: byId('bolo-value').value,
      reason: byId('bolo-reason').value,
      minutes: Number(byId('bolo-minutes').value) || 120,
    });

    byId('bolo-value').value = '';
    byId('bolo-reason').value = '';
  });

  byId('verdict-impound').addEventListener('click', () => post('impound', { reason: 'police seizure' }));

  byId('form-report').addEventListener('submit', (event) => {
    event.preventDefault();

    const charges = [];

    document.querySelectorAll('#report-charges input:checked').forEach((box) => {
      charges.push(box.value);
    });

    post('report', {
      kind: byId('report-kind').value,
      title: byId('report-title').value,
      body: byId('report-body').value,
      subjects: byId('report-subjects').value.split(',').map((name) => name.trim()).filter(Boolean),
      plate: byId('report-plate').value,
      charges,
    });

    byId('report-title').value = '';
    byId('report-body').value = '';
    byId('report-subjects').value = '';
    byId('report-plate').value = '';
    document.querySelectorAll('#report-charges input:checked').forEach((box) => { box.checked = false; });
  });

  window.addEventListener('message', (event) => {
    const data = event.data || {};

    switch (data.action) {
      case 'open':
        return open(data);
      case 'close':
        return close();
      case 'results':
        return renderResults(data.result);
      case 'status':
        return renderStatus(data.status);
      case 'callout':
        return renderCalls(data.calls || []);
      case 'mdt':
        return renderBundle(data.bundle);
      case 'hud':
        return renderHud(data.hud);
      case 'reportDraft':
        showTab('reports');
        if (byId('report-title')) byId('report-title').value = data.title || '';
        return undefined;
      case 'field': {
        if (!state.open) return undefined;
        const card = el('div', 'card');
        card.appendChild(el('h2', null, `${data.kind} result`));
        card.appendChild(el('p', null, JSON.stringify(data.result)));
        results.appendChild(card);
        return undefined;
      }
      default:
        return undefined;
    }
  });

  // Also usable outside the game (preview/debug): window.mdt.open({ ... }).
  window.mdt = {
    open,
    close,
    showTab,
    renderResults,
    renderStatus,
    renderCalls,
    renderCharges,
    renderBundle,
    renderHud,
    state,
    post,
  };
})();
