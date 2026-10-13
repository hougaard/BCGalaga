#!/usr/bin/env python3
"""Generates the Z80 interpreter of the "Galaga Machine" codeunit.

AL has no bit operators, every statement costs a debugger hook call and every procedure call allocates a scope
object. So every opcode is written out with its memory accesses inlined, the flags come from lookup tables
(SZ, SZP, AndT, ...) built by InitTables, and the per instruction overhead is kept to a few statements.
The generated procedures replace the region between the '// <generated z80>' markers in
src/GalagaMachine.Codeunit.al.

    python tools/gen_z80.py

Simplifications (invisible to Galaga):
- The R register is derived from the cycle counter (the game only reads it for random numbers).
- Instruction operands are read from the ROM array without checking the address: code running outside the
  ROM (never in Galaga) is copied to a scratch area of the ROM array first (FetchSlow).
- Interrupts are only checked when IntPending is set.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, '..', 'src', 'GalagaMachine.Codeunit.al')

R8 = ['B', 'C', 'D', 'E', 'H', 'L', '(HL)', 'A']
VAR = {'B': 'rB', 'C': 'rC', 'D': 'rD', 'E': 'rE', 'H': 'rH', 'L': 'rL', 'A': 'rA'}
COND = ['(rF mod 128) < 64', '(rF mod 128) >= 64', '(rF mod 2) = 0', '(rF mod 2) = 1',
        '(rF mod 8) < 4', '(rF mod 8) >= 4', 'rF < 128', 'rF >= 128']


# ---------------------------------------------------------------- memory access (inlined)
def rd(dst, a):
    # 8000-FFFF RAM, 0000-3FFF the CPU's own ROM, 4000-7FFF I/O
    return (f'if {a} >= 32768 then {dst} := Mem[{a} + 1] else if {a} < 16384 then '
            f'{dst} := Rom[RomBase + {a} + 1] else {dst} := ReadMem({a});')


def wr(a, v):
    # WrCnt counts the writes that change memory, for the idle loop detection
    return (f'if ({a} >= 32768) and ({a} < 40960) then begin if Mem[{a} + 1] <> {v} then begin Mem[{a} + 1] := {v}; '
            f'WrCnt += 1; end; end else WriteMem({a}, {v});')


def fetch(dst):
    return [f'{dst} := Rom[RomBase + rPC + 1];', 'rPC += 1;']


def fetch16(dst):
    return [f'{dst} := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];', 'rPC += 2;']


def fetch_d():
    return ['d := Rom[RomBase + rPC + 1];', 'rPC += 1;', 'if d >= 128 then d -= 256;']


def wr_stack(v):
    # a push: below the stack pointer of the idle loop snapshot it only overwrites free stack space
    return (f'if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> {v} then begin Mem[rSP + 1] := {v}; '
            f'if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, {v});')


def push(hi, lo):
    return ['rSP := (rSP + 65535) mod 65536;', wr_stack(hi),
            'rSP := (rSP + 65535) mod 65536;', wr_stack(lo)]


def push_pc():
    return push('rPC div 256', 'rPC mod 256')


def pop(hi, lo):
    return [rd(lo, 'rSP'), 'rSP := (rSP + 1) mod 65536;', rd(hi, 'rSP'), 'rSP := (rSP + 1) mod 65536;']


def pop_pc():
    return pop('t', 'n') + ['rPC := t * 256 + n;']


def idle_jump(self_loop):
    """A short jump backwards: maybe an idle loop. self_loop is a condition for a loop that reads no memory
    (JR $, JP $, or LD SP,nn / JP back to it): only an interrupt can end it, whatever the other CPUs do."""
    check = ['if rPC <> IdleT then begin', '    IdleT := rPC;', '    IdleW := -1;', 'end else', '    IdleCheck();']
    if self_loop is None:
        return check
    return [f'if {self_loop} then begin',
            '    SelfIdle[CpuNo] := true;',
            '    IdleCycles[CpuNo] += RunTarget - Cyc;',
            '    Cyc := RunTarget;',
            'end else',
            '    if rPC <> IdleT then begin',
            '        IdleT := rPC;',
            '        IdleW := -1;',
            '    end else',
            '        IdleCheck();']


def indent(lines, n):
    return [' ' * n + line for line in lines]


# ---------------------------------------------------------------- arithmetic
def alu(k, v):
    """A := A <op> v for the 8 ALU operations (ADD ADC SUB SBC AND XOR OR CP). v is a variable."""
    if k == 0:
        return [f't := rA + {v};',
                'if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];',
                f'if (rA mod 16) + ({v} mod 16) > 15 then rF += 16;',
                f'if ((rA < 128) = ({v} < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;',
                'rA := t;']
    if k == 1:
        return ['c := rF mod 2;', f't := rA + {v} + c;',
                'if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];',
                f'if (rA mod 16) + ({v} mod 16) + c > 15 then rF += 16;',
                f'if ((rA < 128) = ({v} < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;',
                'rA := t;']
    if k == 2:
        return [f't := rA - {v};',
                'if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;',
                f'if (rA mod 16) < ({v} mod 16) then rF += 16;',
                f'if ((rA < 128) <> ({v} < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;',
                'rA := t;']
    if k == 3:
        return ['c := rF mod 2;', f't := rA - {v} - c;',
                'if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;',
                f'if (rA mod 16) - ({v} mod 16) - c < 0 then rF += 16;',
                f'if ((rA < 128) <> ({v} < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;',
                'rA := t;']
    if k == 4:
        return [f'rA := AndT[rA * 256 + {v} + 1];', 'rF := SZP[rA + 1] + 16;']
    if k == 5:
        return [f'rA := rA + {v} - 2 * AndT[rA * 256 + {v} + 1];', 'rF := SZP[rA + 1];']
    if k == 6:
        return [f'rA := rA + {v} - AndT[rA * 256 + {v} + 1];', 'rF := SZP[rA + 1];']
    # CP: the undocumented flags come from the operand
    return [f't := rA - {v};',
            f'if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[{v} + 1]; end else rF := SZ0[t + 1] + 2 + XYT[{v} + 1];',
            f'if (rA mod 16) < ({v} mod 16) then rF += 16;',
            f'if ((rA < 128) <> ({v} < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;']


def inc8(x):
    return [f'if {x} = 255 then {x} := 0 else {x} += 1;', f'rF := (rF mod 2) + SZHVinc[{x} + 1];']


def dec8(x):
    return [f'if {x} = 0 then {x} := 255 else {x} -= 1;', f'rF := (rF mod 2) + SZHVdec[{x} + 1];']


def add16(dst_get, dst_set, src):
    """ADD HL/IX/IY,rr: dst_get is an expression, dst_set a list of statements using t."""
    return ([f'w := {src};', f'hl := {dst_get};', 't := hl + w;',
             'rF := AndT[rF * 256 + 197];',      # keep S, Z and P/V (0xC4)
             'if (hl mod 4096) + (w mod 4096) > 4095 then rF += 16;',
             'if t > 65535 then begin t -= 65536; rF += 1; end;']
            + dst_set + ['rF += XYT[t div 256 + 1];'])


# ---------------------------------------------------------------- main opcodes
def main_ops():
    ops = {}
    ops[0x00] = (4, [])
    pairs = [('rB', 'rC'), ('rD', 'rE'), ('rH', 'rL')]
    for i, (hi, lo) in enumerate(pairs):
        b = i * 16
        ops[b + 0x01] = (10, [f'{lo} := Rom[RomBase + rPC + 1];', f'{hi} := Rom[RomBase + rPC + 2];', 'rPC += 2;'])
        ops[b + 0x03] = (6, [f'if {lo} < 255 then {lo} += 1 else begin {lo} := 0; if {hi} = 255 then {hi} := 0 else {hi} += 1; end;'])
        ops[b + 0x0B] = (6, [f'if {lo} > 0 then {lo} -= 1 else begin {lo} := 255; if {hi} = 0 then {hi} := 255 else {hi} -= 1; end;'])
        ops[b + 0x09] = (11, add16('rH * 256 + rL', ['rH := t div 256;', 'rL := t mod 256;'], f'{hi} * 256 + {lo}'))
    ops[0x31] = (10, fetch16('rSP'))
    ops[0x33] = (6, ['rSP := (rSP + 1) mod 65536;'])
    ops[0x3B] = (6, ['rSP := (rSP + 65535) mod 65536;'])
    ops[0x39] = (11, add16('rH * 256 + rL', ['rH := t div 256;', 'rL := t mod 256;'], 'rSP'))

    for k, r in enumerate(R8):
        if r == '(HL)':
            ops[0x34] = (11, ['ea := rH * 256 + rL;', rd('v', 'ea')] + inc8('v') + [wr('ea', 'v')])
            ops[0x35] = (11, ['ea := rH * 256 + rL;', rd('v', 'ea')] + dec8('v') + [wr('ea', 'v')])
            ops[0x36] = (10, fetch('n') + ['ea := rH * 256 + rL;', wr('ea', 'n')])
        else:
            ops[0x04 + 8 * k] = (4, inc8(VAR[r]))
            ops[0x05 + 8 * k] = (4, dec8(VAR[r]))
            ops[0x06 + 8 * k] = (7, fetch(VAR[r]))

    # rotates of A: only C, H = N = 0 and the undocumented flags change
    ops[0x07] = (4, ['c := rA div 128;', 'rA := (rA * 2) mod 256 + c;', 'rF := AndT[rF * 256 + 197] + c + XYT[rA + 1];'])
    ops[0x0F] = (4, ['c := rA mod 2;', 'rA := rA div 2 + c * 128;', 'rF := AndT[rF * 256 + 197] + c + XYT[rA + 1];'])
    ops[0x17] = (4, ['c := rA div 128;', 'rA := (rA * 2) mod 256 + rF mod 2;', 'rF := AndT[rF * 256 + 197] + c + XYT[rA + 1];'])
    ops[0x1F] = (4, ['c := rA mod 2;', 'rA := rA div 2 + (rF mod 2) * 128;', 'rF := AndT[rF * 256 + 197] + c + XYT[rA + 1];'])

    ops[0x02] = (7, ['ea := rB * 256 + rC;', wr('ea', 'rA')])
    ops[0x0A] = (7, ['ea := rB * 256 + rC;', rd('rA', 'ea')])
    ops[0x12] = (7, ['ea := rD * 256 + rE;', wr('ea', 'rA')])
    ops[0x1A] = (7, ['ea := rD * 256 + rE;', rd('rA', 'ea')])
    ops[0x22] = (16, fetch16('ea') + [wr('ea', 'rL'), 'ea := (ea + 1) mod 65536;', wr('ea', 'rH')])
    ops[0x2A] = (16, fetch16('ea') + [rd('rL', 'ea'), 'ea := (ea + 1) mod 65536;', rd('rH', 'ea')])
    ops[0x32] = (13, fetch16('ea') + [wr('ea', 'rA')])
    ops[0x3A] = (13, fetch16('ea') + [rd('rA', 'ea')])

    ops[0x08] = (4, ['t := rA * 256 + rF;', 'rA := AF2 div 256;', 'rF := AF2 mod 256;', 'AF2 := t;'])
    ops[0x10] = (8, fetch_d() + ['if rB = 0 then rB := 255 else rB -= 1;',
                                 'if rB <> 0 then begin rPC := (rPC + d + 65536) mod 65536; Cyc += 5; end;'])
    ops[0x18] = (12, fetch_d() + ['rPC := (rPC + d + 65536) mod 65536;', 'if (d < 0) and (d >= -20) then begin']
                 + indent(idle_jump('d = -2'), 4) + ['end;'])
    for i in range(4):
        ops[0x20 + 8 * i] = (7, fetch_d() + [f'if {COND[i]} then begin', '    rPC := (rPC + d + 65536) mod 65536;', '    Cyc += 5;',
                                             '    if (d < 0) and (d >= -20) then begin']
                             + indent(idle_jump('d = -2'), 8) + ['    end;', 'end;'])

    ops[0x27] = (4, [  # DAA
        't := rA;',
        'if (rF mod 4) >= 2 then begin',
        '    if ((rF mod 32) >= 16) or ((rA mod 16) > 9) then t -= 6;',
        '    if ((rF mod 2) = 1) or (rA > 153) then t -= 96;',
        'end else begin',
        '    if ((rF mod 32) >= 16) or ((rA mod 16) > 9) then t += 6;',
        '    if ((rF mod 2) = 1) or (rA > 153) then t += 96;',
        'end;',
        't := (t + 512) mod 256;',
        'c := AndT[rF * 256 + 4];',         # keep C and N
        'if rA > 153 then c := c - (c mod 2) + 1;',
        'if ((rA div 16) mod 2) <> ((t div 16) mod 2) then c += 16;',
        'rA := t;',
        'rF := c + SZP[rA + 1];'])
    ops[0x2F] = (4, ['rA := 255 - rA;', 'rF := AndT[rF * 256 + 198] + 18 + XYT[rA + 1];'])
    ops[0x37] = (4, ['rF := AndT[rF * 256 + 197] + 1 + XYT[rA + 1];'])
    ops[0x3F] = (4, ['c := rF mod 2;', 'rF := AndT[rF * 256 + 197] + c * 16 + (1 - c) + XYT[rA + 1];'])

    # LD r,r'
    for op in range(0x40, 0x80):
        if op == 0x76:
            # HALT: executed again until an interrupt (which skips it)
            ops[op] = (4, ['rPC -= 1;', 'Halted := true;', 'IdleCycles[CpuNo] += RunTarget - Cyc;', 'Cyc := RunTarget;'])
            continue
        dst, src = R8[(op >> 3) & 7], R8[op & 7]
        if src == '(HL)':
            ops[op] = (7, ['ea := rH * 256 + rL;', rd(VAR[dst], 'ea')])
        elif dst == '(HL)':
            ops[op] = (7, ['ea := rH * 256 + rL;', wr('ea', VAR[src])])
        elif dst == src:
            ops[op] = (4, [])
        else:
            ops[op] = (4, [f'{VAR[dst]} := {VAR[src]};'])

    # ALU A,r
    for op in range(0x80, 0xC0):
        k, src = (op >> 3) & 7, R8[op & 7]
        if src == '(HL)':
            ops[op] = (7, ['ea := rH * 256 + rL;', rd('v', 'ea')] + alu(k, 'v'))
        else:
            ops[op] = (4, alu(k, VAR[src]))

    for k in range(8):
        ops[0xC0 + 8 * k] = (5, [f'if {COND[k]} then begin'] + indent(pop_pc(), 4) + ['    Cyc += 6;', 'end;'])
        ops[0xC2 + 8 * k] = (10, fetch16('n') + [f'if {COND[k]} then begin', '    if (n < rPC) and (n >= rPC - 20) then begin', '        rPC := n;']
                             + indent(idle_jump(None), 8) + ['    end else', '        rPC := n;', 'end;'])
        ops[0xC4 + 8 * k] = (10, fetch16('n') + [f'if {COND[k]} then begin'] + indent(push_pc(), 4) + ['    rPC := n;', '    Cyc += 7;', 'end;'])
        ops[0xC6 + 8 * k] = (7, fetch('v') + alu(k, 'v'))
        ops[0xC7 + 8 * k] = (11, push_pc() + [f'rPC := {8 * k};'])
    for i, (hi, lo) in enumerate(pairs + [('rA', 'rF')]):
        ops[0xC1 + 16 * i] = (10, pop(hi, lo))
        ops[0xC5 + 16 * i] = (11, push(hi, lo))
    # JP nn: JP $ and "LD SP,nn / JP back to it" (the sub CPU's idle loop) read no memory
    ops[0xC3] = (10, fetch16('n') + ['if (n < rPC) and (n >= rPC - 20) then begin', '    rPC := n;']
                 + indent(idle_jump('(n = rPC - 3) or ((n = rPC - 6) and (Rom[RomBase + n + 1] = 49))'), 4)
                 + ['end else', '    rPC := n;'])
    ops[0xC9] = (10, pop_pc())
    ops[0xCD] = (17, fetch16('n') + push_pc() + ['rPC := n;'])
    ops[0xCB] = (0, ['ExecCB();'])
    ops[0xED] = (0, ['ExecED();'])
    ops[0xDD] = (0, ['ExecXY(false);'])
    ops[0xFD] = (0, ['ExecXY(true);'])
    ops[0xD3] = (11, ['rPC += 1;'])                 # OUT (n),A: the board has no I/O ports
    ops[0xDB] = (11, ['rPC += 1;', 'rA := 255;'])   # IN A,(n)
    ops[0xD9] = (4, ['t := rB * 256 + rC;', 'rB := BC2 div 256;', 'rC := BC2 mod 256;', 'BC2 := t;',
                     't := rD * 256 + rE;', 'rD := DE2 div 256;', 'rE := DE2 mod 256;', 'DE2 := t;',
                     't := rH * 256 + rL;', 'rH := HL2 div 256;', 'rL := HL2 mod 256;', 'HL2 := t;'])
    ops[0xE3] = (19, [rd('n', 'rSP'), 'ea := (rSP + 1) mod 65536;', rd('t', 'ea'),
                      wr('rSP', 'rL'), wr('ea', 'rH'), 'rH := t;', 'rL := n;'])
    ops[0xE9] = (4, ['rPC := rH * 256 + rL;'])
    ops[0xEB] = (4, ['t := rD;', 'rD := rH;', 'rH := t;', 't := rE;', 'rE := rL;', 'rL := t;'])
    ops[0xF3] = (4, ['IFF1 := false;', 'IFF2 := false;'])
    ops[0xF9] = (6, ['rSP := rH * 256 + rL;'])
    ops[0xFB] = (4, ['IFF1 := true;', 'IFF2 := true;', 'EiDelay := true;', 'IntPending := true;'])
    assert len(ops) == 256, len(ops)
    return ops


# ---------------------------------------------------------------- ED opcodes
def step(var_hi, var_lo, delta):
    if delta > 0:
        return [f'if {var_lo} < 255 then {var_lo} += 1 else begin {var_lo} := 0; {var_hi} := ({var_hi} + 1) mod 256; end;']
    return [f'if {var_lo} > 0 then {var_lo} -= 1 else begin {var_lo} := 255; {var_hi} := ({var_hi} + 255) mod 256; end;']


def ed_ops():
    ops = {}
    pairs = [('rB', 'rC'), ('rD', 'rE'), ('rH', 'rL'), (None, None)]
    for i, (hi, lo) in enumerate(pairs):
        src = 'rSP' if hi is None else f'{hi} * 256 + {lo}'
        # SBC HL,rr
        ops[0x42 + 16 * i] = (15, [
            f'w := {src};', 'hl := rH * 256 + rL;', 'c := rF mod 2;', 't := hl - w - c;',
            'rF := 2;',
            'if t < 0 then begin t += 65536; rF += 1; end;',
            'if (hl mod 4096) - (w mod 4096) - c < 0 then rF += 16;',
            'if ((hl < 32768) <> (w < 32768)) and ((hl < 32768) <> (t < 32768)) then rF += 4;',
            'rH := t div 256;', 'rL := t mod 256;',
            'rF += XYT[rH + 1];', 'if rH >= 128 then rF += 128;',
            'if t = 0 then rF += 64;'])
        # ADC HL,rr
        ops[0x4A + 16 * i] = (15, [
            f'w := {src};', 'hl := rH * 256 + rL;', 'c := rF mod 2;', 't := hl + w + c;',
            'rF := 0;',
            'if t > 65535 then begin t -= 65536; rF += 1; end;',
            'if (hl mod 4096) + (w mod 4096) + c > 4095 then rF += 16;',
            'if ((hl < 32768) = (w < 32768)) and ((hl < 32768) <> (t < 32768)) then rF += 4;',
            'rH := t div 256;', 'rL := t mod 256;',
            'rF += XYT[rH + 1];', 'if rH >= 128 then rF += 128;',
            'if t = 0 then rF += 64;'])
        if hi is None:
            ops[0x43 + 16 * i] = (20, fetch16('ea') + [wr('ea', 'rSP mod 256'), 'ea := (ea + 1) mod 65536;', wr('ea', 'rSP div 256')])
            ops[0x4B + 16 * i] = (20, fetch16('ea') + [rd('n', 'ea'), 'ea := (ea + 1) mod 65536;', rd('t', 'ea'), 'rSP := t * 256 + n;'])
        else:
            ops[0x43 + 16 * i] = (20, fetch16('ea') + [wr('ea', lo), 'ea := (ea + 1) mod 65536;', wr('ea', hi)])
            ops[0x4B + 16 * i] = (20, fetch16('ea') + [rd(lo, 'ea'), 'ea := (ea + 1) mod 65536;', rd(hi, 'ea')])
    for k, r in enumerate(R8):
        if r == '(HL)':
            ops[0x70] = (12, ['rF := (rF mod 2) + SZP[256];'])     # IN F,(C): reads 255
            ops[0x71] = (12, [])
        else:
            ops[0x40 + 8 * k] = (12, [f'{VAR[r]} := 255;', 'rF := (rF mod 2) + SZP[256];'])
            ops[0x41 + 8 * k] = (12, [])                         # OUT (C),r
    neg = ['v := rA;', 'rA := 0;'] + alu(2, 'v')
    for op in [0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C]:
        ops[op] = (8, neg)
    for op in [0x45, 0x55, 0x65, 0x75, 0x4D, 0x5D, 0x6D, 0x7D]:   # RETN / RETI
        ops[op] = (14, pop_pc() + ['IFF1 := IFF2;', 'if IFF1 then IntPending := true;'])
    for op in [0x46, 0x4E, 0x66, 0x6E]:
        ops[op] = (8, ['IntMode := 0;'])
    for op in [0x56, 0x76]:
        ops[op] = (8, ['IntMode := 1;'])
    for op in [0x5E, 0x7E]:
        ops[op] = (8, ['IntMode := 2;'])
    ops[0x47] = (9, ['rI := rA;'])
    # R counts instructions; here it is derived from the cycle counter (rR is the offset set by LD R,A)
    ops[0x4F] = (9, ['rR := (rA mod 128 - (Cyc div 4) mod 128 + 128) mod 128;', 'rR7 := rA - rA mod 128;'])
    ops[0x57] = (9, ['rA := rI;', 'rF := (rF mod 2) + SZ[rA + 1];', 'if IFF2 then rF += 4;'])
    ops[0x5F] = (9, ['rA := (Cyc div 4 + rR) mod 128 + rR7;', 'rF := (rF mod 2) + SZ[rA + 1];', 'if IFF2 then rF += 4;'])
    ops[0x67] = (18, ['ea := rH * 256 + rL;', rd('n', 'ea'), 'v := n div 16 + (rA mod 16) * 16;',
                      'rA := (rA div 16) * 16 + n mod 16;', wr('ea', 'v'), 'rF := (rF mod 2) + SZP[rA + 1];'])
    ops[0x6F] = (18, ['ea := rH * 256 + rL;', rd('n', 'ea'), 'v := (n mod 16) * 16 + rA mod 16;',
                      'rA := (rA div 16) * 16 + n div 16;', wr('ea', 'v'), 'rF := (rF mod 2) + SZP[rA + 1];'])

    def ld_flags():
        return ['n := rA + v;',
                'rF := AndT[rF * 256 + 194];',     # keep S, Z and C (0xC1)
                'if (n mod 4) >= 2 then rF += 32;',
                'if (n mod 16) >= 8 then rF += 8;']

    def ld_one(delta):
        return ['ea := rH * 256 + rL;', rd('v', 'ea'), 'ea := rD * 256 + rE;', wr('ea', 'v')] \
            + step('rH', 'rL', delta) + step('rD', 'rE', delta) + step('rB', 'rC', -1)

    def ld_block(delta):
        return ld_one(delta) + ld_flags() + ['if (rB <> 0) or (rC <> 0) then rF += 4;']

    def ld_repeat(delta):
        # LDIR / LDDR: the whole block in one go, until it is done or the time slice ends
        return (['repeat'] + indent(ld_one(delta), 4) + ['    Cyc += 21;', 'until ((rB = 0) and (rC = 0)) or (Cyc >= RunTarget);']
                + ld_flags()
                + ['if (rB <> 0) or (rC <> 0) then begin', '    rF += 4;', '    rPC -= 2;', 'end else', '    Cyc -= 5;'])

    def cp_block(delta, repeat):
        code = ['ea := rH * 256 + rL;', rd('v', 'ea'), 't := rA - v;', 'if t < 0 then t += 256;']
        code += step('rH', 'rL', delta) + step('rB', 'rC', -1)
        code += ['rF := (rF mod 2) + SZ0[t + 1] + 2;',
                 'if (rA mod 16) < (v mod 16) then begin rF += 16; t := (t + 255) mod 256; end;',
                 'if (t mod 4) >= 2 then rF += 32;',
                 'if (t mod 16) >= 8 then rF += 8;',
                 'if (rB <> 0) or (rC <> 0) then begin',
                 '    rF += 4;']
        if repeat:
            code += ['    if (rF mod 128) < 64 then begin', '        rPC -= 2;', '        Cyc += 5;', '    end;']
        code += ['end;']
        return code

    def io_block(delta, repeat, is_in):
        # the Galaga hardware has no I/O ports: IN reads 255, OUT is ignored
        code = ['ea := rH * 256 + rL;']
        if is_in:
            code += [wr('ea', '255')]
        code += ['if rB = 0 then rB := 255 else rB -= 1;'] + step('rH', 'rL', delta)
        code += ['rF := SZ[rB + 1] + 2;']
        if repeat:
            code += ['if rB <> 0 then begin', '    rPC -= 2;', '    Cyc += 5;', 'end;']
        return code

    ops[0xA0] = (16, ld_block(1))
    ops[0xA8] = (16, ld_block(-1))
    ops[0xB0] = (0, ld_repeat(1))
    ops[0xB8] = (0, ld_repeat(-1))
    ops[0xA1] = (16, cp_block(1, False))
    ops[0xA9] = (16, cp_block(-1, False))
    ops[0xB1] = (16, cp_block(1, True))
    ops[0xB9] = (16, cp_block(-1, True))
    ops[0xA2] = (16, io_block(1, False, True))
    ops[0xAA] = (16, io_block(-1, False, True))
    ops[0xB2] = (16, io_block(1, True, True))
    ops[0xBA] = (16, io_block(-1, True, True))
    ops[0xA3] = (16, io_block(1, False, False))
    ops[0xAB] = (16, io_block(-1, False, False))
    ops[0xB3] = (16, io_block(1, True, False))
    ops[0xBB] = (16, io_block(-1, True, False))
    return ops


# ---------------------------------------------------------------- DD / FD opcodes (xy = IX or IY)
XYGET = {'H': 'xy div 256', 'L': 'xy mod 256'}
XYSET = {'H': 'xy := {v} * 256 + xy mod 256;', 'L': 'xy := (xy div 256) * 256 + {v};'}


def xy_ops():
    ops = {}
    ops[0x09] = (15, add16('xy', ['xy := t;'], 'rB * 256 + rC'))
    ops[0x19] = (15, add16('xy', ['xy := t;'], 'rD * 256 + rE'))
    ops[0x29] = (15, add16('xy', ['xy := t;'], 'xy'))
    ops[0x39] = (15, add16('xy', ['xy := t;'], 'rSP'))
    ops[0x21] = (14, fetch16('xy'))
    ops[0x22] = (20, fetch16('ea') + [wr('ea', 'xy mod 256'), 'ea := (ea + 1) mod 65536;', wr('ea', 'xy div 256')])
    ops[0x2A] = (20, fetch16('ea') + [rd('n', 'ea'), 'ea := (ea + 1) mod 65536;', rd('t', 'ea'), 'xy := t * 256 + n;'])
    ops[0x23] = (10, ['xy := (xy + 1) mod 65536;'])
    ops[0x2B] = (10, ['xy := (xy + 65535) mod 65536;'])
    for k, r in [(4, 'H'), (5, 'L')]:
        ops[0x04 + 8 * k] = (8, [f'v := {XYGET[r]};'] + inc8('v') + [XYSET[r].format(v='v')])
        ops[0x05 + 8 * k] = (8, [f'v := {XYGET[r]};'] + dec8('v') + [XYSET[r].format(v='v')])
        ops[0x06 + 8 * k] = (11, fetch('v') + [XYSET[r].format(v='v')])
    ea_d = fetch_d() + ['ea := (xy + d + 65536) mod 65536;']
    ops[0x34] = (23, ea_d + [rd('v', 'ea')] + inc8('v') + [wr('ea', 'v')])
    ops[0x35] = (23, ea_d + [rd('v', 'ea')] + dec8('v') + [wr('ea', 'v')])
    ops[0x36] = (19, ea_d + fetch('n') + [wr('ea', 'n')])
    for op in range(0x40, 0x80):
        if op == 0x76:
            continue
        dst, src = R8[(op >> 3) & 7], R8[op & 7]
        if src == '(HL)':
            ops[op] = (19, ea_d + [rd(VAR[dst], 'ea')])
        elif dst == '(HL)':
            ops[op] = (19, ea_d + [wr('ea', VAR[src])])
        elif dst in 'HL' or src in 'HL':
            get = XYGET[src] if src in 'HL' else VAR[src]
            if dst in 'HL':
                code = [f'v := {get};', XYSET[dst].format(v='v')]
            else:
                code = [f'{VAR[dst]} := {get};']
            ops[op] = (8, code)
    for op in range(0x80, 0xC0):
        k, src = (op >> 3) & 7, R8[op & 7]
        if src == '(HL)':
            ops[op] = (19, ea_d + [rd('v', 'ea')] + alu(k, 'v'))
        elif src in 'HL':
            ops[op] = (8, [f'v := {XYGET[src]};'] + alu(k, 'v'))
    ops[0xCB] = (0, ea_d + ['ExecXYCB(ea);'])
    ops[0xE1] = (14, pop('t', 'n') + ['xy := t * 256 + n;'])
    ops[0xE5] = (15, push('xy div 256', 'xy mod 256'))
    ops[0xE3] = (23, [rd('n', 'rSP'), 'ea := (rSP + 1) mod 65536;', rd('t', 'ea'),
                      wr('rSP', 'xy mod 256'), wr('ea', 'xy div 256'), 'xy := t * 256 + n;'])
    ops[0xE9] = (8, ['rPC := xy;'])
    ops[0xF9] = (10, ['rSP := xy;'])
    return ops


# ---------------------------------------------------------------- emit
def case_body(cyc, code, ind):
    body = []
    if cyc:
        body.append(f'Cyc += {cyc};')
    body += code
    if not body:
        return [' ' * ind + 'begin', ' ' * ind + 'end;']
    if len(body) == 1:
        return [' ' * ind + body[0]]
    return [' ' * ind + 'begin'] + indent(body, ind + 4) + [' ' * ind + 'end;']


def emit_case(ops, ind):
    out = []
    for op in sorted(ops):
        cyc, code = ops[op]
        out.append(' ' * ind + f'{op}:')
        out += case_body(cyc, code, ind + 4)
    return out


def locals_(*names):
    return ['    var'] + [f'        {n}: Integer;' for n in names]


def gen():
    L = ['    // Generated by tools/gen_z80.py - do not edit by hand.', '']
    # ---------------- Execute
    L += ['    /// <summary>Executes the current CPU until Cyc reaches RunTarget.</summary>',
          '    local procedure Execute()']
    L += locals_('op', 'n', 't', 'v', 'c', 'd', 'w', 'ea', 'hl')
    L += ['    begin',
          '        while Cyc < RunTarget do begin',
          '            if IntPending then',
          '                CheckInterrupt();',
          '            if (rPC < 16384) and (not RamCode) then',
          '                op := Rom[RomBase + rPC + 1]',
          '            else',
          '                op := FetchSlow();',
          '            rPC += 1;',
          '            case op of']
    L += emit_case(main_ops(), 16)
    L += ['            end;',
          '        end;',
          '    end;',
          '']
    # ---------------- interrupts
    L += ['    /// <summary>Takes a pending NMI or IRQ (IM 1, or IM 2 with 255 on the data bus).</summary>',
          '    local procedure CheckInterrupt()']
    L += locals_('ea')
    L += ['    begin',
          '        if NmiPending[CpuNo] then begin',
          '            NmiPending[CpuNo] := false;',
          '            if Halted then begin',
          '                Halted := false;',
          '                rPC += 1;',
          '            end;',
          '            IFF1 := false;']
    L += indent(push_pc(), 12)
    L += ['            rPC := 102;',
          '            Cyc += 11;',
          '        end else',
          '            if EiDelay then',
          '                // the instruction after EI runs before an interrupt is taken',
          '                EiDelay := false',
          '            else',
          '                if IFF1 and IrqLine[CpuNo] then begin',
          '                    if Halted then begin',
          '                        Halted := false;',
          '                        rPC += 1;',
          '                    end;',
          '                    IFF1 := false;',
          '                    IFF2 := false;']
    L += indent(push_pc(), 20)
    L += ['                    if IntMode = 2 then begin',
          '                        ea := rI * 256 + 255;',
          '                        rPC := ReadMem(ea) + 256 * ReadMem((ea + 1) mod 65536);',
          '                        Cyc += 19;',
          '                    end else begin',
          '                        rPC := 56;',
          '                        Cyc += 13;',
          '                    end;',
          '                end;',
          '        IntPending := NmiPending[CpuNo] or EiDelay or (IFF1 and IrqLine[CpuNo]);',
          '    end;',
          '']
    # ---------------- CB
    L += ['    local procedure ExecCB()']
    L += locals_('op', 'r', 'b', 'm', 'v', 'ea')
    L += ['    begin']
    L += indent(fetch('op'), 8)
    L += [
        '        r := op mod 8;',
        '        case r of',
        '            0: v := rB;',
        '            1: v := rC;',
        '            2: v := rD;',
        '            3: v := rE;',
        '            4: v := rH;',
        '            5: v := rL;',
        '            6: begin',
        '                ea := rH * 256 + rL;',
        '                ' + rd('v', 'ea'),
        '            end;',
        '            7: v := rA;',
        '        end;',
        '        b := (op div 8) mod 8;',
        '        case op div 64 of',
        '            0: v := RotOp(b, v);',
        '            1: begin',
        '                // BIT: Z (and P/V) when the bit is clear, S for a set bit 7, H set, C kept',
        '                if ((v div Pow2[b + 1]) mod 2) = 0 then',
        '                    rF := (rF mod 2) + 84 + XYT[v + 1]',
        '                else',
        '                    if b = 7 then rF := (rF mod 2) + 144 + XYT[v + 1] else rF := (rF mod 2) + 16 + XYT[v + 1];',
        '                if r = 6 then Cyc += 12 else Cyc += 8;',
        '                exit;',
        '            end;',
        '            2: begin',
        '                m := Pow2[b + 1];',
        '                if ((v div m) mod 2) = 1 then v -= m;',
        '            end;',
        '            3: begin',
        '                m := Pow2[b + 1];',
        '                if ((v div m) mod 2) = 0 then v += m;',
        '            end;',
        '        end;',
        '        case r of',
        '            0: rB := v;',
        '            1: rC := v;',
        '            2: rD := v;',
        '            3: rE := v;',
        '            4: rH := v;',
        '            5: rL := v;',
        '            6: begin',
        '                ' + wr('ea', 'v'),
        '                Cyc += 15;',
        '                exit;',
        '            end;',
        '            7: rA := v;',
        '        end;',
        '        Cyc += 8;',
        '    end;',
        '']
    # ---------------- DDCB / FDCB
    L += ['    local procedure ExecXYCB(ea: Integer)']
    L += locals_('op', 'r', 'b', 'm', 'v')
    L += ['    begin']
    L += indent(fetch('op'), 8)
    L += [
        '        ' + rd('v', 'ea'),
        '        r := op mod 8;',
        '        b := (op div 8) mod 8;',
        '        case op div 64 of',
        '            0: v := RotOp(b, v);',
        '            1: begin',
        '                if ((v div Pow2[b + 1]) mod 2) = 0 then',
        '                    rF := (rF mod 2) + 84 + XYT[v + 1]',
        '                else',
        '                    if b = 7 then rF := (rF mod 2) + 144 + XYT[v + 1] else rF := (rF mod 2) + 16 + XYT[v + 1];',
        '                Cyc += 20;',
        '                exit;',
        '            end;',
        '            2: begin',
        '                m := Pow2[b + 1];',
        '                if ((v div m) mod 2) = 1 then v -= m;',
        '            end;',
        '            3: begin',
        '                m := Pow2[b + 1];',
        '                if ((v div m) mod 2) = 0 then v += m;',
        '            end;',
        '        end;',
        '        ' + wr('ea', 'v'),
        '        // undocumented: the result is also copied to a register',
        '        case r of',
        '            0: rB := v;',
        '            1: rC := v;',
        '            2: rD := v;',
        '            3: rE := v;',
        '            4: rH := v;',
        '            5: rL := v;',
        '            7: rA := v;',
        '        end;',
        '        Cyc += 23;',
        '    end;',
        '']
    # ---------------- ED
    L += ['    local procedure ExecED()']
    L += locals_('op', 'n', 't', 'v', 'c', 'w', 'ea', 'hl')
    L += ['    begin']
    L += indent(fetch('op'), 8)
    L += ['        case op of']
    L += emit_case(ed_ops(), 12)
    L += ['            else',
          '                Cyc += 8;',
          '        end;',
          '    end;',
          '']
    # ---------------- DD / FD
    L += ['    /// <summary>',
          '    /// Executes a DD (IX) or FD (IY) prefixed opcode. When the opcode does not use HL, H or L the prefix has no',
          '    /// effect: then the opcode runs as an unprefixed one in the next step of Execute.',
          '    /// </summary>',
          '    local procedure ExecXY(IsIY: Boolean)']
    L += locals_('op', 'n', 't', 'v', 'c', 'd', 'w', 'ea', 'hl', 'xy')
    L += ['    begin',
          '        if IsIY then xy := rIY else xy := rIX;']
    L += indent(fetch('op'), 8)
    L += ['        case op of']
    L += emit_case(xy_ops(), 12)
    L += ['            else begin',
          '                Cyc += 4;',
          '                rPC -= 1;',
          '                exit;',
          '            end;',
          '        end;',
          '        if IsIY then rIY := xy else rIX := xy;',
          '    end;',
          '']
    # ---------------- helpers
    L += [
        '    /// <summary>The CB rotate and shift operations: RLC RRC RL RR SLA SRA SLL SRL.</summary>',
        '    local procedure RotOp(Kind: Integer; V: Integer): Integer',
        '    var',
        '        Res: Integer;',
        '        Cy: Integer;',
        '    begin',
        '        case Kind of',
        '            0: begin Cy := V div 128; Res := (V * 2) mod 256 + Cy; end;',
        '            1: begin Cy := V mod 2; Res := V div 2 + Cy * 128; end;',
        '            2: begin Cy := V div 128; Res := (V * 2) mod 256 + rF mod 2; end;',
        '            3: begin Cy := V mod 2; Res := V div 2 + (rF mod 2) * 128; end;',
        '            4: begin Cy := V div 128; Res := (V * 2) mod 256; end;',
        '            5: begin Cy := V mod 2; Res := V div 2 + (V div 128) * 128; end;',
        '            6: begin Cy := V div 128; Res := (V * 2) mod 256 + 1; end;',
        '            7: begin Cy := V mod 2; Res := V div 2; end;',
        '        end;',
        '        rF := SZP[Res + 1] + Cy;',
        '        exit(Res);',
        '    end;',
        '',
        '    /// <summary>',
        '    /// Fetches an opcode when the program counter is outside the ROM (never in Galaga): the instruction bytes are',
        '    /// copied to a scratch area after the ROMs, and RomBase points there until the next opcode fetch.',
        '    /// </summary>',
        '    local procedure FetchSlow(): Integer',
        '    var',
        '        i: Integer;',
        '    begin',
        '        if RamCode then begin',
        '            RamCode := false;',
        '            RomBase := (CpuNo - 1) * 16384;',
        '            if rPC < 16384 then',
        '                exit(Rom[RomBase + rPC + 1]);',
        '        end;',
        '        for i := 0 to 3 do',
        '            Rom[49153 + i] := ReadMem((rPC + i) mod 65536);',
        '        RomBase := 49152 - rPC;',
        '        RamCode := true;',
        '        exit(Rom[49153]);',
        '    end;',
        '',
        '    /// <summary>',
        '    /// A short backward jump reached the same target twice in a row. When nothing was written and the registers',
        '    /// are the same as at the previous visit, the loop can only be waiting for an interrupt or for another CPU',
        '    /// (which runs after this one in the time slice): skip to the end of the slice.',
        '    /// </summary>',
        '    local procedure IdleCheck()',
        '    begin',
        '        if (WrCnt = IdleW) and (rA = IdleA) and (rF = IdleF) and (rB = IdleB) and (rC = IdleC) and (rD = IdleD) and',
        '           (rE = IdleE) and (rH = IdleH) and (rL = IdleL) and (rSP = IdleSP) and (rIX = IdleIX) and (rIY = IdleIY) and',
        '           (AF2 = IdleAF2) and (BC2 = IdleBC2) and (DE2 = IdleDE2) and (HL2 = IdleHL2)',
        '        then begin',
        '            IdleCycles[CpuNo] += RunTarget - Cyc;',
        '            Cyc := RunTarget;',
        '            exit;',
        '        end;',
        '        IdleW := WrCnt;',
        '        IdleA := rA;',
        '        IdleF := rF;',
        '        IdleB := rB;',
        '        IdleC := rC;',
        '        IdleD := rD;',
        '        IdleE := rE;',
        '        IdleH := rH;',
        '        IdleL := rL;',
        '        IdleSP := rSP;',
        '        IdleIX := rIX;',
        '        IdleIY := rIY;',
        '        IdleAF2 := AF2;',
        '        IdleBC2 := BC2;',
        '        IdleDE2 := DE2;',
        '        IdleHL2 := HL2;',
        '    end;',
    ]
    return L


def main():
    with open(TARGET, encoding='utf-8') as f:
        src = f.read()
    start = '    // <generated z80>\n'
    end = '    // </generated z80>\n'
    i, j = src.index(start), src.index(end)
    out = src[:i + len(start)] + '\n'.join(gen()) + '\n' + src[j:]
    with open(TARGET, 'w', encoding='utf-8', newline='\n') as f:
        f.write(out)
    print('generated', TARGET)


if __name__ == '__main__':
    main()
