// Disassembles a ROM range: node tools/test/dis.js cpu from to   (cpu 1 main, 2 sub, 3 sound; hex addresses)
'use strict';
const fs = require('fs');
const path = require('path');
const { dis, h4 } = require('./z80dis');
const romDir = path.join(__dirname, '..', '..', 'ROMs');
const files = { 1: ['.3p', '.3m', '.2m', '.2l'], 2: ['.3f'], 3: ['.2c'] };
const names = fs.readdirSync(romDir);
const cpu = +process.argv[2];
const rom = Buffer.concat(files[cpu].map(ext => fs.readFileSync(path.join(romDir, names.find(n => n.toLowerCase().endsWith(ext))))));
let pc = parseInt(process.argv[3], 16);
const end = parseInt(process.argv[4], 16);
while (pc < end) {
    const [t, l] = dis(a => rom[a] || 0, pc);
    console.log(h4(pc), [...rom.slice(pc, pc + l)].map(v => v.toString(16).padStart(2, '0')).join(' ').padEnd(12), t);
    pc += l;
}
