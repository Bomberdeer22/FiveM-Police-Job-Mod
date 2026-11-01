/* =========================================================================
   fk_economy — app.js
   Single NUI page that renders the money HUD and the customisation / staff
   menu. All money values arrive from the server via Lua messages; the page
   only ever sends *intent* (move the HUD, run a staff action).
   ========================================================================= */

(() => {
    'use strict';

    const DEMO = !!window.__FK_DEMO__;

    const $ = (selector, root = document) => root.querySelector(selector);
    const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

    const ICONS = {
        cash: '<svg viewBox="0 0 24 24"><rect x="2.5" y="6" width="19" height="12" rx="2.5"/><circle cx="12" cy="12" r="2.4"/><path d="M6.2 9.6v4.8M17.8 9.6v4.8"/></svg>',
        bank: '<svg viewBox="0 0 24 24"><path d="M3 21h18"/><path d="M5 21v-9M9.6 21v-9M14.4 21v-9M19 21v-9"/><path d="M2.4 11.2h19.2L12 4.2 2.4 11.2Z"/></svg>',
        other: '<svg viewBox="0 0 24 24"><rect x="3" y="6" width="18" height="13" rx="2.5"/><path d="M16 12.5h3"/></svg>',
    };

    const state = {
        resource: 'fk_economy',
        config: null,
        settings: null,
        balances: {},
        staff: false,
        players: [],
        selected: null,
        account: 'cash',
        menuOpen: false,
        ready: false,
        paused: false,
        dead: false,
        hasData: false,
        tween: {},
        rows: {},
        saveTimer: null,
        confirmTimer: null,
        staffTabVisible: false,
        tab: 'hud',
        dragging: false,
    };

    /* ---------------------------------------------------------------------
       Transport
       --------------------------------------------------------------------- */

    function post(name, data = {}) {
        if (DEMO) {
            if (typeof window.demoBridge === 'function') {
                window.demoBridge(name, data);
            }
            return;
        }
        fetch(`https://${state.resource}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data),
        }).catch(() => { /* resource stopped — nothing to do */ });
    }

    /* ---------------------------------------------------------------------
       Formatting helpers
       --------------------------------------------------------------------- */

    // NumberFormat instances are expensive; the HUD formats every frame while
    // a balance tweens, so keep them cached.
    const formatterCache = new Map();

    function numberFormatter(decimals) {
        const locale = (state.config && state.config.locale) || undefined;
        const key = `${locale}|${decimals}`;
        if (formatterCache.has(key)) return formatterCache.get(key);

        let formatter;
        try {
            formatter = new Intl.NumberFormat(locale, {
                minimumFractionDigits: decimals,
                maximumFractionDigits: decimals,
            });
        } catch (error) {
            formatter = null;
        }
        formatterCache.set(key, formatter);
        return formatter;
    }

    function formatMoney(value) {
        const currency = (state.config && state.config.currency) || { symbol: '$', decimals: 0, symbolFirst: true };
        const decimals = Number.isFinite(currency.decimals) ? currency.decimals : 0;
        const num = Number(value) || 0;
        const abs = Math.abs(num);

        const formatter = numberFormatter(decimals);
        let body;
        if (formatter) {
            body = formatter.format(abs);
        } else {
            body = abs.toFixed(decimals).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
        }

        const symbol = currency.symbol || '$';
        const withSymbol = currency.symbolFirst === false ? `${body}${symbol}` : `${symbol}${body}`;
        return num < 0 ? `-${withSymbol}` : withSymbol;
    }

    function formatCompact(value) {
        return formatMoney(value);
    }

    const clamp = (v, min, max) => Math.min(max, Math.max(min, v));

    function debounceSave() {
        clearTimeout(state.saveTimer);
        state.saveTimer = setTimeout(() => {
            post('saveSettings', { settings: state.settings });
        }, 220);
    }

    /* ---------------------------------------------------------------------
       Toasts
       --------------------------------------------------------------------- */

    function toast(title, message, kind = 'info', timeout = 4200) {
        const host = $('#toasts');
        if (!host) return;

        const el = document.createElement('div');
        el.className = `toast ${kind}`;
        el.innerHTML = `<div class="bar"></div><div><div class="toast-title"></div><div class="toast-msg"></div></div>`;
        el.querySelector('.toast-title').textContent = title || '';
        el.querySelector('.toast-msg').textContent = message || '';
        host.appendChild(el);

        setTimeout(() => {
            el.classList.add('out');
            setTimeout(() => el.remove(), 260);
        }, timeout);

        while (host.children.length > 4) host.firstChild.remove();
    }

    /* ---------------------------------------------------------------------
       HUD
       --------------------------------------------------------------------- */

    function accountIds() {
        const configured = (state.config && state.config.accounts) || [];
        const ids = configured.map((a) => a.id);
        if (!ids.length) ids.push('cash', 'bank');
        const order = ['cash', 'bank'];
        return ids.sort((a, b) => {
            const ia = order.indexOf(a);
            const ib = order.indexOf(b);
            return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
        });
    }

    function accountLabel(id) {
        const configured = ((state.config && state.config.accounts) || []).find((a) => a.id === id);
        return configured ? configured.label : id.charAt(0).toUpperCase() + id.slice(1);
    }

    function buildHudRows() {
        const host = $('#hud-rows');
        if (!host) return;
        host.innerHTML = '';
        state.rows = {};

        accountIds().forEach((id) => {
            const row = document.createElement('div');
            row.className = 'hud-row';
            row.dataset.account = id;
            row.innerHTML = `
                <span class="hud-ico">${ICONS[id] || ICONS.other}</span>
                <span class="hud-label">${accountLabel(id)}</span>
                <span class="hud-value">${formatMoney(state.balances[id] || 0)}</span>
            `;
            host.appendChild(row);
            state.rows[id] = { row, value: row.querySelector('.hud-value') };
        });
    }

    function renderMiniBalances() {
        const host = $('#balance-mini');
        if (!host) return;
        host.innerHTML = accountIds()
            .map((id) => `<div class="mini-row"><span>${accountLabel(id)}</span><strong>${formatCompact(state.balances[id] || 0)}</strong></div>`)
            .join('');
    }

    function tweenValue(id, from, to) {
        const row = state.rows[id];
        if (!row) return;

        if (state.tween[id]) cancelAnimationFrame(state.tween[id]);

        const animate = state.config ? state.config.animations !== false : true;
        const duration = (state.config && state.config.tweenMs) || 650;

        if (!animate || duration <= 0) {
            row.value.textContent = formatMoney(to);
            return;
        }

        const start = performance.now();
        const step = (now) => {
            const t = clamp((now - start) / duration, 0, 1);
            const eased = 1 - Math.pow(1 - t, 3);
            row.value.textContent = formatMoney(Math.round(from + (to - from) * eased));
            if (t < 1) {
                state.tween[id] = requestAnimationFrame(step);
            } else {
                row.value.textContent = formatMoney(to);
                state.tween[id] = null;
            }
        };
        state.tween[id] = requestAnimationFrame(step);
    }

    function flashHud(kind, account) {
        const hud = $('#hud');
        if (!hud) return;

        const gainClass = kind === 'gain' ? 'is-gain' : 'is-loss';
        hud.classList.remove('is-gain', 'is-loss');
        // Force a reflow so the flash restarts when two changes land quickly
        void hud.offsetWidth;
        hud.classList.add(gainClass);

        const row = state.rows[account] && state.rows[account].row;
        if (row) {
            row.classList.remove('is-gain', 'is-loss');
            void row.offsetWidth;
            row.classList.add(gainClass);
            clearTimeout(row._flashTimer);
            row._flashTimer = setTimeout(() => row.classList.remove('is-gain', 'is-loss'), 900);
        }

        clearTimeout(flashHud._timer);
        flashHud._timer = setTimeout(() => hud.classList.remove('is-gain', 'is-loss'), 900);
    }

    function pushDelta(id, diff) {
        if (!state.config || state.config.showDeltaFloat === false) return;
        const host = $('#hud-deltas');
        if (!host) return;

        const pill = document.createElement('div');
        pill.className = `delta-pill ${diff > 0 ? 'gain' : 'loss'}`;
        pill.textContent = `${diff > 0 ? '+' : '−'}${formatMoney(Math.abs(diff))} ${accountLabel(id).toUpperCase()}`;
        host.appendChild(pill);

        setTimeout(() => {
            pill.classList.add('out');
            setTimeout(() => pill.remove(), 520);
        }, 1700);

        while (host.children.length > 4) host.firstChild.remove();
    }

    function updateHudVisibility() {
        const hud = $('#hud');
        if (!hud) return;
        const visible = state.hasData && state.settings && state.settings.visible !== false && !state.dead;
        hud.classList.toggle('is-hidden', !visible);
        hud.classList.toggle('is-paused', !!state.paused);
    }

    function handleState(data) {
        const balances = data.balances || {};
        const first = !state.hasData;

        accountIds().forEach((id) => {
            const next = Number(balances[id]) || 0;
            const prev = Number(state.balances[id]) || 0;

            if (!first && next !== prev) {
                tweenValue(id, prev, next);
                pushDelta(id, next - prev);
                flashHud(next > prev ? 'gain' : 'loss', id);
            } else if (state.rows[id]) {
                state.rows[id].value.textContent = formatMoney(next);
            }
            state.balances[id] = next;
        });

        if (typeof data.staff === 'boolean') setStaff(data.staff);

        state.hasData = true;
        state.ready = true;
        renderMiniBalances();
        updateHudVisibility();
    }

    /* ---------------------------------------------------------------------
       Settings / HUD placement
       --------------------------------------------------------------------- */

    function applySettings(settings) {
        if (!settings) return;
        const opacity = Number(settings.opacity);
        state.settings = {
            visible: settings.visible !== false,
            x: Number(settings.x) || 0,
            y: Number(settings.y) || 0,
            scale: Number(settings.scale) || 1,
            opacity: Number.isFinite(opacity) ? clamp(opacity, 0.05, 1) : 1,
            compact: settings.compact === true,
        };

        const hud = $('#hud');
        const root = document.documentElement;
        root.style.setProperty('--scale', state.settings.scale);
        hud.style.left = `${state.settings.x}%`;
        hud.style.top = `${state.settings.y}%`;
        hud.style.opacity = state.settings.opacity;
        hud.classList.toggle('is-compact', state.settings.compact);

        syncControls();
        updateHudVisibility();
    }

    function syncControls() {
        const s = state.settings;
        if (!s) return;

        const visible = $('#opt-visible');
        const compact = $('#opt-compact');
        const scale = $('#opt-scale');
        const opacity = $('#opt-opacity');

        if (visible) visible.checked = s.visible !== false;
        if (compact) compact.checked = !!s.compact;

        const limits = (state.config && state.config.limits) || {};
        if (scale) {
            scale.min = limits.minScale ?? 0.65;
            scale.max = limits.maxScale ?? 1.8;
            scale.value = s.scale;
            $('#out-scale').textContent = `${s.scale.toFixed(2)}×`;
            setRangeFill(scale);
        }
        if (opacity) {
            opacity.min = limits.minOpacity ?? 0.25;
            opacity.max = limits.maxOpacity ?? 1;
            opacity.value = s.opacity;
            $('#out-opacity').textContent = `${Math.round(s.opacity * 100)}%`;
            setRangeFill(opacity);
        }

        const readout = $('#pos-readout');
        if (readout) readout.textContent = `${s.x.toFixed(1)}% · ${s.y.toFixed(1)}%`;
    }

    function setRangeFill(input) {
        const min = Number(input.min) || 0;
        const max = Number(input.max) || 100;
        const pct = ((Number(input.value) - min) / (max - min)) * 100;
        input.style.setProperty('--fill', `${pct}%`);
    }

    /** Keep the HUD fully on screen after a move or a resize. */
    function clampToViewport() {
        const hud = $('#hud');
        if (!hud || !state.settings) return;
        const rect = hud.getBoundingClientRect();
        const w = window.innerWidth;
        const h = window.innerHeight;
        const margin = 4;

        let changed = false;
        if (rect.right > w - margin) {
            state.settings.x = clamp(((w - rect.width - margin) / w) * 100, 0, 100);
            changed = true;
        }
        if (rect.bottom > h - margin) {
            state.settings.y = clamp(((h - rect.height - margin) / h) * 100, 0, 100);
            changed = true;
        }
        if (changed) applySettings(state.settings);
    }

    function applyPreset(corner) {
        const hud = $('#hud');
        if (!hud || !state.settings) return;

        // Measure the HUD with the origin at 0,0 so preset maths is simple.
        state.settings.x = 0;
        state.settings.y = 0;
        applySettings(state.settings);

        const rect = hud.getBoundingClientRect();
        const w = window.innerWidth;
        const h = window.innerHeight;
        const margin = 16;

        const x = corner.endsWith('l') ? margin : w - rect.width - margin;
        const y = corner.startsWith('t') ? margin : h - rect.height - margin;

        state.settings.x = Number(((x / w) * 100).toFixed(2));
        state.settings.y = Number(((y / h) * 100).toFixed(2));
        applySettings(state.settings);
        highlightPreset(corner);
        debounceSave();
    }

    function highlightPreset(corner) {
        $$('.preset').forEach((btn) => btn.classList.toggle('is-active', btn.dataset.preset === corner));
    }

    /* ---------------------------------------------------------------------
       Dragging
       --------------------------------------------------------------------- */

    function setupDrag() {
        const hud = $('#hud');
        let drag = null;

        hud.addEventListener('pointerdown', (event) => {
            if (!hud.classList.contains('is-editing')) return;
            event.preventDefault();

            const rect = hud.getBoundingClientRect();
            drag = {
                offsetX: event.clientX - rect.left,
                offsetY: event.clientY - rect.top,
            };
            try { hud.setPointerCapture(event.pointerId); } catch (_) { /* ignore */ }
        });

        const onMove = (event) => {
            if (!drag || !state.settings) return;
            const w = window.innerWidth;
            const h = window.innerHeight;
            state.settings.x = clamp(((event.clientX - drag.offsetX) / w) * 100, 0, 100);
            state.settings.y = clamp(((event.clientY - drag.offsetY) / h) * 100, 0, 100);
            applySettings(state.settings);
        };

        const endDrag = () => {
            if (!drag) return;
            drag = null;
            snapToEdges();
            debounceSave();
        };

        // Listen on window as well as the HUD so a drag keeps working even if
        // the cursor outruns the element (or pointer capture is unavailable).
        hud.addEventListener('pointermove', onMove);
        window.addEventListener('pointermove', onMove);
        window.addEventListener('pointerup', endDrag);
        window.addEventListener('pointercancel', endDrag);
        hud.addEventListener('pointerup', endDrag);
        hud.addEventListener('pointercancel', endDrag);

        window.addEventListener('resize', () => {
            if (!state.settings) return;
            clampToViewport();
        });
    }

    function snapToEdges() {
        const hud = $('#hud');
        if (!hud || !state.settings) return;
        const cfg = state.config || {};
        const snapPx = Number(cfg.edgeSnapPx) || 0;
        if (snapPx <= 0) return;

        const rect = hud.getBoundingClientRect();
        const w = window.innerWidth;
        const h = window.innerHeight;
        let changed = false;

        if (rect.left < snapPx) {
            state.settings.x = 0;
            changed = true;
        } else if (w - rect.right < snapPx) {
            state.settings.x = ((w - rect.width) / w) * 100;
            changed = true;
        }

        if (rect.top < snapPx) {
            state.settings.y = 0;
            changed = true;
        } else if (h - rect.bottom < snapPx) {
            state.settings.y = ((h - rect.height) / h) * 100;
            changed = true;
        }

        if (changed) {
            state.settings.x = Number(state.settings.x.toFixed(2));
            state.settings.y = Number(state.settings.y.toFixed(2));
            applySettings(state.settings);
        }
    }

    /* ---------------------------------------------------------------------
       Menu
       --------------------------------------------------------------------- */

    const PANEL_META = {
        hud: { title: 'HUD Layout', sub: 'Presets, fine tuning, or free dragging with the mouse.' },
        staff: { title: 'Staff Tools', sub: 'Give or take money. Every action is audit-logged.' },
        prices: { title: 'Price List', sub: 'Item prices from config.lua — managed by the server owner.' },
    };

    function setMenu(open, fromLua = false) {
        state.menuOpen = !!open;
        const menu = $('#menu');
        menu.classList.toggle('is-open', state.menuOpen);
        menu.setAttribute('aria-hidden', state.menuOpen ? 'false' : 'true');

        if (state.menuOpen) {
            setTab(state.tab || 'hud');
        } else {
            exitDragMode();
            resetTakeConfirm();
        }

        if (!fromLua) {
            post(state.menuOpen ? 'menuOpened' : 'close');
        }
    }

    function setTab(name) {
        if (name === 'staff' && !state.staffTabVisible) name = 'hud';

        const menu = $('#menu');
        if (!menu) return;

        exitDragMode();
        state.tab = name;

        $$('.tab', menu).forEach((tab) => tab.classList.toggle('is-active', tab.dataset.tab === name));
        $$('.panel', menu).forEach((panel) => panel.classList.toggle('is-active', panel.dataset.panel === name));

        const meta = PANEL_META[name] || PANEL_META.hud;
        $('#panel-title').textContent = meta.title;
        $('#panel-sub').textContent = meta.sub;

        if (name === 'staff') {
            post('requestPlayers');
            renderPlayers();
        }
    }

    /* Drag mode hides the menu panel so the HUD can be dragged anywhere,
       including over where the panel normally sits. */
    function enterDragMode() {
        if (!state.menuOpen) return;
        state.dragging = true;
        document.body.classList.add('is-dragging');
        $('#hud').classList.add('is-editing');
        if (state.settings) {
            highlightPreset(guessCorner());
            clampToViewport();
        }
    }

    function exitDragMode() {
        if (!state.dragging) return;
        state.dragging = false;
        document.body.classList.remove('is-dragging');
        $('#hud').classList.remove('is-editing');
        highlightPreset(guessCorner());
        debounceSave();
    }

    function guessCorner() {
        const s = state.settings;
        if (!s) return null;
        const left = s.x < 50;
        const top = s.y < 50;
        return top ? (left ? 'tl' : 'tr') : left ? 'bl' : 'br';
    }

    /* ---------------------------------------------------------------------
       Staff panel
       --------------------------------------------------------------------- */

    function setStaff(isStaff) {
        state.staff = !!isStaff;
        state.staffTabVisible = state.staff;

        const tab = $('#tab-staff');
        if (tab) {
            tab.style.display = state.staff ? '' : 'none';
            tab.classList.toggle('is-staff', state.staff);
        }
        $('#staff-pill').style.display = state.staff ? 'inline-block' : 'none';

        const denied = $('#staff-denied');
        const body = $('#staff-body');
        denied.hidden = state.staff;
        body.style.display = state.staff ? '' : 'none';

        if (!state.staff && state.tab === 'staff') {
            setTab('hud');
        }
    }

    function buildAccountSegments() {
        const host = $('#account-seg');
        if (!host) return;
        host.innerHTML = '';
        accountIds().forEach((id, index) => {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.dataset.account = id;
            btn.textContent = accountLabel(id);
            if (index === 0) btn.classList.add('is-active');
            host.appendChild(btn);
        });
        state.account = accountIds()[0] || 'cash';
    }

    function buildQuickAmounts() {
        const host = $('#quick-amounts');
        if (!host) return;
        host.innerHTML = '';
        const amounts = (state.config && state.config.staff && state.config.staff.quickAmounts) || [100, 500, 1000, 5000];
        amounts.forEach((amount) => {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'chip';
            btn.textContent = formatMoney(amount);
            btn.addEventListener('click', () => {
                $('#amount').value = amount;
                $('#amount').focus();
            });
            host.appendChild(btn);
        });
    }

    function buildReasons() {
        const select = $('#reason');
        if (!select) return;
        const reasons = (state.config && state.config.staff && state.config.staff.reasons) || ['Staff adjustment'];
        select.innerHTML = reasons.map((reason) => `<option value="${reason}">${reason}</option>`).join('');
        if (reasons.includes('Bonus')) select.value = 'Bonus';
    }

    function renderPlayers() {
        const host = $('#player-list');
        if (!host) return;

        if (!state.staff) {
            host.innerHTML = '<div class="list-empty">Staff access required.</div>';
            return;
        }

        const query = ($('#player-search').value || '').trim().toLowerCase();
        const players = state.players.filter((player) => {
            if (!query) return true;
            return String(player.id).includes(query) || (player.name || '').toLowerCase().includes(query);
        });

        if (!players.length) {
            host.innerHTML = '<div class="list-empty">No players match your search.</div>';
            return;
        }

        host.innerHTML = '';
        players.forEach((player) => {
            const balances = player.balances || {};
            const moneyText = accountIds()
                .map((id) => formatCompact(balances[id] || 0))
                .join(' · ');

            const row = document.createElement('button');
            row.type = 'button';
            row.className = 'player-row';
            row.dataset.id = player.id;
            if (state.selected && state.selected.id === player.id) row.classList.add('is-selected');

            row.innerHTML = `
                <span class="player-id">${player.id}</span>
                <span class="player-name">${escapeHtml(player.name || 'Unknown')}${player.isMe ? ' <span class="player-me">YOU</span>' : ''}</span>
                <span class="player-money">${moneyText}</span>
            `;

            row.addEventListener('click', () => selectTarget(player));
            host.appendChild(row);
        });
    }

    function selectTarget(player) {
        state.selected = player;
        $$('.player-row').forEach((row) => {
            row.classList.toggle('is-selected', Number(row.dataset.id) === player.id);
        });

        const card = $('#target-card');
        card.classList.remove('empty');
        card.querySelector('.target-name').textContent = player.name || 'Unknown';
        const balances = player.balances || {};
        card.querySelector('.target-meta').textContent = `ID ${player.id} · ${accountIds()
            .map((id) => `${accountLabel(id)} ${formatCompact(balances[id] || 0)}`)
            .join(' · ')}`;

        resetTakeConfirm();
    }

    function clearTarget() {
        state.selected = null;
        const card = $('#target-card');
        card.classList.add('empty');
        card.querySelector('.target-name').textContent = 'None';
        card.querySelector('.target-meta').textContent = 'Pick someone from the list';
    }

    function escapeHtml(value) {
        return String(value)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    function resetTakeConfirm() {
        const btn = $('#btn-take');
        if (!btn) return;
        clearTimeout(state.confirmTimer);
        btn.classList.remove('is-confirm');
        btn.innerHTML = '<span class="btn-ico">−</span> Take money';
        btn.dataset.confirm = 'false';
    }

    function readAmount() {
        const raw = Number($('#amount').value);
        if (!Number.isFinite(raw) || raw <= 0) return null;
        return Math.floor(raw);
    }

    function staffAction(mode) {
        if (!state.staff) {
            toast('Not allowed', 'You do not have staff permissions.', 'error');
            return;
        }
        if (!state.selected) {
            toast('No player selected', 'Pick a player from the list first.', 'warn');
            return;
        }
        const amount = readAmount();
        if (!amount) {
            toast('Invalid amount', 'Enter an amount greater than zero.', 'warn');
            $('#amount').focus();
            return;
        }
        const max = (state.config && state.config.limits && state.config.limits.maxPerAction) || 1000000;
        if (amount > max) {
            toast('Too much', `The per-action limit is ${formatMoney(max)}.`, 'warn');
            return;
        }

        post('staffAction', {
            mode,
            account: state.account,
            amount,
            target: state.selected.id,
            reason: $('#reason').value || 'Staff adjustment',
        });
    }

    function handleStaffResult(result) {
        if (!result) return;
        if (result.ok) {
            toast(result.title || 'Done', result.message || '', 'success');
            $('#amount').value = '';
            resetTakeConfirm();
            setTimeout(() => post('requestPlayers'), 350);
        } else {
            toast('Action failed', result.message || 'Unknown error.', 'error');
            resetTakeConfirm();
        }
    }

    /* ---------------------------------------------------------------------
       Prices
       --------------------------------------------------------------------- */

    function renderPrices() {
        const host = $('#price-list');
        if (!host) return;

        const items = (state.config && state.config.items) || {};
        const query = ($('#price-search').value || '').trim().toLowerCase();
        const groups = new Map();

        Object.entries(items).forEach(([key, item]) => {
            const label = item.label || key;
            const haystack = `${key} ${label} ${item.description || ''}`.toLowerCase();
            if (query && !haystack.includes(query)) return;

            const category = item.category || 'Other';
            if (!groups.has(category)) groups.set(category, []);
            groups.get(category).push({ key, label, item });
        });

        if (!groups.size) {
            host.innerHTML = '<div class="price-empty">No items match that search.</div>';
            $('#price-count').textContent = '';
            return;
        }

        const sorted = Array.from(groups.entries()).sort((a, b) => a[0].localeCompare(b[0]));
        let count = 0;

        host.innerHTML = sorted
            .map(([category, entries]) => {
                const rows = entries
                    .sort((a, b) => a.label.localeCompare(b.label))
                    .map(({ key, label, item }) => {
                        count += 1;
                        const desc = item.description
                            ? `<div class="price-item-desc">${escapeHtml(item.description)}</div>`
                            : '';
                        return `
                            <div class="price-item" data-key="${escapeHtml(key)}">
                                <div>
                                    <div class="price-item-name">${escapeHtml(label)}</div>
                                    ${desc}
                                </div>
                                <div class="price-item-right">
                                    <div class="price-item-value">${formatMoney(item.price || 0)}</div>
                                    <div class="price-item-key">${escapeHtml(key)}</div>
                                </div>
                            </div>
                        `;
                    })
                    .join('');
                return `<div class="price-group"><h3>${escapeHtml(category)}</h3>${rows}</div>`;
            })
            .join('');

        const total = Object.keys(items).length;
        $('#price-count').textContent = count === total ? `${total} items` : `${count} of ${total} items`;
    }

    /* ---------------------------------------------------------------------
       Wiring
       --------------------------------------------------------------------- */

    function applyConfig(config) {
        state.config = config || {};
        state.resource = state.config.resource || state.resource;

        if (state.config.accent) {
            document.documentElement.style.setProperty('--accent', state.config.accent);
        }

        const prefix = $('#amount-prefix');
        if (prefix) prefix.textContent = (state.config.currency && state.config.currency.symbol) || '$';

        const keyLabel = $('.key');
        if (keyLabel) keyLabel.textContent = state.config.key || 'F7';

        buildHudRows();
        buildAccountSegments();
        buildQuickAmounts();
        buildReasons();
        renderMiniBalances();
        renderPrices();
    }

    function bindUI() {
        // Tabs
        $$('.tab').forEach((tab) => {
            tab.addEventListener('click', () => setTab(tab.dataset.tab));
        });

        $('#close-btn').addEventListener('click', () => setMenu(false));
        $('#menu .menu-scrim').addEventListener('click', () => setMenu(false));

        document.addEventListener('keydown', (event) => {
            if (event.key !== 'Escape' || !state.menuOpen) return;
            event.preventDefault();
            if (state.dragging) {
                exitDragMode();
                return;
            }
            setMenu(false);
        });

        $('#btn-move').addEventListener('click', enterDragMode);
        $('#btn-drag-done').addEventListener('click', exitDragMode);

        // HUD controls
        const scale = $('#opt-scale');
        const opacity = $('#opt-opacity');

        scale.addEventListener('input', () => {
            state.settings.scale = Number(scale.value);
            applySettings(state.settings);
        });
        scale.addEventListener('change', () => {
            clampToViewport();
            debounceSave();
        });

        opacity.addEventListener('input', () => {
            state.settings.opacity = Number(opacity.value);
            applySettings(state.settings);
        });
        opacity.addEventListener('change', debounceSave);

        $('#opt-visible').addEventListener('change', (event) => {
            state.settings.visible = event.target.checked;
            applySettings(state.settings);
            debounceSave();
        });

        $('#opt-compact').addEventListener('change', (event) => {
            state.settings.compact = event.target.checked;
            applySettings(state.settings);
            debounceSave();
        });

        $$('.preset').forEach((btn) => {
            btn.addEventListener('click', () => applyPreset(btn.dataset.preset));
        });

        $$('[data-nudge]').forEach((btn) => {
            btn.addEventListener('click', () => {
                const step = 0.5;
                const dir = btn.dataset.nudge;
                if (dir === 'left') state.settings.x -= step;
                if (dir === 'right') state.settings.x += step;
                if (dir === 'up') state.settings.y -= step;
                if (dir === 'down') state.settings.y += step;
                state.settings.x = Number(clamp(state.settings.x, 0, 100).toFixed(2));
                state.settings.y = Number(clamp(state.settings.y, 0, 100).toFixed(2));
                applySettings(state.settings);
                clampToViewport();
                highlightPreset(guessCorner());
                debounceSave();
            });
        });

        $('#btn-reset').addEventListener('click', () => {
            post('resetSettings');
            toast('Layout reset', 'The HUD is back to its default position.', 'info', 2600);
        });

        // Staff controls
        $('#player-search').addEventListener('input', renderPlayers);
        $('#btn-refresh-players').addEventListener('click', () => post('requestPlayers'));

        $('#account-seg').addEventListener('click', (event) => {
            const btn = event.target.closest('button[data-account]');
            if (!btn) return;
            state.account = btn.dataset.account;
            $$('#account-seg button').forEach((b) => b.classList.toggle('is-active', b === btn));
            resetTakeConfirm();
        });

        $('#btn-give').addEventListener('click', () => staffAction('add'));

        const takeBtn = $('#btn-take');
        takeBtn.addEventListener('click', () => {
            if (takeBtn.dataset.confirm === 'true') {
                staffAction('remove');
                return;
            }
            if (!state.selected || !readAmount()) {
                staffAction('remove'); // reuse validation + toast feedback
                return;
            }
            takeBtn.dataset.confirm = 'true';
            takeBtn.classList.add('is-confirm');
            takeBtn.innerHTML = 'Confirm take';
            clearTimeout(state.confirmTimer);
            state.confirmTimer = setTimeout(resetTakeConfirm, 3500);
        });

        $('#amount').addEventListener('keydown', (event) => {
            if (event.key === 'Enter') staffAction('add');
        });

        $('#price-search').addEventListener('input', renderPrices);
    }

    function handleMessage(data) {
        switch (data.action) {
            case 'init':
                applyConfig(data.config);
                applySettings(data.settings);
                if (data.config && typeof data.config.staff === 'object' && data.config.staff.enabled) {
                    setStaff(true);
                }
                break;

            case 'state':
                handleState(data);
                break;

            case 'settings':
                applySettings(data.settings);
                break;

            case 'staffAccess':
                setStaff(data.staff);
                break;

            case 'players':
                state.players = data.players || [];
                if (state.selected) {
                    const fresh = state.players.find((p) => p.id === state.selected.id);
                    if (fresh) selectTarget(fresh);
                    else {
                        clearTarget();
                    }
                }
                renderPlayers();
                break;

            case 'staffResult':
                handleStaffResult(data.result);
                break;

            case 'notify':
                if (data.notification) {
                    const kind = data.notification.kind === 'error' ? 'error' : 'success';
                    toast(data.notification.title || '', data.notification.message || '', kind, 5000);
                }
                break;

            case 'menu':
                setMenu(data.open, true);
                break;

            case 'pause':
                state.paused = !!data.open;
                updateHudVisibility();
                break;

            case 'dead':
                state.dead = !!data.dead;
                updateHudVisibility();
                break;

            default:
                break;
        }
    }

    window.addEventListener('message', (event) => {
        const data = event.data;
        if (!data || typeof data !== 'object' || !data.action) return;
        handleMessage(data);
    });

    // -----------------------------------------------------------------------
    // Boot
    // -----------------------------------------------------------------------

    function boot() {
        bindUI();
        setupDrag();

        // Sensible defaults until Lua sends the real config.
        state.settings = { visible: true, x: 1, y: 78, scale: 1, opacity: 1, compact: false };
        applySettings(state.settings);

        post('ready');

        // Re-request balances when the page becomes visible again (alt-tab),
        // without rebuilding the whole UI.
        document.addEventListener('visibilitychange', () => {
            if (!document.hidden) post('refresh');
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
