// Counts the AL statements and procedure calls per frame (a model of the AL runtime cost: every AL statement
// calls StmtHit, every procedure call allocates a scope object).
//   python tools/al2js.py src/GalagaMachine.Codeunit.al tools/test/galaga_count.js --fast --count
//   node tools/test/cost.js from to [--input=...]
'use strict';
const fs = require('fs');
const path = require('path');
const args = process.argv.slice(2);
const opt = (name, def) => { const a = args.find(x => x.startsWith('--' + name + '=')); return a ? a.substring(name.length + 3) : def; };
const pos = args.filter(x => !x.startsWith('--'));
const from = +(pos[0] || 1500), to = +(pos[1] || 1800);
const buttons = { left: 1, right: 2, up: 3, down: 4, fire: 5, coin: 6, start1: 7, start2: 8, coin2: 9, test: 10, service: 11 };
const script = (opt('input', '1000:coin+,1008:coin-,1100:start1+,1108:start1-,1500:left+,1560:left-,1500:fire+,1504:fire-,1600:right+,1700:right-') || '').split(',').filter(Boolean)
    .map(s => { const m = /^(\d+):(\w+)([+-])$/.exec(s); return { frame: +m[1], button: buttons[m[2]], pressed: m[3] === '+' }; });
const M = require(path.join(__dirname, opt('module', 'galaga_count.js')))();
const ROMS = [['.3p', 1, 0], ['.3m', 1, 4096], ['.2m', 1, 8192], ['.2l', 1, 12288], ['.3f', 2, 0], ['.2c', 3, 0],
    ['.4l', 4, 0], ['.4d', 5, 0], ['.4f', 5, 4096], ['.5n', 6, 0], ['.2n', 7, 0], ['.1c', 8, 0], ['.1d', 9, 0]];
const romDir = path.join(__dirname, '..', '..', 'ROMs');
for (const file of fs.readdirSync(romDir)) {
    const r = ROMS.find(x => file.toLowerCase().endsWith(x[0]));
    if (!r) continue;
    const data = fs.readFileSync(path.join(romDir, file));
    for (let i = 0; i < data.length; i++) M.LoadRom(r[1], r[2] + i, data[i]);
}
M.Initialize();
let base = null;
const snap = () => { const s = M._stats(); return { ST: { ...s.ST }, CALLS: { ...s.CALLS } }; };
let textLen = 0;
for (let f = 1; f <= to; f++) {
    for (const s of script) if (s.frame === f) M.SetButton(s.button, s.pressed);
    if (f === from) base = snap();
    M.RunFrame(true);
    const t = M.GetFrameText();
    if (f >= from) textLen += t.length;
}
const end = snap(), n = to - from + 1;
const rows = Object.keys(end.ST).map(k => [k, ((end.ST[k] || 0) - (base.ST[k] || 0)) / n, ((end.CALLS[k] || 0) - (base.CALLS[k] || 0)) / n])
    .filter(r => r[1] > 0 || r[2] > 0).sort((a, b) => b[1] - a[1]);
let ts = 0, tc = 0;
console.log('procedure'.padEnd(20), 'statements/frame'.padStart(17), 'calls/frame'.padStart(12));
for (const [k, st, c] of rows) { ts += st; tc += c; console.log(k.padEnd(20), st.toFixed(0).padStart(17), c.toFixed(1).padStart(12)); }
console.log('TOTAL'.padEnd(20), ts.toFixed(0).padStart(17), tc.toFixed(1).padStart(12));
console.log('frame text', (textLen / n).toFixed(0), 'chars/frame');
