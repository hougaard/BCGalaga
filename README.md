# Galaga for Business Central

An emulator of the Namco Galaga arcade board written in AL. It runs the original ROMs: three Z80 CPUs, the Namco
custom chips (06XX, 51XX, 54XX at a high level), the video hardware and the WSG sound registers. The
"Galaga Screen" control add-in only shows the frames, plays the sound and sends the keyboard back.

Open page **Galaga** (search "Galaga"). Keys: arrows move, Space fires, 5 inserts a coin, 1 / 2 start,
M sound on/off, End cycles the upscaling filters, ` shows timings, I imports ROMs.

## ROMs

The `ROMs` folder ships with the app as resources (the `galagao` set). Files are matched by the chip location at the
end of the name (`.3p`, `.3m`, `.2m`, `.2l` main CPU, `.3f` sub CPU, `.2c` sound CPU, `.4l` characters, `.4d` `.4f`
sprites), so `galaga` (gg1_1b.3p ...) works too. The color PROMs (`prom-5.5n`, `prom-4.2n`, `prom-3.1c`) and the sound
PROM (`prom-1.1d`) are in the parent set `galaga.zip`, not in the clone sets. Without them the colors are made up
and the add-in uses its own waveforms. Import `galaga.zip` on page **Galaga ROM Files** (or drop the PROM files into
`ROMs`) for the real colors and sound.

## Objects

| Object | |
|---|---|
| codeunit 66700 "Galaga Machine" | the emulator: memory map, custom chips, video, sound registers, Z80 (generated) |
| codeunit 66701 "Galaga ROM Loader" | finds the ROM files (imported, then app resources), imports zip romsets |
| codeunit 66702 "Galaga Session" | single instance: keeps the machine for the session, runs the frames for the page |
| page 66700 Galaga, controladdin "Galaga Screen" | the game |
| table 66700, page 66701 "Galaga ROM Files" | imported ROM files |

## How it works

- **Z80**: `tools/gen_z80.py` writes the interpreter into the `// <generated z80>` region of
  `GalagaMachine.Codeunit.al`. AL has no bit operators, so flags and AND/OR/XOR come from lookup tables. Every AL
  statement calls a debugger hook and every procedure call allocates a scope object, so the opcodes are written out
  with memory accesses inlined and the per-instruction overhead is a handful of statements.
- **Idle loops**: a short backward jump that comes back with the same registers and no memory changed is skipped to
  the end of the time slice; `JR $`-style loops let a CPU sleep until its next interrupt. The sub and sound CPUs are
  idle 70-85% of the time.
- **Video**: the tilemap and the sprites are drawn into separate 224x288 layers; only changed rows are sent, run
  length encoded, plus the star positions. The add-in stacks the layers.
- **Timing**: 60.6 frames per second, 264 lines of 192 cycles per CPU, the CPUs take turns every 4 lines. The
  add-in asks for as many frames as keep it 4 frames ahead of real time (10 per request at most).

## Tools

```sh
python tools/gen_z80.py                                                     # regenerate the Z80 interpreter
tools/compile.sh                                                            # compile check with the AL compiler
python tools/al2js.py src/GalagaMachine.Codeunit.al tools/test/galaga_machine.js   # AL -> JS (AL semantics, checked)
node tools/test/run.js 2400 --shots=1010,1500,2000 --input="1000:coin+,1008:coin-,1100:start1+,1108:start1-"
python tools/al2js.py src/GalagaMachine.Codeunit.al tools/test/galaga_count.js --fast --count
node tools/test/cost.js 1500 1800                                           # AL statements and calls per frame
node tools/test/profile.js 1500 1800 1                                      # hot code of a CPU
node tools/test/dis.js 1 0730 0770                                          # disassemble
node tools/test/browser/make.js                                             # then open tools/test/browser/harness.html
```

`al2js.py` runs the codeunit in node with AL's semantics (1-based bounds-checked arrays, Integer overflow errors, both
operands of `and`/`or` evaluated), so the emulator can be tested against the ROMs without a BC server.
`harness.html` runs the real control add-in with a mock of the page.

## Limitations

- The 05XX starfield is an approximation (the real star pattern comes from an LFSR in the chip).
- The 54XX explosion noise is approximated by the add-in.
- No cocktail cabinet (flip screen) support, no save states.
