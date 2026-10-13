// Minimal Z80 disassembler for debugging (returns [text, length]).
'use strict';
const R = ['B', 'C', 'D', 'E', 'H', 'L', '(HL)', 'A'];
const RP = ['BC', 'DE', 'HL', 'SP'];
const RP2 = ['BC', 'DE', 'HL', 'AF'];
const CC = ['NZ', 'Z', 'NC', 'C', 'PO', 'PE', 'P', 'M'];
const ALU = ['ADD A,', 'ADC A,', 'SUB ', 'SBC A,', 'AND ', 'XOR ', 'OR ', 'CP '];
const ROT = ['RLC', 'RRC', 'RL', 'RR', 'SLA', 'SRA', 'SLL', 'SRL'];
const h2 = v => v.toString(16).toUpperCase().padStart(2, '0') + 'h';
const h4 = v => v.toString(16).toUpperCase().padStart(4, '0') + 'h';

function dis(rd, pc) {
    let p = pc;
    const b = () => rd(p++ & 0xffff);
    const w = () => { const l = b(); return l | (b() << 8); };
    const d = () => { const v = b(); return v >= 128 ? v - 256 : v; };
    let op = b();
    let ix = null;
    if (op === 0xdd || op === 0xfd) { ix = op === 0xdd ? 'IX' : 'IY'; op = b(); }
    const r = (i, disp) => {
        if (!ix) return R[i];
        if (i === 6) return `(${ix}${disp >= 0 ? '+' : ''}${disp})`;
        return R[i];
    };
    const hl = () => ix || 'HL';
    let t;
    if (op === 0xcb) {
        let disp = 0;
        if (ix) disp = d();
        const o = b();
        const x = o >> 6, y = (o >> 3) & 7, z = o & 7;
        const reg = ix ? `(${ix}${disp >= 0 ? '+' : ''}${disp})` : R[z];
        t = x === 0 ? `${ROT[y]} ${reg}` : `${['', 'BIT', 'RES', 'SET'][x]} ${y},${reg}`;
    } else if (op === 0xed) {
        const o = b();
        const x = o >> 6, y = (o >> 3) & 7, z = o & 7;
        if (x === 1) {
            t = [() => `IN ${R[y]},(C)`, () => `OUT (C),${R[y]}`, () => (y & 1 ? 'ADC' : 'SBC') + ` HL,${RP[y >> 1]}`,
                () => (y & 1 ? `LD ${RP[y >> 1]},(${h4(w())})` : `LD (${h4(w())}),${RP[y >> 1]}`), () => 'NEG', () => (y === 1 ? 'RETI' : 'RETN'),
                () => `IM ${[0, 0, 1, 2, 0, 0, 1, 2][y]}`, () => ['LD I,A', 'LD R,A', 'LD A,I', 'LD A,R', 'RRD', 'RLD', 'NOP', 'NOP'][y]][z]();
        } else if (x === 2 && y >= 4 && z <= 3) {
            t = [['LDI', 'CPI', 'INI', 'OUTI'], ['LDD', 'CPD', 'IND', 'OUTD'], ['LDIR', 'CPIR', 'INIR', 'OTIR'], ['LDDR', 'CPDR', 'INDR', 'OTDR']][y - 4][z];
        } else t = 'ED ' + h2(o);
    } else {
        const x = op >> 6, y = (op >> 3) & 7, z = op & 7, q = y & 1, pp = y >> 1;
        const rpx = i => (i === 2 ? hl() : RP[i]);
        if (x === 0) {
            if (z === 0) {
                if (y === 0) t = 'NOP';
                else if (y === 1) t = "EX AF,AF'";
                else { const dd = d(); const tgt = h4((p + dd) & 0xffff); t = y === 2 ? 'DJNZ ' + tgt : y === 3 ? 'JR ' + tgt : `JR ${CC[y - 4]},${tgt}`; }
            } else if (z === 1) t = q ? `ADD ${hl()},${rpx(pp)}` : `LD ${rpx(pp)},${h4(w())}`;
            else if (z === 2) t = [() => `LD (BC),A`, () => `LD A,(BC)`, () => `LD (DE),A`, () => `LD A,(DE)`, () => `LD (${h4(w())}),${hl()}`, () => `LD ${hl()},(${h4(w())})`, () => `LD (${h4(w())}),A`, () => `LD A,(${h4(w())})`][y]();
            else if (z === 3) t = (q ? 'DEC ' : 'INC ') + rpx(pp);
            else if (z === 4) t = 'INC ' + r(y, y === 6 && ix ? d() : 0);
            else if (z === 5) t = 'DEC ' + r(y, y === 6 && ix ? d() : 0);
            else if (z === 6) { const dd = y === 6 && ix ? d() : 0; t = `LD ${r(y, dd)},${h2(b())}`; }
            else if (z === 7) t = ['RLCA', 'RRCA', 'RLA', 'RRA', 'DAA', 'CPL', 'SCF', 'CCF'][y];
        } else if (x === 1) {
            if (op === 0x76) t = 'HALT';
            else { const dd = (y === 6 || z === 6) && ix ? d() : 0; t = `LD ${r(y, dd)},${r(z, dd)}`; }
        } else if (x === 2) {
            const dd = z === 6 && ix ? d() : 0;
            t = ALU[y] + r(z, dd);
        } else {
            if (z === 0) t = `RET ${CC[y]}`;
            else if (z === 1) t = q ? ['RET', 'EXX', `JP (${hl()})`, `LD SP,${hl()}`][pp] : `POP ${pp === 2 ? hl() : RP2[pp]}`;
            else if (z === 2) t = `JP ${CC[y]},${h4(w())}`;
            else if (z === 3) t = [() => `JP ${h4(w())}`, () => 'CB', () => `OUT (${h2(b())}),A`, () => `IN A,(${h2(b())})`, () => `EX (SP),${hl()}`, () => 'EX DE,HL', () => 'DI', () => 'EI'][y]();
            else if (z === 4) t = `CALL ${CC[y]},${h4(w())}`;
            else if (z === 5) t = q ? (pp === 0 ? `CALL ${h4(w())}` : '??') : `PUSH ${pp === 2 ? hl() : RP2[pp]}`;
            else if (z === 6) t = ALU[y] + h2(b());
            else t = `RST ${h2(y * 8)}`;
        }
    }
    return [t, p - pc];
}

module.exports = { dis, h2, h4 };
