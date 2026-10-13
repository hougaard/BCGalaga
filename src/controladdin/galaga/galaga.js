// Galaga Screen control add-in
// Shows the frames of the "Galaga Machine" codeunit: three 224x288 layers (tilemap, sprites, stars) of palette
// indexes, plays the sound (the Namco WSG registers are synthesized here, the 54XX noise is approximated) and
// sends the keyboard back to Business Central.
(function galagaScreen() {
    'use strict';
    if (!document.getElementById('controlAddIn')) {
        // not in the DOM yet: start when the page has loaded
        window.addEventListener('load', galagaScreen);
        return;
    }

    var W = 224, H = 288, N = W * H;
    var FRAME_MS = 1000 / 60.606;            // the arcade's frame rate
    var CLEAR = 96;                          // transparent in the tilemap and sprite layers (black in the palette)
    var MAX_BATCH = 10;                      // most frames asked for in one request (the page allows 10)
    var LEAD = 4;                            // frames to stay ahead of real time

    var root = document.getElementById('controlAddIn');
    root.innerHTML =
        '<div class="galaga-wrap" id="galagaWrap">' +
        '  <canvas id="galagaCanvas" width="224" height="288" tabindex="0"></canvas>' +
        '  <div class="galaga-status" id="galagaStatus">' +
        '    <div id="galagaStatusText">Loading Galaga...</div>' +
        '    <button id="galagaImport" class="galaga-button" style="display:none">Import ROMs...</button>' +
        '  </div>' +
        '  <div class="galaga-help" id="galagaHelp">&larr; &rarr; move &nbsp; SPACE fire &nbsp; 5 coin &nbsp; 1 / 2 start &nbsp; M sound &nbsp; I import ROMs &nbsp; END filter &nbsp; ` stats</div>' +
        '  <div class="galaga-fps" id="galagaFps"></div>' +
        '  <div class="galaga-info" id="galagaInfo"></div>' +
        '  <div class="galaga-toast" id="galagaToast"></div>' +
        '</div>';

    var canvas = document.getElementById('galagaCanvas');
    var wrap = document.getElementById('galagaWrap');
    var statusBox = document.getElementById('galagaStatus');
    var statusText = document.getElementById('galagaStatusText');
    var importButton = document.getElementById('galagaImport');
    var helpBox = document.getElementById('galagaHelp');
    var fpsBox = document.getElementById('galagaFps');
    var infoBox = document.getElementById('galagaInfo');
    var toastBox = document.getElementById('galagaToast');
    var toastTimer = 0;

    // WebGL draws the frame at the display resolution through an upscaling filter (End cycles the filters),
    // the 2D canvas (stretched by the browser) is the fallback
    var renderer = galagaCreateRenderer(canvas, W, H);
    var ctx = renderer ? null : canvas.getContext('2d');
    var image = ctx ? ctx.createImageData(W, H) : new ImageData(W, H);
    var pixels = new Uint32Array(image.data.buffer);
    var rgba = new Uint8Array(image.data.buffer);
    if (renderer) {
        try {
            var savedFilter = window.localStorage.getItem('galaga.filter');
            if (savedFilter !== null) renderer.mode = +savedFilter;
        } catch (e) { }
    }

    // ---------------------------------------------------------------- layout
    function resize() {
        // the rotated arcade monitor: 3:4
        var w = wrap.clientWidth, h = wrap.clientHeight;
        var ch = h, cw = Math.floor(h * 3 / 4);
        if (cw > w) { cw = w; ch = Math.floor(w * 4 / 3); }
        canvas.style.width = cw + 'px';
        canvas.style.height = ch + 'px';
        if (renderer) renderer.resize(cw, ch);
    }
    window.addEventListener('resize', resize);
    resize();

    function showToast(text, ms) {
        toastBox.textContent = text;
        toastBox.style.opacity = '1';
        clearTimeout(toastTimer);
        toastTimer = setTimeout(function () { toastBox.style.opacity = '0'; }, ms || 1500);
    }

    function nextFilter() {
        if (!renderer) {
            showToast('Upscaling filters need WebGL');
            return;
        }
        renderer.mode = renderer.mode + 1;
        showToast('Filter: ' + renderer.modes[renderer.mode] + '  (End)');
        try { window.localStorage.setItem('galaga.filter', String(renderer.mode)); } catch (e) { }
        draw();
    }

    // ---------------------------------------------------------------- frames
    // tokens: 2 characters of the URL safe base64 alphabet = 12 bits (see "Galaga Machine".GetFrameText)
    var ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    var DEC = new Int16Array(128);
    for (var a = 0; a < 64; a++) DEC[ALPHABET.charCodeAt(a)] = a;

    var tiles = new Uint8Array(N).fill(CLEAR);
    var sprites = new Uint8Array(N).fill(CLEAR);
    var stars = new Int32Array(0);           // pairs: pixel index, palette index
    var palette = new Uint32Array(97);
    for (var p = 0; p < 97; p++) palette[p] = 0xff000000;

    function tok(s, i) {
        return DEC[s.charCodeAt(i)] * 64 + DEC[s.charCodeAt(i + 1)];
    }

    function applyVideo(v) {
        if (!v || v === '-') return;
        var layer = tiles, pos = 0, rowEnd = 0;
        for (var i = 0; i + 1 < v.length; i += 2) {
            var t = tok(v, i);
            if (t < 3200) {
                // a run: color * 32 + length - 1
                var color = t >> 5;
                var end = pos + (t & 31) + 1;
                if (end > rowEnd) end = rowEnd;
                while (pos < end) layer[pos++] = color;
            } else if (t < 3500) {
                layer = tiles;
                pos = (t - 3200) * W;
                rowEnd = pos + W;
            } else if (t < 3800) {
                layer = sprites;
                pos = (t - 3500) * W;
                rowEnd = pos + W;
                sprites.fill(CLEAR, pos, rowEnd);
            } else {
                pos = rowEnd - W + (t - 3800);
            }
        }
    }

    function applyStars(s) {
        if (s === '=') return;
        var list = new Int32Array(Math.floor(s.length / 4) * 2);
        for (var i = 0, j = 0; i + 3 < s.length; i += 4) {
            var r = tok(s, i), c = tok(s, i + 2);
            list[j++] = (r >> 3) * W + (c >> 3);
            list[j++] = 32 + (r & 7) * 8 + (c & 7);
        }
        stars = list;
    }

    function applyFrame(frame) {
        var parts = frame.split('!');
        applyVideo(parts[0]);
        applyStars(parts.length > 1 ? parts[1] : '=');
        if (parts[2]) playSounds(parts[2]);
    }

    // the stars shine through where the tilemap and the sprites are transparent
    function draw() {
        for (var i = 0; i < N; i++) {
            var t = tiles[i];
            pixels[i] = palette[t !== CLEAR ? t : sprites[i]];
        }
        for (var j = 0; j < stars.length; j += 2) {
            var k = stars[j];
            if (tiles[k] === CLEAR && sprites[k] === CLEAR) pixels[k] = palette[stars[j + 1]];
        }
        if (renderer) renderer.draw(rgba);
        else ctx.putImageData(image, 0, 0);
    }

    // ---------------------------------------------------------------- frame loop
    var running = false;
    var inFlight = false;
    var queue = [];                          // frames received and not shown yet
    var events = [];                         // input since the last request
    var lastRequest = 0;
    var budgetStart = 0;                     // real time budget: the frames requested since then
    var requested = 0;
    var nextShow = 0;
    var serverMs = 0, roundTripMs = 0, lastBatch = 0;
    var shown = 0, fpsStart = performance.now();
    var showStats = false;

    function requestFrames() {
        if (!running || inFlight) return;
        var now = performance.now();
        var elapsed = now - lastRequest;
        lastRequest = now;
        // ask for the frames that keep the game LEAD frames ahead of real time
        var n = Math.floor((now - budgetStart) / FRAME_MS) + LEAD - requested;
        if (n > 3 * MAX_BATCH) {
            // the server cannot keep up: the game slows down instead of catching up later
            budgetStart = now - (requested - LEAD) * FRAME_MS;
            n = MAX_BATCH;
        }
        n = Math.max(1, Math.min(MAX_BATCH, n));
        requested += n;
        inFlight = true;
        var input = JSON.stringify(events);
        events = [];
        Microsoft.Dynamics.NAV.InvokeExtensibilityMethod('RequestFrames', [input, Math.round(elapsed), n]);
    }

    window.DrawFrames = function (batch, ms) {
        serverMs = ms;
        roundTripMs = performance.now() - lastRequest;
        inFlight = false;
        var list = batch ? batch.split(';') : [];
        lastBatch = list.length;
        for (var i = 0; i < list.length; i++) queue.push(list[i]);
        // far behind (e.g. the tab was hidden): apply the old frames without showing them
        while (queue.length > 3 * MAX_BATCH) applyFrame(queue.shift());
        requestFrames();
    };

    function animate(now) {
        if (queue.length && now >= nextShow) {
            // two frames at a time when they pile up
            var steps = queue.length > MAX_BATCH + 2 ? 2 : 1;
            while (steps-- > 0 && queue.length) applyFrame(queue.shift());
            draw();
            nextShow = Math.max(nextShow + FRAME_MS, now - FRAME_MS);
            shown++;
        }
        if (now - fpsStart > 1000) {
            if (showStats) {
                fpsBox.textContent = (shown * 1000 / (now - fpsStart)).toFixed(1) + ' fps | batch ' + lastBatch +
                    ' | server ' + serverMs + 'ms | round trip ' + Math.round(roundTripMs) + 'ms | queue ' + queue.length +
                    (audio && audio.state === 'running' ? (muted ? ' | muted (M)' : '') : ' | sound: press a key');
            }
            shown = 0;
            fpsStart = now;
        }
        requestAnimationFrame(animate);
    }
    requestAnimationFrame(animate);

    // ---------------------------------------------------------------- sound
    // The Namco WSG: 3 voices playing 32 sample 4-bit waveforms from the sound PROM. Its registers (one nibble each)
    // arrive with the frames; the voices are synthesized in a ScriptProcessorNode (an AudioWorklet would need https).
    var audio = null;
    var muted = false;
    var wsgGain = null;
    var regs = new Uint8Array(32);
    var waves = [];                          // 8 x Float32Array(32), -1..1
    var phase = [0, 0, 0];
    var noiseShort = null, noiseLong = null;

    function setWaves(hex) {
        waves = [];
        for (var w = 0; w < 8; w++) {
            var wave = new Float32Array(32);
            for (var i = 0; i < 32; i++) {
                var v;
                if (hex && hex.length >= 256) v = parseInt(hex.charAt(w * 32 + i), 16);
                else v = builtinWave(w, i);
                wave[i] = (v - 7.5) / 7.5;
            }
            waves.push(wave);
        }
    }

    // waveforms for when the sound PROM is missing: sine, square, triangle, saw, pulses, sine + octave
    function builtinWave(w, i) {
        var x = i / 32;
        switch (w) {
            case 0: return 7.5 + 7.5 * Math.sin(2 * Math.PI * x);
            case 1: return i < 16 ? 15 : 0;
            case 2: return i < 16 ? i : 31 - i;
            case 3: return i / 2;
            case 4: return i < 8 ? 15 : 0;
            case 5: return 7.5 + 5 * Math.sin(2 * Math.PI * x) + 2.5 * Math.sin(4 * Math.PI * x);
            case 6: return i < 4 ? 15 : 0;
            default: return 7.5 + 7.5 * Math.sin(2 * Math.PI * x) * (i < 16 ? 1 : 0.5);
        }
    }
    setWaves('');

    function initAudio() {
        if (!audio) {
            var AC = window.AudioContext || window.webkitAudioContext;
            if (!AC) return;
            audio = new AC();
            wsgGain = audio.createGain();
            wsgGain.gain.value = muted ? 0 : 0.5;
            wsgGain.connect(audio.destination);
            var node = audio.createScriptProcessor(1024, 0, 1);
            node.onaudioprocess = synthesize;
            node.connect(wsgGain);
            noiseShort = makeNoise(0.45, 7);
            noiseLong = makeNoise(1.1, 3.5);
        }
        // browsers only allow audio after a user gesture: called again on key presses and clicks
        if (audio.state === 'suspended') audio.resume();
    }

    function synthesize(e) {
        var out = e.outputBuffer.getChannelData(0);
        out.fill(0);
        // voice 0: waveform 05, frequency 10-14 (20 bits), volume 15; voice 1: 0A, 16-19, 1A; voice 2: 0F, 1B-1E, 1F
        var base = [16, 22, 27], wreg = [5, 10, 15], vreg = [21, 26, 31];
        for (var v = 0; v < 3; v++) {
            var vol = regs[vreg[v]];
            var b = base[v];
            // voice 0 has 5 frequency nibbles, voices 1 and 2 have 4 (the lowest nibble is 0)
            var freq = v === 0
                ? (regs[b + 4] << 16) | (regs[b + 3] << 12) | (regs[b + 2] << 8) | (regs[b + 1] << 4) | regs[b]
                : (regs[b + 3] << 16) | (regs[b + 2] << 12) | (regs[b + 1] << 8) | (regs[b] << 4);
            if (!vol || !freq) continue;
            // the chip runs at 96 kHz and adds freq to a 20 bit counter: its top 5 bits pick the sample
            var step = freq * 96000 / 1048576 * 32 / audio.sampleRate;
            var wave = waves[regs[wreg[v]] & 7];
            var ph = phase[v];
            var amp = vol / 15 / 3;
            for (var i = 0; i < out.length; i++) {
                out[i] += wave[(ph | 0) & 31] * amp;
                ph += step;
            }
            phase[v] = ph % 32;
        }
    }

    function setRegisters(hex) {
        for (var i = 0; i < 32; i++) regs[i] = parseInt(hex.charAt(i), 16);
    }

    // the 54XX makes the explosion noise: white noise with a falling filter
    function makeNoise(seconds, decay) {
        var len = Math.floor(audio.sampleRate * seconds);
        var buffer = audio.createBuffer(1, len, audio.sampleRate);
        var data = buffer.getChannelData(0);
        for (var i = 0; i < len; i++) data[i] = (Math.random() * 2 - 1) * Math.exp(-decay * i / audio.sampleRate);
        return buffer;
    }

    function playNoise(buffer, cutoff) {
        if (!audio || audio.state !== 'running' || muted) return;
        var src = audio.createBufferSource();
        var filter = audio.createBiquadFilter();
        var gain = audio.createGain();
        src.buffer = buffer;
        filter.type = 'lowpass';
        filter.frequency.setValueAtTime(cutoff, audio.currentTime);
        filter.frequency.exponentialRampToValueAtTime(80, audio.currentTime + buffer.duration);
        gain.gain.value = 0.6;
        src.connect(filter);
        filter.connect(gain);
        gain.connect(audio.destination);
        src.start();
    }

    // w(half)(32 hex) = new WSG registers (half 1: half a frame later), n(2 hex) = a 54XX command
    function playSounds(list) {
        var items = list.split(',');
        var boom = 0;
        for (var i = 0; i < items.length; i++) {
            var it = items[i];
            if (it.charAt(0) === 'w') {
                if (it.charAt(1) === '1') {
                    (function (hex) { setTimeout(function () { setRegisters(hex); }, FRAME_MS / 2); })(it.substring(2));
                } else {
                    setRegisters(it.substring(2));
                }
            } else if (it.charAt(0) === 'n') {
                var cmd = parseInt(it.substring(1), 16);
                if (cmd === 0x10) boom |= 1;
                else if (cmd === 0x20) boom |= 2;
            }
        }
        if (boom & 1) playNoise(noiseShort, 2500);
        if (boom & 2) playNoise(noiseLong, 900);
    }

    function setMuted(value) {
        muted = value;
        if (wsgGain) wsgGain.gain.value = muted ? 0 : 0.5;
        showToast(muted ? 'Sound off (M)' : 'Sound on (M)');
    }

    // ---------------------------------------------------------------- calls from Business Central
    window.Init = function (paletteHex, wavesHex) {
        for (var i = 0; i < 97; i++) {
            var r = parseInt(paletteHex.substr(i * 6, 2), 16);
            var g = parseInt(paletteHex.substr(i * 6 + 2, 2), 16);
            var b = parseInt(paletteHex.substr(i * 6 + 4, 2), 16);
            palette[i] = 0xff000000 | (b << 16) | (g << 8) | r;
        }
        setWaves(wavesHex);
        // the next frame sends everything
        tiles.fill(CLEAR);
        sprites.fill(CLEAR);
        stars = new Int32Array(0);
        queue = [];
    };

    window.ShowInfo = function (info) {
        infoBox.textContent = info;
    };

    window.ShowStatus = function (message, showImport) {
        statusText.textContent = message;
        statusBox.style.display = message ? 'flex' : 'none';
        importButton.style.display = showImport ? 'inline-block' : 'none';
    };

    window.ShowMessage = function (message) {
        showToast(message, 8000);
    };

    window.Start = function () {
        ShowStatus('', false);
        running = true;
        inFlight = false;
        lastRequest = performance.now() - FRAME_MS;
        budgetStart = performance.now();
        requested = 0;
        canvas.focus();
        requestFrames();
    };

    importButton.addEventListener('click', function () {
        Microsoft.Dynamics.NAV.InvokeExtensibilityMethod('ImportRomsRequested', []);
    });

    // ---------------------------------------------------------------- keyboard
    // browser key -> button of the machine: 1 left, 2 right, 3 up, 4 down, 5 fire, 6 coin, 7 start 1, 8 start 2,
    // 9 coin 2, 10 test switch, 11 service credit
    var KEYMAP = {
        'ArrowLeft': 1, 'KeyA': 1, 'ArrowRight': 2, 'KeyD': 2, 'ArrowUp': 3, 'ArrowDown': 4,
        'Space': 5, 'ControlLeft': 5, 'ControlRight': 5, 'KeyZ': 5, 'KeyX': 5,
        'Digit5': 6, 'KeyC': 6, 'Digit1': 7, 'Enter': 7, 'Digit2': 8, 'Digit6': 9, 'F2': 10, 'Digit9': 11
    };
    var keysDown = {};

    function setStatsVisible(visible) {
        showStats = visible;
        fpsBox.style.display = visible ? '' : 'none';
        infoBox.style.display = visible ? '' : 'none';
    }
    setStatsVisible(false);

    canvas.addEventListener('keydown', function (e) {
        initAudio();
        helpBox.style.opacity = '0';
        if (e.code === 'End') {
            nextFilter();
            e.preventDefault();
            return;
        }
        if (e.code === 'Backquote') {
            setStatsVisible(!showStats);
            e.preventDefault();
            return;
        }
        if (e.code === 'KeyM') {
            setMuted(!muted);
            e.preventDefault();
            return;
        }
        if (e.code === 'KeyI') {
            Microsoft.Dynamics.NAV.InvokeExtensibilityMethod('ImportRomsRequested', []);
            e.preventDefault();
            return;
        }
        var b = KEYMAP[e.code];
        if (!b) return;
        e.preventDefault();
        if (keysDown[e.code]) return;   // auto repeat
        keysDown[e.code] = true;
        events.push([0, b]);
    });
    canvas.addEventListener('keyup', function (e) {
        var b = KEYMAP[e.code];
        if (!b) return;
        e.preventDefault();
        keysDown[e.code] = false;
        events.push([1, b]);
    });
    canvas.addEventListener('blur', function () {
        for (var code in keysDown) {
            if (keysDown[code]) events.push([1, KEYMAP[code]]);
        }
        keysDown = {};
    });
    canvas.addEventListener('click', function () {
        initAudio();
        canvas.focus();
    });

    Microsoft.Dynamics.NAV.InvokeExtensibilityMethod('ControlReady', []);
}());
