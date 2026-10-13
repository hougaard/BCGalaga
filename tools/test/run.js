// Runs the translated "Galaga Machine" codeunit with node: loads the ROMs, runs frames, decodes the frame text the way
// the control add-in does and writes PNG snapshots.
//
//   python tools/al2js.py src/GalagaMachine.Codeunit.al tools/test/galaga_machine.js [--fast]
//   node tools/test/run.js [frames] [--png=every] [--input="frame:button+,frame:button-,..."] [--out=dir]
'use strict';
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const args = process.argv.slice(2);
const opt = (name, def) => {
    const a = args.find(x => x.startsWith('--' + name + '='));
    return a ? a.substring(name.length + 3) : def;
};
const frames = parseInt(args.find(x => !x.startsWith('--')) || '600', 10);
const pngEvery = parseInt(opt('png', '60'), 10);
const outDir = opt('out', path.join(__dirname, 'out'));
const module_ = opt('module', path.join(__dirname, 'galaga_machine.js'));
const romDir = opt('roms', path.join(__dirname, '..', '..', 'ROMs'));
const buttons = { left: 1, right: 2, up: 3, down: 4, fire: 5, coin: 6, start1: 7, start2: 8, coin2: 9, test: 10, service: 11 };
// input script: "frame:button+" press, "frame:button-" release
const script = (opt('input', '') || '').split(',').filter(Boolean).map(s => {
    const m = /^(\d+):(\w+)([+-])$/.exec(s);
    if (!m) throw new Error('bad input ' + s);
    return { frame: +m[1], button: buttons[m[2]], pressed: m[3] === '+' };
});

fs.mkdirSync(outDir, { recursive: true });
const M = require(module_)();

// the same mapping as the "Galaga ROM Loader" codeunit: region, offset by the chip location in the file name
const ROMS = [
    ['.3p', 1, 0], ['.3m', 1, 4096], ['.2m', 1, 8192], ['.2l', 1, 12288], ['.3f', 2, 0], ['.2c', 3, 0],
    ['.4l', 4, 0], ['.4d', 5, 0], ['.4f', 5, 4096], ['.5n', 6, 0], ['.2n', 7, 0], ['.1c', 8, 0], ['.1d', 9, 0]];
for (const file of fs.readdirSync(romDir)) {
    const r = ROMS.find(x => file.toLowerCase().endsWith(x[0]));
    if (!r) continue;
    const data = fs.readFileSync(path.join(romDir, file));
    for (let i = 0; i < data.length; i++) M.LoadRom(r[1], r[2] + i, data[i]);
    console.log('loaded', file, '-> region', r[1], 'offset', r[2], data.length, 'bytes');
}
let t0 = Date.now();
M.Initialize();
console.log('initialize', Date.now() - t0, 'ms, color PROMs', M.HasColorProms(), 'sound PROM', M.HasSoundProm());

// ---------------------------------------------------------------- decoding (same as galaga.js)
const ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
const DEC = {};
for (let i = 0; i < 64; i++) DEC[ALPHA[i]] = i;
const W = 224, H = 288;
const tiles = new Uint8Array(W * H).fill(96);     // the layers, as the add-in keeps them
const sprites = new Uint8Array(W * H).fill(96);
let stars = [];
const indexes = new Uint8Array(W * H).fill(96);   // the composed frame
const palHex = M.GetPaletteText();
const palette = [];
for (let i = 0; i < 97; i++) palette.push([0, 2, 4].map(k => parseInt(palHex.substr(i * 6 + k, 2), 16)));

function applyFrame(text) {
    const [video, starText, sound] = text.split('!');
    let layer = null, row = -1, x = 0;
    const checkRow = () => { if (layer === tiles && row >= 0 && x !== W) throw new Error('tile row ' + row + ' has ' + x + ' pixels'); };
    if (video && video !== '-') {
        for (let i = 0; i < video.length; i += 2) {
            const v = DEC[video[i]] * 64 + DEC[video[i + 1]];
            if (v >= 3800) {
                x = v - 3800;
            } else if (v >= 3500) {
                checkRow();
                layer = sprites; row = v - 3500; x = 0;
                sprites.fill(96, row * W, row * W + W);
            } else if (v >= 3200) {
                checkRow();
                layer = tiles; row = v - 3200; x = 0;
            } else {
                const color = v >> 5, n = (v & 31) + 1;
                if (x + n > W) throw new Error('run past the end of row ' + row);
                layer.fill(color, row * W + x, row * W + x + n);
                x += n;
            }
        }
        checkRow();
    }
    if (starText !== '=') {
        stars = [];
        for (let i = 0; i + 3 < starText.length; i += 4) {
            const a = DEC[starText[i]] * 64 + DEC[starText[i + 1]], b = DEC[starText[i + 2]] * 64 + DEC[starText[i + 3]];
            stars.push([(a >> 3) * W + (b >> 3), 32 + (a & 7) * 8 + (b & 7)]);
        }
    }
    for (let i = 0; i < W * H; i++) indexes[i] = tiles[i] !== 96 ? tiles[i] : sprites[i];
    for (const [p, c] of stars) if (indexes[p] === 96) indexes[p] = c;
    return { videoChars: (video || '').length + (starText || '').length, sound };
}

// ---------------------------------------------------------------- PNG
const CRC = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
function crc32(buf) { let c = -1; for (const b of buf) c = CRC[(c ^ b) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; }
function chunk(type, data) {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
}
function writePng(file, scale, images, cols) {
    scale = scale || 2;
    images = images || [indexes];
    cols = Math.min(cols || 1, images.length);
    const rows = Math.ceil(images.length / cols);
    const w = (W * scale + 4) * cols, h = (H * scale + 4) * rows;
    const raw = Buffer.alloc((w * 3 + 1) * h);
    for (let y = 0; y < h; y++) {
        raw[y * (w * 3 + 1)] = 0;
        for (let x = 0; x < w; x++) {
            const cx = Math.floor(x / (W * scale + 4)), cy = Math.floor(y / (H * scale + 4));
            const ix = x % (W * scale + 4), iy = y % (H * scale + 4);
            const img = images[cy * cols + cx];
            const c = img && ix < W * scale && iy < H * scale ? palette[img[Math.floor(iy / scale) * W + Math.floor(ix / scale)]] : [60, 60, 60];
            raw.set(c, y * (w * 3 + 1) + 1 + x * 3);
        }
    }
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
    fs.writeFileSync(file, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr),
        chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]));
}

// ---------------------------------------------------------------- run
const hex = (v, n) => v.toString(16).toUpperCase().padStart(n || 4, '0');
let totalMs = 0, chars = 0;
const shots = (opt('shots', '') || '').split(',').filter(Boolean).map(Number);
const shotImages = [];
const sounds = [];
for (let f = 1; f <= frames; f++) {
    for (const s of script) if (s.frame === f) M.SetButton(s.button, s.pressed);
    t0 = process.hrtime.bigint();
    M.RunFrame(true);
    const text = M.GetFrameText();
    totalMs += Number(process.hrtime.bigint() - t0) / 1e6;
    const r = applyFrame(text);
    chars += r.videoChars;
    if (r.sound) sounds.push(f + ':' + r.sound);
    if (shots.includes(f)) shotImages.push(indexes.slice());
    if (pngEvery && f % pngEvery === 0) {
        writePng(path.join(outDir, 'frame' + String(f).padStart(5, '0') + '.png'));
        console.log('frame', f, 'PC', [1, 2, 3].map(c => hex(M.GetCpuRegister(c, 0))).join(' '),
            '| avg', (totalMs / f).toFixed(2), 'ms/frame | avg', Math.round(chars / f), 'video chars/frame');
    }
}
fs.writeFileSync(path.join(outDir, 'sound.log'), sounds.join('\n'));
if (shotImages.length) writePng(path.join(outDir, 'montage.png'), 1, shotImages, +opt('cols', 6));
console.log('done:', frames, 'frames,', (totalMs / frames).toFixed(2), 'ms/frame');
console.log('idle (skipped) cycles % main/sub/sound:', [1, 2, 3].map(c => M.GetIdlePercent(c)).join(' / '));
