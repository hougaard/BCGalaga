// Profiles the CPUs of the translated machine: which code they run in a range of frames.
//   node tools/test/profile.js fromFrame toFrame [cpu] [--input=...] [--top=40]
'use strict';
const fs = require('fs');
const path = require('path');
const { dis, h4 } = require('./z80dis');

const args = process.argv.slice(2);
const opt = (name, def) => { const a = args.find(x => x.startsWith('--' + name + '=')); return a ? a.substring(name.length + 3) : def; };
const pos = args.filter(x => !x.startsWith('--'));
const from = +(pos[0] || 0), to = +(pos[1] || 100), onlyCpu = pos[2] ? +pos[2] : 0;
const top = +opt('top', 40);
const buttons = { left: 1, right: 2, up: 3, down: 4, fire: 5, coin: 6, start1: 7, start2: 8, coin2: 9, test: 10, service: 11 };
const script = (opt('input', '') || '').split(',').filter(Boolean).map(s => {
    const m = /^(\d+):(\w+)([+-])$/.exec(s);
    return { frame: +m[1], button: buttons[m[2]], pressed: m[3] === '+' };
});

// inject a hook at the start of every instruction
let src = fs.readFileSync(path.join(__dirname, opt('module', 'galaga_machine.js')), 'utf8');
const marker = 'while (($cyc < $runtarget)) {';
const at = src.indexOf(marker, src.indexOf('function $execute'));
src = src.substring(0, at + marker.length) + '\n if (HOOK) HOOK($cpuno, $rpc, $halted);' + src.substring(at + marker.length);
src = src.replace("module.exports = function create() {", "module.exports = function create(HOOK) {");
const m = { exports: {} };
new Function('module', 'require', src)(m, require);

let counting = false;
const counts = [null, new Map(), new Map(), new Map()];
const M = m.exports((cpu, pc, halted) => {
    if (!counting) return;
    const k = halted ? -1 : pc;
    counts[cpu].set(k, (counts[cpu].get(k) || 0) + 1);
});
const ROMS = [['.3p', 1, 0], ['.3m', 1, 4096], ['.2m', 1, 8192], ['.2l', 1, 12288], ['.3f', 2, 0], ['.2c', 3, 0],
    ['.4l', 4, 0], ['.4d', 5, 0], ['.4f', 5, 4096], ['.5n', 6, 0], ['.2n', 7, 0], ['.1c', 8, 0], ['.1d', 9, 0]];
const romDir = path.join(__dirname, '..', '..', 'ROMs');
const roms = [null, Buffer.alloc(16384), Buffer.alloc(16384), Buffer.alloc(16384)];
for (const file of fs.readdirSync(romDir)) {
    const r = ROMS.find(x => file.toLowerCase().endsWith(x[0]));
    if (!r) continue;
    const data = fs.readFileSync(path.join(romDir, file));
    for (let i = 0; i < data.length; i++) M.LoadRom(r[1], r[2] + i, data[i]);
    if (r[1] <= 3) data.copy(roms[r[1]], r[2]);
}
M.Initialize();
for (let f = 1; f <= to; f++) {
    for (const s of script) if (s.frame === f) M.SetButton(s.button, s.pressed);
    counting = f >= from;
    M.RunFrame(false);
    M.GetFrameText();
}
for (let cpu = 1; cpu <= 3; cpu++) {
    if (onlyCpu && cpu !== onlyCpu) continue;
    const list = [...counts[cpu].entries()].sort((a, b) => b[1] - a[1]);
    const total = list.reduce((s, x) => s + x[1], 0);
    console.log(`---- CPU ${cpu}: ${total} instructions in frames ${from}-${to} (${(total / (to - from + 1)).toFixed(0)}/frame)`);
    const rd = a => (a < 0x4000 ? roms[cpu][a] : M.PeekMemory(a));
    for (const [pc, n] of list.slice(0, top)) {
        const text = pc < 0 ? 'HALTED' : dis(rd, pc)[0];
        console.log(`${pc < 0 ? '----' : h4(pc)}  ${(100 * n / total).toFixed(2).padStart(6)}%  ${text}`);
    }
}
