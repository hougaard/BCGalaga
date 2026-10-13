// Builds the browser harness: the translated machine and the ROMs as scripts for harness.html.
//   node tools/test/browser/make.js
'use strict';
const fs = require('fs');
const path = require('path');
const here = __dirname;
const src = fs.readFileSync(path.join(here, '..', 'galaga_machine.js'), 'utf8');
fs.writeFileSync(path.join(here, 'machine.gen.js'), 'var module = {};\n' + src + '\nwindow.createMachine = module.exports;\n');
const romDir = path.join(here, '..', '..', '..', 'ROMs');
const roms = {};
for (const f of fs.readdirSync(romDir)) roms[f] = fs.readFileSync(path.join(romDir, f)).toString('base64');
fs.writeFileSync(path.join(here, 'roms.gen.js'), 'window.ROMS = ' + JSON.stringify(roms) + ';\n');
console.log('harness built');
