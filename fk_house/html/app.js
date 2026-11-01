/* =========================================================================
   fk_house — app.js
   Renders the interaction card. The Lua side owns the keyboard, so this page
   never takes focus: it only displays what it is told.
   ========================================================================= */
(function () {
    'use strict';

    const card = document.getElementById('card');
    const titleEl = document.getElementById('title');
    const subtitleEl = document.getElementById('subtitle');
    const optionsEl = document.getElementById('options');
    const footerEl = document.getElementById('footer');

    function clearOptions() {
        while (optionsEl.firstChild) {
            optionsEl.removeChild(optionsEl.firstChild);
        }
    }

    function renderOption(option, position) {
        const row = document.createElement('li');
        row.className = 'option';
        row.dataset.index = String(option.index || position);

        const key = document.createElement('span');
        key.className = 'option__key';
        key.textContent = String(option.index || position);

        const body = document.createElement('div');
        body.className = 'option__body';

        const label = document.createElement('div');
        label.className = 'option__label';
        label.textContent = option.label || '';

        body.appendChild(label);

        if (option.hint) {
            const hint = document.createElement('div');
            hint.className = 'option__hint';
            hint.textContent = option.hint;
            body.appendChild(hint);
        }

        row.appendChild(key);
        row.appendChild(body);

        return row;
    }

    function show(data) {
        const payload = data || {};
        const options = Array.isArray(payload.options) ? payload.options : [];

        titleEl.textContent = payload.title || 'Michael\'s house';
        subtitleEl.textContent = payload.subtitle || 'Michael\'s house';
        footerEl.textContent = payload.footer || 'Press the number to choose · ESC to close';

        clearOptions();

        options.forEach((option, index) => {
            optionsEl.appendChild(renderOption(option, index + 1));
        });

        card.classList.remove('is-hidden');
        return options.length;
    }

    function hide() {
        card.classList.add('is-hidden');
        clearOptions();
    }

    window.houseUI = { show, hide };

    window.addEventListener('message', (event) => {
        const message = event.data || {};

        if (message.action === 'show') {
            show(message.data);
        } else if (message.action === 'hide') {
            hide();
        }
    });
})();
