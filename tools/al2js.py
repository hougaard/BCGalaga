#!/usr/bin/env python3
"""Translates the AL subset used by the "Galaga Machine" codeunit to a JavaScript module, so the emulator can be
tested with node against the real ROMs (tools/test/run.js).

    python tools/al2js.py src/GalagaMachine.Codeunit.al tools/test/galaga_machine.js [--fast]

Supported: one codeunit with global variables (Integer, Boolean, Text, TextBuilder, arrays of them) and procedures
with value parameters; begin/end, if, case, while, repeat, for, exit, assignments (:= += -= *=), procedure calls,
CopyStr, Evaluate, TextBuilder.Append/ToText.

AL semantics are kept: arrays are 1-based and bounds checked, Integer overflow and division by zero are errors,
and both operands of and/or are evaluated. --fast drops the checks.
"""
import re
import sys

KEYWORDS = {'and', 'or', 'xor', 'not', 'div', 'mod', 'begin', 'end', 'if', 'then', 'else', 'case', 'of', 'while',
            'do', 'repeat', 'until', 'for', 'to', 'downto', 'exit', 'var', 'procedure', 'local', 'true', 'false',
            'array', 'codeunit'}

TOKEN_RE = re.compile(r"""
    (?P<ws>\s+) |
    (?P<comment>//[^\n]*|/\*.*?\*/) |
    (?P<num>\d+) |
    (?P<str>'(?:[^']|'')*') |
    (?P<qid>"[^"]*") |
    (?P<id>[A-Za-z_][A-Za-z0-9_]*) |
    (?P<op>:=|\+=|-=|\*=|<>|<=|>=|\.\.|[()\[\],;:.=<>+\-*/{}])
""", re.S | re.X)


class Tok:
    def __init__(self, kind, val, line):
        self.kind, self.val, self.line = kind, val, line

    def __repr__(self):
        return f'{self.kind}:{self.val}@{self.line}'


def tokenize(src):
    toks, pos, line = [], 0, 1
    while pos < len(src):
        m = TOKEN_RE.match(src, pos)
        if not m:
            raise SyntaxError(f'line {line}: unexpected {src[pos:pos + 20]!r}')
        kind, val = m.lastgroup, m.group()
        if kind == 'id' and val.lower() in KEYWORDS:
            kind, val = 'kw', val.lower()
        if kind not in ('ws', 'comment'):
            toks.append(Tok(kind, val, line))
        line += val.count('\n')
        pos = m.end()
    toks.append(Tok('eof', '', line))
    return toks


class Type:
    def __init__(self, base, dims=None, elem=None):
        self.base, self.dims, self.elem = base, dims, elem   # base: integer boolean text textbuilder array

    def __repr__(self):
        return self.base if self.base != 'array' else f'array{self.dims} of {self.elem}'


INT, BOOL, TEXT = Type('integer'), Type('boolean'), Type('text')


class Translator:
    def __init__(self, toks, fast, count=False):
        self.t, self.i, self.fast, self.count = toks, 0, fast, count
        self.globals = {}       # lower name -> Type
        self.procs = {}         # lower name -> (Name, params [(lname, Type)], ret Type or None, local)
        self.locals = None
        self.tmp = 0
        self.out = []

    # ------------------------------------------------------------ token helpers
    def peek(self, k=0):
        return self.t[self.i + k]

    def take(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def is_(self, val, k=0):
        tok = self.peek(k)
        return tok.kind in ('kw', 'op') and tok.val == val

    def accept(self, val):
        if self.is_(val):
            self.i += 1
            return True
        return False

    def expect(self, val):
        tok = self.take()
        if tok.kind not in ('kw', 'op') or tok.val != val:
            self.err(f'expected {val!r}, found {tok.val!r}', tok)
        return tok

    def ident(self):
        tok = self.take()
        if tok.kind not in ('id', 'qid'):
            self.err(f'expected identifier, found {tok.val!r}', tok)
        return tok.val

    def err(self, msg, tok=None):
        tok = tok or self.peek()
        raise SyntaxError(f'line {tok.line}: {msg}')

    # ------------------------------------------------------------ declarations
    def parse_type(self):
        tok = self.take()
        if tok.kind == 'kw' and tok.val == 'array':
            self.expect('[')
            dims = [int(self.take().val)]
            while self.accept(','):
                dims.append(int(self.take().val))
            self.expect(']')
            self.expect('of')
            return Type('array', dims, self.parse_type())
        name = tok.val.lower()
        if name == 'text':
            if self.accept('['):
                self.take()
                self.expect(']')
            return TEXT
        if name in ('integer', 'boolean', 'textbuilder'):
            return Type(name)
        self.err(f'unsupported type {tok.val}', tok)

    def parse_vars(self):
        decls = []
        while self.peek().kind in ('id', 'qid'):
            names = [self.ident()]
            while self.accept(','):
                names.append(self.ident())
            self.expect(':')
            typ = self.parse_type()
            self.expect(';')
            decls += [(n, typ) for n in names]
        return decls

    def parse(self):
        self.expect('codeunit')
        self.take()
        self.ident()
        self.expect('{')
        if self.accept('var'):
            for name, typ in self.parse_vars():
                self.globals[name.lower()] = typ
        # first pass: signatures
        start = self.i
        bodies = []
        while not self.is_('}'):
            local = self.accept('local')
            self.expect('procedure')
            name = self.ident()
            params = []
            self.expect('(')
            while not self.is_(')'):
                if self.accept('var'):
                    self.err('var parameters are not supported')
                pname = self.ident()
                self.expect(':')
                params.append((pname.lower(), self.parse_type()))
                self.accept(';')
            self.expect(')')
            ret = None
            if self.accept(':'):
                ret = self.parse_type()
            self.accept(';')
            self.procs[name.lower()] = (name, params, ret, local)
            body_start = self.i
            self.skip_body()
            bodies.append((name.lower(), body_start))
        # second pass: bodies
        for lname, pos in bodies:
            self.i = pos
            self.emit_proc(lname)
        return self.finish()

    def skip_body(self):
        if self.accept('var'):
            self.parse_vars()
        depth = 0
        while True:
            tok = self.take()
            if tok.kind == 'kw' and tok.val in ('begin', 'case', 'repeat'):
                depth += 1
            elif tok.kind == 'kw' and tok.val in ('end', 'until'):
                depth -= 1
                if depth == 0:
                    if tok.val == 'until':
                        self.err('unexpected until')
                    break
        self.accept(';')

    # ------------------------------------------------------------ code
    def jsname(self, lname):
        return '$' + lname

    def default(self, typ):
        if typ.base == 'array':
            n = 1
            for d in typ.dims:
                n *= d
            if typ.elem.base == 'integer':
                return f'new Int32Array({n + 1})'
            if typ.elem.base == 'boolean':
                return f'new Array({n + 1}).fill(false)'
            if typ.elem.base == 'text':
                return f"new Array({n + 1}).fill('')"
            self.err(f'unsupported array element {typ.elem}')
        return {'integer': '0', 'boolean': 'false', 'text': "''", 'textbuilder': '[]'}[typ.base]

    def lookup(self, lname):
        if self.locals is not None and lname in self.locals:
            return self.locals[lname]
        if lname in self.globals:
            return self.globals[lname]
        return None

    def emit_proc(self, lname):
        name, params, ret, local = self.procs[lname]
        self.locals = {p: t for p, t in params}
        decls = []
        if self.accept('var'):
            decls = self.parse_vars()
            for n, t in decls:
                self.locals[n.lower()] = t
        self.ret = ret
        if ret is not None:
            self.locals['$result'] = ret
        lines = [f'function {self.jsname(lname)}({", ".join(self.jsname(p) for p, _ in params)}) {{']
        self.cur = repr(name)
        if self.count:
            lines.append(f'  CALLS[{self.cur}] = (CALLS[{self.cur}] || 0) + 1; ST[{self.cur}] = ST[{self.cur}] || 0;')
        for n, t in decls:
            lines.append(f'  let {self.jsname(n.lower())} = {self.default(t)};')
        body = self.block()
        self.accept(';')
        lines += ['  ' + l for l in body]
        if ret is not None:
            lines.append(f'  return {self.default(ret)};')
        lines.append('}')
        self.out += lines
        self.locals = None

    def block(self):
        self.expect('begin')
        stmts = self.stmt_list(('end',))
        self.expect('end')
        return stmts

    def stmt_list(self, enders):
        out = []
        while True:
            if any(self.is_(e) for e in enders):
                return out
            if self.accept(';'):
                continue
            out += self.stmt()
            if not self.accept(';'):
                if any(self.is_(e) for e in enders):
                    return out
                self.err(f'expected ; found {self.peek().val!r}')

    def stmt(self):
        out = self.stmt_()
        if self.count and out:
            # AL calls StmtHit/CStmtHit once per statement: count them per procedure
            return [f'ST[{self.cur}]++;'] + out
        return out

    def stmt_(self):
        tok = self.peek()
        if self.is_('begin'):
            return ['{'] + ['  ' + l for l in self.block()] + ['}']
        if self.accept('if'):
            cond = self.bool_expr()
            self.expect('then')
            then = self.sub_stmt()
            out = [f'if ({cond}) {{'] + then
            if self.accept('else'):
                out += ['} else {'] + self.sub_stmt()
            return out + ['}']
        if self.accept('while'):
            cond = self.bool_expr()
            self.expect('do')
            if self.count:
                cond = f'(ST[{self.cur}]++, {cond})'
            return [f'while ({cond}) {{'] + self.sub_stmt() + ['}']
        if self.accept('repeat'):
            body = self.stmt_list(('until',))
            self.expect('until')
            cond = self.bool_expr()
            return ['do {'] + ['  ' + l for l in body] + [f'}} while (!({cond}));']
        if self.accept('for'):
            var = self.ident().lower()
            if self.lookup(var) is not INT and (self.lookup(var) is None or self.lookup(var).base != 'integer'):
                self.err('for variable must be an Integer')
            self.expect(':=')
            a, _ = self.expr()
            down = self.accept('downto')
            if not down:
                self.expect('to')
            b, _ = self.expr()
            self.expect('do')
            self.tmp += 1
            end = f'$end{self.tmp}'
            v = self.jsname(var)
            step = f'{v}--' if down else f'{v}++'
            cmp = '>=' if down else '<='
            return [f'for (let {end} = ({b}), _f = ({v} = ({a})); {v} {cmp} {end}; {step}) {{'] + self.sub_stmt() + ['}']
        if self.accept('case'):
            sel, st = self.expr()
            self.expect('of')
            out = [f'switch ({sel}) {{']
            while not self.is_('end') and not self.is_('else'):
                labels = []
                while True:
                    lab, _ = self.expr()
                    if self.accept('..'):
                        hi, _ = self.expr()
                        labels += [str(x) for x in range(int(eval(lab)), int(eval(hi)) + 1)]
                    else:
                        labels.append(lab)
                    if not self.accept(','):
                        break
                self.expect(':')
                body = self.stmt()
                self.accept(';')
                out += [f'  case {lab}:' for lab in labels] + ['  {'] + ['    ' + l for l in body] + ['  }', '  break;']
            if self.accept('else'):
                body = self.stmt_list(('end',))
                out += ['  default: {'] + ['    ' + l for l in body] + ['  }']
            self.expect('end')
            return out + ['}']
        if self.accept('exit'):
            if self.accept('('):
                e, _ = self.expr()
                self.expect(')')
                return [f'return {e};']
            return ['return;']
        if tok.kind in ('id', 'qid'):
            return self.simple_stmt()
        self.err(f'unexpected {tok.val!r}')

    def sub_stmt(self):
        if self.is_(';') or self.is_('else') or self.is_('end'):
            return []
        return ['  ' + l for l in self.stmt()]

    def simple_stmt(self):
        name = self.ident()
        lname = name.lower()
        # builtins used as statements
        if lname == 'evaluate':
            self.expect('(')
            target, _ = self.lvalue(self.ident())
            self.expect(',')
            src, _ = self.expr()
            self.expect(')')
            return [f'{target} = parseInt({src}, 10);']
        if lname == 'error':
            self.expect('(')
            e, _ = self.expr()
            self.expect(')')
            return [f'throw new Error({e});']
        if self.is_('.'):
            self.take()
            method = self.ident().lower()
            typ = self.lookup(lname)
            if typ is None or typ.base != 'textbuilder':
                self.err(f'method call on {name}')
            self.expect('(')
            args = self.args()
            if method == 'append':
                return [f'{self.jsname(lname)}.push({args[0][0]});']
            self.err(f'unsupported TextBuilder.{method}')
        if lname in self.procs:
            args = self.args() if self.accept('(') else []
            return [self.call(lname, args) + ';']
        target, typ = self.lvalue(name)
        op = self.take()
        if op.val not in (':=', '+=', '-=', '*='):
            self.err(f'expected assignment, found {op.val!r}', op)
        val, vt = self.expr()
        if op.val == ':=':
            if typ.base != vt.base and not (typ.base == 'text' and vt.base == 'text'):
                self.err(f'cannot assign {vt} to {typ}')
            if typ.base == 'integer':
                val = self.chk(val)
            return [f'{target} = {val};']
        if typ.base == 'text' and op.val == '+=':
            return [f'{target} += {val};']
        if typ.base != 'integer' or vt.base != 'integer':
            self.err(f'{op.val} needs Integers')
        return [f'{target} = {self.chk(f"{target} {op.val[0]} ({val})")};']

    def lvalue(self, name):
        lname = name.lower()
        typ = self.lookup(lname)
        if typ is None:
            self.err(f'unknown variable {name}')
        js = self.jsname(lname)
        if self.accept('['):
            if typ.base != 'array':
                self.err(f'{name} is not an array')
            idx, it = self.expr()
            if it.base != 'integer':
                self.err('array index must be an Integer')
            self.expect(']')
            return f'{js}[{self.idx(idx, typ)}]', typ.elem
        return js, typ

    def idx(self, e, typ):
        n = 1
        for d in typ.dims:
            n *= d
        if self.fast:
            return e
        return f'IX({e}, {n})'

    def chk(self, e):
        return e if self.fast else f'CK({e})'

    def args(self):
        out = []
        while not self.is_(')'):
            out.append(self.expr())
            self.accept(',')
        self.expect(')')
        return out

    def call(self, lname, args):
        name, params, ret, local = self.procs[lname]
        if len(args) != len(params):
            self.err(f'{name} takes {len(params)} arguments')
        for (a, at), (p, pt) in zip(args, params):
            if at.base != pt.base:
                self.err(f'argument {p} of {name}: {at} for {pt}')
        return f'{self.jsname(lname)}({", ".join(a for a, _ in args)})'

    # ------------------------------------------------------------ expressions
    def bool_expr(self):
        e, t = self.expr()
        if t.base != 'boolean':
            self.err(f'condition is {t}')
        return e

    def expr(self):
        a, at = self.simple()
        if self.peek().kind == 'op' and self.peek().val in ('=', '<>', '<', '<=', '>', '>='):
            op = self.take().val
            b, bt = self.simple()
            if at.base != bt.base:
                self.err(f'comparing {at} with {bt}')
            if op in ('<', '<=', '>', '>=') and at.base != 'integer':
                self.err(f'{op} on {at}')
            js = {'=': '===', '<>': '!=='}.get(op, op)
            return f'({a} {js} {b})', BOOL
        return a, at

    def simple(self):
        a, at = self.term()
        while True:
            tok = self.peek()
            if tok.kind == 'op' and tok.val in ('+', '-'):
                self.take()
                b, bt = self.term()
                if at.base == 'text' and bt.base == 'text' and tok.val == '+':
                    a, at = f'({a} + {b})', TEXT
                    continue
                if at.base != 'integer' or bt.base != 'integer':
                    self.err(f'{tok.val} on {at}, {bt}')
                a = self.chk(f'({a} {tok.val} {b})') if not self.fast else f'({a} {tok.val} {b})'
            elif tok.kind == 'kw' and tok.val in ('or', 'xor'):
                self.take()
                b, bt = self.term()
                if at.base != 'boolean' or bt.base != 'boolean':
                    self.err(f'{tok.val} on {at}, {bt}')
                if tok.val == 'xor':
                    a = f'({a} !== {b})'
                else:
                    a = f'({a} || {b})' if self.fast else f'OR({a}, {b})'
            else:
                return a, at

    def term(self):
        a, at = self.factor()
        while True:
            tok = self.peek()
            if tok.kind == 'op' and tok.val == '*':
                self.take()
                b, bt = self.factor()
                if at.base != 'integer' or bt.base != 'integer':
                    self.err(f'* on {at}, {bt}')
                a = self.chk(f'({a} * {b})') if not self.fast else f'({a} * {b})'
            elif tok.kind == 'kw' and tok.val in ('div', 'mod'):
                self.take()
                b, bt = self.factor()
                if at.base != 'integer' or bt.base != 'integer':
                    self.err(f'{tok.val} on {at}, {bt}')
                if tok.val == 'div':
                    a = f'(({a} / {b}) | 0)' if self.fast else f'DIV({a}, {b})'
                else:
                    a = f'({a} % {b})' if self.fast else f'MOD({a}, {b})'
            elif tok.kind == 'kw' and tok.val == 'and':
                self.take()
                b, bt = self.factor()
                if at.base != 'boolean' or bt.base != 'boolean':
                    self.err(f'and on {at}, {bt}')
                a = f'({a} && {b})' if self.fast else f'AND({a}, {b})'
            elif tok.kind == 'op' and tok.val == '/':
                self.err('/ is not supported')
            else:
                return a, at

    def factor(self):
        tok = self.take()
        if tok.kind == 'num':
            return tok.val, INT
        if tok.kind == 'str':
            return repr(tok.val[1:-1].replace("''", "'")), TEXT
        if tok.kind == 'kw' and tok.val in ('true', 'false'):
            return tok.val, BOOL
        if tok.kind == 'kw' and tok.val == 'not':
            e, t = self.factor()
            if t.base != 'boolean':
                self.err(f'not on {t}')
            return f'(!{e})', BOOL
        if tok.kind == 'op' and tok.val == '-':
            e, t = self.factor()
            if t.base != 'integer':
                self.err(f'- on {t}')
            return f'(-{e})', INT
        if tok.kind == 'op' and tok.val == '(':
            e, t = self.expr()
            self.expect(')')
            return f'({e})', t
        if tok.kind in ('id', 'qid'):
            lname = tok.val.lower()
            if lname == 'copystr':
                self.expect('(')
                args = self.args()
                return f'{args[0][0]}.substr(({args[1][0]}) - 1, {args[2][0]})', TEXT
            if lname == 'strlen':
                self.expect('(')
                args = self.args()
                return f'{args[0][0]}.length', INT
            if lname in self.procs and self.lookup(lname) is None:
                args = self.args() if self.accept('(') else []
                ret = self.procs[lname][2]
                if ret is None:
                    self.err(f'{tok.val} returns no value')
                return self.call(lname, args), ret
            if self.is_('.'):
                self.take()
                method = self.ident().lower()
                self.expect('(')
                self.args()
                if method == 'totext':
                    return f"{self.jsname(lname)}.join('')", TEXT
                self.err(f'unsupported method {method}')
            return self.lvalue(tok.val)
        self.err(f'unexpected {tok.val!r} in expression', tok)

    # ------------------------------------------------------------ module
    def finish(self):
        hdr = ["'use strict';", '// generated by tools/al2js.py - do not edit', 'module.exports = function create() {',
               'const ST = {}, CALLS = {};']
        if not self.fast:
            hdr += [
                'const MAXI = 2147483647, MINI = -2147483648;',
                "function CK(x) { if (x > MAXI || x < MINI) throw new Error('AL Integer overflow: ' + x); return x; }",
                "function IX(i, n) { if (i < 1 || i > n || i !== (i | 0)) throw new Error('AL array index out of bounds: ' + i + ' of ' + n); return i; }",
                "function DIV(a, b) { if (b === 0) throw new Error('AL division by zero'); return (a / b) | 0; }",
                "function MOD(a, b) { if (b === 0) throw new Error('AL division by zero'); return a % b; }",
                'function AND(a, b) { return a && b; }',
                'function OR(a, b) { return a || b; }',
            ]
        for lname, typ in self.globals.items():
            hdr.append(f'let {self.jsname(lname)} = {self.default(typ)};')
        api = []
        for lname, (name, params, ret, local) in self.procs.items():
            if not local:
                api.append(f'  {name}: {self.jsname(lname)},')
        glob = ', '.join(f'{lname}: {self.jsname(lname)}' for lname in self.globals)
        tail = ['return {'] + api + [f'  _globals: () => ({{ {glob} }}),', '  _stats: () => ({ ST, CALLS }),', '};', '};']
        return '\n'.join(hdr + self.out + tail) + '\n'


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    fast = '--fast' in sys.argv
    src = open(args[0], encoding='utf-8').read()
    js = Translator(tokenize(src), fast, '--count' in sys.argv).parse()
    with open(args[1], 'w', encoding='utf-8', newline='\n') as f:
        f.write(js)
    print('wrote', args[1])


if __name__ == '__main__':
    main()
