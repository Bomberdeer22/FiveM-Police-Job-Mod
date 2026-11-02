/* =========================================================================
   preview/demo.js — dev-only mock bridge.
   Stands in for the Lua client so html/app.js can be exercised in a browser.
   Not shipped to the server and not referenced by the resource.
   ========================================================================= */

(() => {
    'use strict';

    const DEFAULTS = { visible: true, x: 1, y: 78, scale: 1, opacity: 1, compact: false };

    const demo = {
        cash: 1250,
        bank: 24500,
        staff: true,
        settings: { ...DEFAULTS },
        players: [
            { id: 1, name: 'Demo Officer', isMe: true },
            { id: 2, name: 'Sarah Miller', isMe: false, balances: { cash: 780, bank: 12300 } },
            { id: 4, name: 'James Cole', isMe: false, balances: { cash: 240, bank: 4100 } },
            { id: 7, name: 'Olivia Reyes', isMe: false, balances: { cash: 3120, bank: 68000 } },
            { id: 11, name: 'Marcus Webb', isMe: false, balances: { cash: 0, bank: 950 } },
        ],
        items: {
            bodycam: { label: 'Body Camera', price: 250, category: 'Equipment', description: 'Records your shift. Useful in court.' },
            radio: { label: 'Police Radio', price: 450, category: 'Equipment', description: 'Lets you talk to dispatch.' },
            handcuffs: { label: 'Handcuffs', price: 120, category: 'Equipment', description: 'Standard issue restraints.' },
            body_armour: { label: 'Armour Vest', price: 900, category: 'Equipment', description: 'Ballistic protection.' },
            spike_strips: { label: 'Spike Strips', price: 600, category: 'Equipment', description: 'One use per deployment.' },
            coffee: { label: 'Coffee', price: 5, category: 'Consumables', description: 'Keeps you awake on nights.' },
            donut: { label: 'Donut', price: 3, category: 'Consumables', description: 'Tradition.' },
            medkit: { label: 'Medical Kit', price: 150, category: 'Consumables', description: 'Stop the bleeding before EMS arrive.' },
            license_driving: { label: 'Driving License', price: 500, category: 'Licenses', description: 'Required to drive legally.' },
            license_weapon: { label: 'Weapon License', price: 2500, category: 'Licenses', description: 'Firearms permit.' },
            service_repair: { label: 'Vehicle Repair', price: 400, category: 'Services', description: 'Full repair at the station workshop.' },
            service_impound: { label: 'Impound Release', price: 750, category: 'Services', description: 'Get your vehicle back from the pound.' },
            vehicle_cruiser: { label: 'Patrol Cruiser', price: 45000, category: 'Vehicles', description: 'Issued to your department.' },
            vehicle_interceptor: { label: 'Interceptor', price: 85000, category: 'Vehicles', description: 'High speed pursuit unit.' },
        },
    };

    const send = (payload) => setTimeout(() => window.postMessage(payload, '*'), 0);

    const myBalances = () => ({ cash: demo.cash, bank: demo.bank });

    const balancesFor = (player) => (player.id === 1 ? myBalances() : { ...player.balances });

    function config() {
        return {
            resource: 'fk_economy',
            currency: { symbol: '$', code: 'USD', decimals: 0, symbolFirst: true },
            locale: 'en-GB',
            accent: '#3b82f6',
            accounts: [
                { id: 'cash', label: 'Cash' },
                { id: 'bank', label: 'Bank' },
            ],
            items: demo.items,
            limits: {
                minScale: 0.65,
                maxScale: 1.8,
                minOpacity: 0.25,
                maxOpacity: 1,
                maxPerAction: 1000000,
            },
            staff: {
                reasons: ['Payroll', 'Bonus', 'Fine', 'Correction', 'Refund', 'Testing'],
                quickAmounts: [100, 500, 1000, 5000, 25000],
                enabled: demo.staff,
            },
            key: 'F7',
            animations: true,
            tweenMs: 650,
            edgeSnapPx: 24,
            showDeltaFloat: true,
        };
    }

    const pushState = () => send({ action: 'state', balances: myBalances(), staff: demo.staff, name: 'Demo Officer' });

    const pushPlayers = () =>
        send({
            action: 'players',
            players: demo.players.map((player) => ({
                id: player.id,
                name: player.name,
                isMe: !!player.isMe,
                balances: balancesFor(player),
            })),
        });

    function handleStaffAction(data) {
        const player = demo.players.find((p) => p.id === Number(data.target));
        if (!player) {
            return send({ action: 'staffResult', result: { ok: false, message: 'That player is no longer online.' } });
        }

        const amount = Math.floor(Number(data.amount) || 0);
        const account = data.account === 'bank' ? 'bank' : 'cash';
        const balances = balancesFor(player);

        if (!amount || amount <= 0) {
            return send({ action: 'staffResult', result: { ok: false, message: 'Enter a valid amount.' } });
        }
        if (data.mode === 'remove' && (balances[account] || 0) < amount) {
            return send({
                action: 'staffResult',
                result: { ok: false, message: `${player.name} does not have enough ${account}.` },
            });
        }

        const delta = data.mode === 'remove' ? -amount : amount;
        balances[account] = (balances[account] || 0) + delta;

        if (player.id === 1) {
            demo.cash = balances.cash;
            demo.bank = balances.bank;
        } else {
            player.balances = balances;
        }

        pushState();
        pushPlayers();

        const verb = delta > 0 ? 'Added' : 'Removed';
        const prep = delta > 0 ? 'to' : 'from';
        send({
            action: 'staffResult',
            result: { ok: true, message: `${verb} $${Math.abs(delta).toLocaleString('en-US')} ${account} ${prep} ${player.name}` },
        });
    }

    window.demoBridge = (name, data = {}) => {
        switch (name) {
            case 'ready':
                setTimeout(() => {
                    send({ action: 'init', config: config(), settings: demo.settings });
                    pushState();
                    pushPlayers();
                }, 30);
                break;

            case 'refresh':
                pushState();
                break;

            case 'saveSettings':
                demo.settings = { ...demo.settings, ...data.settings };
                break;

            case 'resetSettings':
                demo.settings = { ...DEFAULTS };
                send({ action: 'settings', settings: demo.settings });
                break;

            case 'requestPlayers':
                pushPlayers();
                break;

            case 'close':
                send({ action: 'menu', open: false });
                break;

            case 'staffAction':
                handleStaffAction(data);
                break;

            default:
                break;
        }
    };

    /* ---------------------------------------------------------------------
       Demo control bar (stands in for the F7 keybind)
       --------------------------------------------------------------------- */

    function toolbar() {
        const bar = document.createElement('div');
        bar.id = 'demo-bar';
        bar.style.cssText = [
            'position:fixed',
            'top:16px',
            'left:16px',
            'z-index:120',
            'display:flex',
            'gap:6px',
            'align-items:center',
            'padding:7px 9px',
            'border-radius:12px',
            'background:rgba(10,15,26,.92)',
            'border:1px solid rgba(255,255,255,.1)',
            'box-shadow:0 12px 30px rgba(0,0,0,.5)',
            "font:600 11px/1 'Inter','Segoe UI',system-ui,sans-serif",
            'pointer-events:auto',
        ].join(';');

        const button = (label, handler) => {
            const b = document.createElement('button');
            b.type = 'button';
            b.textContent = label;
            b.style.cssText = [
                'padding:7px 10px',
                'border-radius:8px',
                'border:1px solid rgba(255,255,255,.12)',
                'background:rgba(255,255,255,.05)',
                'color:#dbe6f8',
                'font:inherit',
                'cursor:pointer',
            ].join(';');
            b.addEventListener('click', handler);
            bar.appendChild(b);
            return b;
        };

        const open = button('Open menu', () => send({ action: 'menu', open: true }));
        open.style.background = 'linear-gradient(140deg,#3b82f6,#2563eb)';
        open.style.borderColor = 'rgba(147,197,253,.4)';
        open.style.color = '#fff';

        button('Cash +$250', () => {
            demo.cash += 250;
            pushState();
        });

        button('Cash −$100', () => {
            demo.cash = Math.max(0, demo.cash - 100);
            pushState();
        });

        button('Bank +$1,000', () => {
            demo.bank += 1000;
            pushState();
        });

        button('Toggle HUD', () => {
            demo.settings = { ...demo.settings, visible: !demo.settings.visible };
            send({ action: 'settings', settings: demo.settings });
        });

        document.body.appendChild(bar);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', toolbar);
    } else {
        toolbar();
    }
})();
