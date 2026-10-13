// Traces one CPU in one frame: node tools/test/trace.js frame cpu [count] [--input=...]
'use strict';
const fs = require('fs');
const path = require('path');
const { dis, h4 } = require('./z80dis');
const args = process.argv.slice(2);
const opt = (name, def) => { const a = args.find(x => x.startsWith('--' + name + '=')); return a ? a.substring(name.length + 3) : def; };
const pos = args.filter(x => !x.startsWith('--'));
const frame = +pos[0], cpuSel = +pos[1], count = +(pos[2] || 300), skip = +opt('skip', 0);
const buttons = { left: 1, right: 2, up: 3, down: 4, fire: 5, coin: 6, start1: 7, start2: 8, coin2: 9, test: 10, service: 11 };
const script = (opt('input', '') || '').split(',').filter(Boolean).map(s => { const m = /^(\d+):(\w+)([+-])$/.exec(s); return { frame: +m[1], button: buttons[m[2]], pressed: m[3] === '+' }; });
let src = fs.readFileSync(path.join(__dirname, 'galaga_machine.js'), 'utf8');
const marker = 'while (($cyc < $runtarget)) {';
const at = src.indexOf(marker, src.indexOf('function $execute'));
src = src.substring(0, at + marker.length) + '\n if (HOOK) HOOK($cpuno, $rpc, $halted, $ra, $rf, $rb, $rc, $rd, $re, $rh, $rl, $rsp, $wrcnt, $cyc);' + src.substring(at + marker.length);
src = src.replace("module.exports = function create() {", "module.exports = function create(HOOK) {");
const m = { exports: {} };
new Function('module', 'require', src)(m, require);
let on = false, n = 0, skipped = 0;
const roms = [null, Buffer.alloc(16384), Buffer.alloc(16384), Buffer.alloc(16384)];
const hx = v => v.toString(16).padStart(2, '0');
const M = m.exports((cpu, pc, halted, a, f, b, c, d, e, h, l, sp, wr, cyc) => {
    if (!on || cpu !== cpuSel || n >= count) return;
    if (skipped++ < skip) return;
    n++;
    const rd = x => (x < 0x4000 ? roms[cpu][x] : M.PeekMemory(x));
    console.log(`${String(cyc).padStart(6)} ${h4(pc)} A${hx(a)} F${hx(f)} BC${hx(b)}${hx(c)} DE${hx(d)}${hx(e)} HL${hx(h)}${hx(l)} SP${sp.toString(16)} W${wr}  ${halted ? 'HALT' : dis(rd, pc)[0]}`);
});
const ROMS = [['.3p', 1, 0], ['.3m', 1, 4096], ['.2m', 1, 8192], ['.2l', 1, 12288], ['.3f', 2, 0], ['.2c', 3, 0],
    ['.4l', 4, 0], ['.4d', 5, 0], ['.4f', 5, 4096], ['.5n', 6, 0], ['.2n', 7, 0], ['.1c', 8, 0], ['.1d', 9, 0]];
const romDir = path.join(__dirname, '..', '..', 'ROMs');
for (const file of fs.readdirSync(romDir)) {
    const r = ROMS.find(x => file.toLowerCase().endsWith(x[0]));
    if (!r) continue;
    const data = fs.readFileSync(path.join(romDir, file));
    for (let i = 0; i < data.length; i++) M.LoadRom(r[1], r[2] + i, data[i]);
    if (r[1] <= 3) data.copy(roms[r[1]], r[2]);
}
M.Initialize();
for (let f = 1; f <= frame; f++) {
    for (const s of script) if (s.frame === f) M.SetButton(s.button, s.pressed);
    on = f === frame;
    M.RunFrame(false);
    M.GetFrameText();
}
