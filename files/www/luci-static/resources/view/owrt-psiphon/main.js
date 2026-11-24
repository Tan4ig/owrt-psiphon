'use strict';
'require view';
'require ui';
'require rpc';

var callStatus = rpc.declare({ object: 'owrt-psiphon', method: 'status', expect: { '': {} } });
var callStart = rpc.declare({ object: 'owrt-psiphon', method: 'start', expect: { '': {} } });
var callStop = rpc.declare({ object: 'owrt-psiphon', method: 'stop', expect: { '': {} } });
var callAdopt = rpc.declare({ object: 'owrt-psiphon', method: 'adopt', expect: { '': {} } });
var callSetCountry = rpc.declare({ object: 'owrt-psiphon', method: 'set_country', params: [ 'country' ], expect: { '': {} } });
var callProbe = rpc.declare({ object: 'owrt-psiphon', method: 'probe', expect: { '': {} } });
var callScan = rpc.declare({ object: 'owrt-psiphon', method: 'scan', expect: { '': {} } });
var callScanStatus = rpc.declare({ object: 'owrt-psiphon', method: 'scan_status', expect: { '': {} } });
var E = (function(raw) { return function() { var a = Array.prototype.slice.call(arguments), i = a.length - 1; if (i >= 1 && (typeof a[i] === 'string' || typeof a[i] === 'number')) a[i] = [ String(a[i]) ]; return raw.apply(null, a); }; })(window.E);
var countries = [
        [ 'NL', 'Нидерланды' ], [ 'DE', 'Германия' ], [ 'BE', 'Бельгия' ],
        [ 'FR', 'Франция' ], [ 'GB', 'Великобритания' ], [ 'PL', 'Польша' ],
        [ 'CZ', 'Чехия' ], [ 'AT', 'Австрия' ], [ 'CH', 'Швейцария' ], [ 'US', 'США' ]
];

return view.extend({
        load: function() {
                return Promise.all([ callStatus(), callScanStatus().catch(function() { return {}; }) ]);
        },
        render: function(data) {
                var status = data[0] || {};
                var scan = data[1] || {};
                var root = E('div', { 'class': 'cbi-map' });
                var note = E('div', { 'class': 'alert-message' });
                var state = E('div', { 'class': 'cbi-section' });
                var country = E('select', { 'class': 'cbi-input-select', 'id': 'owrt-country' }, countries.map(function(c) {
                        return E('option', { 'value': c[0], 'selected': c[0] === (status.country || 'NL') }, c[1] + ' (' + c[0] + ')');
                }));
                var result = E('pre', { 'id': 'owrt-result', 'style': 'white-space:pre-wrap; overflow-wrap:anywhere' }, '');
                var scanBox = E('div', { 'id': 'owrt-scan', 'class': 'alert-message' }, scan.message || (scan.running ? 'Проверяется: ' + (scan.current || '…') : 'Автовыбор ещё не запускался'));
                var scanResults = E('div', { 'id': 'owrt-scan-results' });
                var subscription = status.subscription || 'socks5://192.168.1.1:8086#OWRTPsiphon';
                var pollActive = false;

                function notify(msg, type) {
                        ui.addNotification(null, E('p', {}, msg), type || 'info');
                }
                function updateStatus() {
                        return Promise.all([ callStatus(), callScanStatus().catch(function() { return {}; }) ]).then(function(v) {
                                status = v[0] || {}; scan = v[1] || {};
                                subscription = status.subscription || subscription;
                                state.innerHTML = '';
                                var rows = [
                                        [ 'Состояние', status.running ? (status.managed ? 'Запущен под procd' : 'Работает вручную') : 'Остановлен' ],
                                        [ 'Страна', status.country || '—' ],
                                        [ 'Выходной IP', status.exit_ip || '—' ],
                                        [ 'Фактическая страна выхода', status.exit_country || '—' ],
                                        [ 'Последняя задержка', status.latency_ms ? status.latency_ms + ' мс' : 'не измерена' ],
                                        [ 'Версия warp-plus', status.version || '—' ],
                                        [ 'SOCKS5', subscription ]
                                ];
                                rows.forEach(function(r) {
                                        state.appendChild(E('div', { 'class': 'tr' }, [
                                                E('div', { 'class': 'td left', 'style': 'font-weight:bold;width:34%' }, r[0]),
                                                E('div', { 'class': 'td' }, r[1])
                                        ]));
                                });
                                scanBox.textContent = scan.running ? 'Проверяется страна: ' + (scan.current || '…') : (scan.message || 'Автовыбор ещё не запускался');
                                scanResults.innerHTML = '';
                                if (scan.results && scan.results.length) {
                                        var table = E('table', { 'class': 'table' });
                                        table.appendChild(E('tr', {}, [ E('th', {}, 'Страна'), E('th', {}, 'Выход'), E('th', {}, 'Задержка'), E('th', {}, 'Результат') ]));
                                        scan.results.forEach(function(r) { table.appendChild(E('tr', {}, [ E('td', {}, r.country || '—'), E('td', {}, r.exit_country || '—'), E('td', {}, r.latency_ms != null ? r.latency_ms + ' мс' : '—'), E('td', {}, r.state === 'ok' ? 'доступна' : r.state === 'mismatch' ? 'другая страна' : 'нет ответа') ])); });
                                        scanResults.appendChild(table);
                                }
                                result.textContent = status.manual ? 'Обнаружен ранее запущенный вручную Psiphon. Нажмите «Перенять текущий туннель», чтобы передать его под управление procd. Будет короткое переподключение.' : '';
                        });
                }
                function pollScan() {
                        if (pollActive || !scan.running) return;
                        pollActive = true;
                        function tick() {
                                updateStatus().then(function() {
                                        if (scan.running) window.setTimeout(tick, 5000);
                                        else pollActive = false;
                                }).catch(function() { pollActive = false; });
                        }
                        window.setTimeout(tick, 2500);
                }
                function action(promise, success) {
                        promise.then(function(r) {
                                if (r && r.ok) notify(r.message || success, 'info');
                                else notify((r && r.message) || 'Операция не выполнена', 'error');
                                return updateStatus();
                        }).then(function() { pollScan(); }).catch(function(e) { notify('Ошибка RPC: ' + e, 'error'); });
                }
                function button(label, cls, fn) {
                        return E('button', { 'class': 'btn ' + cls, 'click': fn, 'style': 'margin:4px' }, label);
                }

                root.appendChild(E('h2', {}, 'OWRTPsiphon'));
                root.appendChild(E('p', {}, 'Psiphon через warp-plus. Управление отдельное от Steer: ссылка SOCKS5 остаётся постоянной при смене страны.'));
                root.appendChild(E('h3', {}, 'Состояние туннеля'));
                root.appendChild(state);
                root.appendChild(E('div', { 'class': 'cbi-section' }, [
                        E('h3', {}, 'Страна выхода'),
                        E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title', 'for': 'owrt-country' }, 'Страна'), E('div', { 'class': 'cbi-value-field' }, country) ]),
                        button('Применить страну', 'cbi-button-action', function() { action(callSetCountry(country.value), 'Страна сохранена'); }),
                        button('Автовыбор по задержке (10 стран)', 'cbi-button-positive', function() { action(callScan(), 'Проверка стран запущена'); }),
                        scanBox, scanResults
                ]));
                root.appendChild(E('div', { 'class': 'cbi-section' }, [
                        E('h3', {}, 'Управление'),
                        button('Запустить', 'cbi-button-positive', function() { action(callStart(), 'Запуск отправлен'); }),
                        button('Остановить', 'cbi-button-negative', function() { action(callStop(), 'Остановка отправлена'); }),
                        button('Перенять текущий туннель', 'cbi-button-action', function() {
                                if (confirm('Текущий ручной warp-plus будет перезапущен под управлением OWRTPsiphon. Возможен кратковременный обрыв соединений Steer. Продолжить?')) action(callAdopt(), 'Туннель передан службе');
                        }),
                        button('Проверить SOCKS', 'cbi-button', function() { action(callProbe(), 'Проверка завершена'); }),
                        button('Обновить', 'cbi-button', function() { updateStatus(); })
                ]));
                root.appendChild(E('div', { 'class': 'cbi-section' }, [
                        E('h3', {}, 'Ссылка для Steer'),
                        E('p', {}, 'Добавь эту строку в подписку Steer. Адрес и порт не меняются при выборе другой страны.'),
                        E('input', { 'class': 'cbi-input-text', 'readonly': 'readonly', 'value': subscription, 'style': 'width:100%;max-width:650px' }),
                        button('Скопировать SOCKS5-ссылку', 'cbi-button-action', function() {
                                var input = root.querySelector('input[readonly]');
                                input.select();
                                if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(subscription).then(function() { notify('Ссылка скопирована'); }).catch(function() { document.execCommand('copy'); notify('Ссылка скопирована'); });
                                else { document.execCommand('copy'); notify('Ссылка скопирована'); }
                        })
                ]));
                root.appendChild(result);
                root.appendChild(E('p', { 'class': 'alert-message warning' }, 'Важно: автоподбор последовательно проверяет страны и может временно прервать действующий туннель. Он не запускает десять туннелей одновременно.'));
                updateStatus().then(function() { pollScan(); });
                return root;
        }
});
