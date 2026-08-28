#!/usr/bin/env python3
"""Generate a conservative Hilbert raw binding from a C header using clang's AST.

The generator maps unfamiliar pointers/records/callbacks to ADDRESS. That
keeps ABI declarations honest while richer handwritten facade modules can add Hilbert
record types where their layout has been verified.
"""
from __future__ import annotations
import argparse, json, re, subprocess, sys
from pathlib import Path

IDENT_RE = re.compile(r'[^A-Za-z0-9_]')
RESERVED = {x.lower() for x in '''MODULE IMPORT EXPORT CONST TYPE SUBTYPE VAR RECORD ARRAY POINTER REF PROCEDURE RETURN BEGIN END IF THEN ELSIF ELSE CASE OF FOR IN TO BY WHILE REPEAT UNTIL LOOP EXIT AND OR NOT DIV MOD TRUE FALSE NIL NEW TASK START AWAIT PARALLEL PROTECTED ATOMIC PRE POST ASSERT EXCEPTION RAISE UNSAFE FOREIGN LIBRARY VARARGS SIZEOF ALIGNOF ADR WITH DEFER GENERIC DISTINCT SET SLICE'''.split()}

def hident(s: str, fallback: str) -> str:
    s = IDENT_RE.sub('_', s or fallback)
    if not s or s[0].isdigit(): s = '_' + s
    if s.lower() in RESERVED: s += '_'
    return s

def ctype(q: str, *, ret=False) -> str | None:
    q = re.sub(r'\b(const|volatile|restrict|_Atomic)\b', '', q)
    q = ' '.join(q.split())
    if q == 'void': return None if ret else 'ADDRESS'
    # Function pointers, pointer-to-pointer, arrays and unknown pointers are opaque.
    if '(*' in q or q.count('*') > 1 or '[' in q: return 'ADDRESS'
    if '*' in q:
        base = q.replace('*','').strip()
        if base in {'char','signed char'}: return 'CSTRING'
        primitive_ptrs = {
            'unsigned char':'BYTE', '_Bool':'BOOLEAN', 'bool':'BOOLEAN',
            'short':'INTEGER16', 'short int':'INTEGER16', 'unsigned short':'CARDINAL16', 'unsigned short int':'CARDINAL16',
            'int':'INTEGER32', 'signed int':'INTEGER32', 'unsigned':'CARDINAL32', 'unsigned int':'CARDINAL32',
            'long':'INTEGER64', 'long int':'INTEGER64', 'unsigned long':'CARDINAL64', 'unsigned long int':'CARDINAL64',
            'long long':'INTEGER64', 'long long int':'INTEGER64', 'unsigned long long':'CARDINAL64', 'unsigned long long int':'CARDINAL64',
            'float':'REAL32', 'double':'REAL64', 'size_t':'SIZE', 'ssize_t':'INTEGER64',
            'int8_t':'INTEGER8', 'int16_t':'INTEGER16', 'int32_t':'INTEGER32', 'int64_t':'INTEGER64',
            'uint8_t':'CARDINAL8', 'uint16_t':'CARDINAL16', 'uint32_t':'CARDINAL32', 'uint64_t':'CARDINAL64',
        }
        if base in primitive_ptrs: return 'POINTER TO ' + primitive_ptrs[base]
        return 'ADDRESS'
    aliases = {
        '_Bool':'BOOLEAN','bool':'BOOLEAN','char':'CHAR','signed char':'INTEGER8','unsigned char':'BYTE',
        'short':'INTEGER16','short int':'INTEGER16','signed short':'INTEGER16','signed short int':'INTEGER16',
        'unsigned short':'CARDINAL16','unsigned short int':'CARDINAL16',
        'int':'INTEGER32','signed':'INTEGER32','signed int':'INTEGER32','unsigned':'CARDINAL32','unsigned int':'CARDINAL32',
        'long':'INTEGER64','long int':'INTEGER64','signed long':'INTEGER64','signed long int':'INTEGER64',
        'unsigned long':'CARDINAL64','unsigned long int':'CARDINAL64',
        'long long':'INTEGER64','long long int':'INTEGER64','signed long long':'INTEGER64','signed long long int':'INTEGER64',
        'unsigned long long':'CARDINAL64','unsigned long long int':'CARDINAL64',
        'float':'REAL32','double':'REAL64','long double':'REAL64',
        'size_t':'SIZE','ssize_t':'INTEGER64','ptrdiff_t':'INTEGER64','intptr_t':'INTEGER64','uintptr_t':'CARDINAL64',
        'int8_t':'INTEGER8','int16_t':'INTEGER16','int32_t':'INTEGER32','int64_t':'INTEGER64',
        'uint8_t':'CARDINAL8','uint16_t':'CARDINAL16','uint32_t':'CARDINAL32','uint64_t':'CARDINAL64',
        'time_t':'INTEGER64','off_t':'INTEGER64','FILE':'ADDRESS',
    }
    if q in aliases: return aliases[q]
    # enums and typedef handles are passed using the platform's normal scalar/pointer ABI;
    # ADDRESS is the safest raw representation until a facade verifies the typedef.
    if q.startswith('enum '): return 'INTEGER32'
    return 'ADDRESS'

def walk(n):
    yield n
    for ch in n.get('inner', []): yield from walk(ch)

def parse_ast(header: Path, clang: str, clang_args: list[str]):
    cmd=[clang,'-x','c','-fsyntax-only','-Xclang','-ast-dump=json',*clang_args,str(header)]
    p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    if p.returncode:
        print(p.stderr,file=sys.stderr); raise SystemExit(p.returncode)
    return json.loads(p.stdout)

def fn_decl(n):
    if n.get('kind') != 'FunctionDecl' or n.get('isImplicit'): return None
    name=n.get('name'); qt=n.get('type',{}).get('qualType','')
    if not name or not qt: return None
    ret_q=qt.split(' (',1)[0]
    ret=ctype(ret_q,ret=True)
    params=[]
    for i,ch in enumerate(n.get('inner', [])):
        if ch.get('kind')!='ParmVarDecl': continue
        pq=ch.get('type',{}).get('qualType','void *')
        params.append((hident(ch.get('name',''),f'Arg{i}'),ctype(pq) or 'ADDRESS'))
    variadic=bool(n.get('variadic')) or qt.endswith(', ...)') or qt.endswith('(...)')
    return name,params,ret,variadic

def emit(module:str, library:str, funcs, note:str):
    names=[f[0] for f in funcs]
    out=[f'MODULE {module};',f'(* {note} *)']
    for i in range(0,len(names),20): out.append('EXPORT '+', '.join(names[i:i+20])+';')
    out += ['',f'FOREIGN "C" LIBRARY "{library}";','']
    for name,params,ret,varargs in funcs:
        args='; '.join(f'{n}: {t}' for n,t in params)
        line=f'FOREIGN "C" PROCEDURE {name}({args})'
        if ret: line+=f': {ret}'
        if varargs: line+=' VARARGS'
        line+=';'
        out.append(line)
    out += ['',f'END {module}.','']
    return '\n'.join(out)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('header',type=Path); ap.add_argument('--module',required=True); ap.add_argument('--library',required=True)
    ap.add_argument('--prefix',action='append',default=[]); ap.add_argument('--clang',default='clang')
    ap.add_argument('--clang-arg',action='append',default=[]); ap.add_argument('-o','--output',type=Path)
    ns=ap.parse_args()
    tree=parse_ast(ns.header,ns.clang,ns.clang_arg)
    found={}
    for n in walk(tree):
        f=fn_decl(n)
        if not f: continue
        if ns.prefix and not any(f[0].startswith(p) for p in ns.prefix): continue
        found[f[0]]=f
    funcs=[found[k] for k in sorted(found)]
    note=f'Generated raw C ABI binding from {ns.header.name}; {len(funcs)} procedures. Unknown/complex C types are conservatively ADDRESS.'
    text=emit(ns.module,ns.library,funcs,note)
    if ns.output: ns.output.write_text(text)
    else: sys.stdout.write(text)
    print(f'generated {ns.module}: {len(funcs)} procedures',file=sys.stderr)
if __name__=='__main__': main()
