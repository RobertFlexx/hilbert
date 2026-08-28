#!/usr/bin/env python3
"""Generate Hilbert's raw SQLite3 binding from an official sqlite3.h.

This derives the callable surface and integer constants from the header
being targeted. Session/preupdate declarations are enabled while parsing so a release
binding can include those optional first-party SQLite APIs too.
"""
from __future__ import annotations
import argparse, ast, json, re, subprocess, sys
from pathlib import Path

ALIASES = {
    'sqlite3':'Database','sqlite3_stmt':'Statement','sqlite3_value':'Value','sqlite3_context':'Context',
    'sqlite3_backup':'Backup','sqlite3_blob':'Blob','sqlite3_mutex':'Mutex','sqlite3_vfs':'VFS',
    'sqlite3_file':'File','sqlite3_io_methods':'IOMethods','sqlite3_module':'Module','sqlite3_index_info':'IndexInfo',
    'sqlite3_snapshot':'Snapshot','sqlite3_session':'Session','sqlite3_changeset_iter':'ChangesetIterator',
    'sqlite3_changegroup':'ChangeGroup','sqlite3_rebaser':'Rebaser','sqlite3_api_routines':'APIRoutines',
    'sqlite3_mem_methods':'MemoryMethods','sqlite3_pcache_methods':'PCacheMethods','sqlite3_pcache_methods2':'PCacheMethods2',
    'sqlite3_pcache':'PCache','sqlite3_pcache_page':'PCachePage','sqlite3_str':'StringBuilder',
}
RESERVED={x.lower() for x in 'MODULE IMPORT EXPORT CONST TYPE SUBTYPE VAR RECORD ARRAY POINTER REF PROCEDURE RETURN BEGIN END IF THEN ELSIF ELSE CASE OF FOR IN TO BY WHILE REPEAT UNTIL LOOP EXIT AND OR NOT DIV MOD TRUE FALSE NIL NEW TASK START AWAIT PARALLEL PROTECTED ATOMIC PRE POST ASSERT EXCEPTION RAISE UNSAFE FOREIGN LIBRARY VARARGS SIZEOF ALIGNOF ADR WITH DEFER GENERIC DISTINCT SET SLICE'.split()}

def ident(s, fallback):
    s=re.sub(r'[^A-Za-z0-9_]','_',s or fallback)
    if not s or s[0].isdigit(): s='_'+s
    if s.lower() in RESERVED: s+='_'
    return s

def clean(q): return ' '.join(re.sub(r'\b(const|volatile|restrict|_Atomic)\b','',q).split())

def map_base(base):
    base=clean(base)
    if base in ALIASES: return ALIASES[base]
    table={
      'void':'ADDRESS','char':'CHAR','signed char':'INTEGER8','unsigned char':'BYTE','short':'INTEGER16','unsigned short':'CARDINAL16',
      'int':'INTEGER32','unsigned int':'CARDINAL32','long':'INTEGER64','unsigned long':'CARDINAL64','long long':'INTEGER64','unsigned long long':'CARDINAL64',
      'float':'REAL32','double':'REAL64','size_t':'SIZE','sqlite3_int64':'INTEGER64','sqlite3_uint64':'CARDINAL64',
      'sqlite_int64':'INTEGER64','sqlite_uint64':'CARDINAL64','sqlite3_filename':'CSTRING','sqlite3_destructor_type':'ADDRESS','sqlite3_syscall_ptr':'ADDRESS',
    }
    return table.get(base,'ADDRESS')

def map_type(q, ret=False):
    q=clean(q)
    if q=='void': return None if ret else 'ADDRESS'
    if '(*' in q or '[' in q: return 'ADDRESS'
    stars=q.count('*')
    base=q.replace('*','').strip()
    if stars:
        if base=='char': elem='CSTRING'
        elif base=='unsigned char': elem='POINTER TO BYTE'
        else: elem=map_base(base)
        if stars==1:
            if base=='char': return 'CSTRING'
            if base=='unsigned char': return 'POINTER TO BYTE'
            if base in ALIASES: return ALIASES[base]
            return 'ADDRESS'
        if stars==2 and base in ALIASES: return 'POINTER TO '+ALIASES[base]
        if stars==2 and base=='char': return 'POINTER TO CSTRING'
        return 'ADDRESS'
    return map_base(base)

def walk(n):
    yield n
    for c in n.get('inner',[]): yield from walk(c)

def ast_tree(header, clang):
    cmd=[clang,'-x','c','-fsyntax-only','-DSQLITE_ENABLE_SESSION=1','-DSQLITE_ENABLE_PREUPDATE_HOOK=1','-Xclang','-ast-dump=json',str(header)]
    p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    if p.returncode: print(p.stderr,file=sys.stderr); raise SystemExit(p.returncode)
    return json.loads(p.stdout)

def functions(header, clang):
    found={}
    for n in walk(ast_tree(header,clang)):
        if n.get('kind')!='FunctionDecl' or n.get('isImplicit'): continue
        name=n.get('name','')
        if not (name.startswith('sqlite3_') or name.startswith('sqlite3session_') or name.startswith('sqlite3changeset_') or name.startswith('sqlite3changegroup_') or name.startswith('sqlite3rebaser_')): continue
        qt=n.get('type',{}).get('qualType','')
        if not qt: continue
        ret=map_type(qt.split(' (',1)[0],ret=True)
        ps=[]
        for i,c in enumerate(n.get('inner',[])):
            if c.get('kind')=='ParmVarDecl': ps.append((ident(c.get('name'),f'Arg{i+1}'),map_type(c.get('type',{}).get('qualType','void *')) or 'ADDRESS'))
        variadic=bool(n.get('variadic')) or qt.endswith(', ...)') or qt.endswith('(...)')
        found[name]=(name,ps,ret,variadic)
    return [found[k] for k in sorted(found)]

class Eval(ast.NodeVisitor):
    def visit_Expression(self,n): return self.visit(n.body)
    def visit_Constant(self,n):
        if type(n.value) is not int: raise ValueError
        return n.value
    def visit_UnaryOp(self,n):
        v=self.visit(n.operand)
        if isinstance(n.op,ast.USub): return -v
        if isinstance(n.op,ast.UAdd): return v
        if isinstance(n.op,ast.Invert): return ~v
        raise ValueError
    def visit_BinOp(self,n):
        a,b=self.visit(n.left),self.visit(n.right); op=n.op
        if isinstance(op,ast.Add): return a+b
        if isinstance(op,ast.Sub): return a-b
        if isinstance(op,ast.Mult): return a*b
        if isinstance(op,ast.FloorDiv): return a//b
        if isinstance(op,ast.LShift): return a<<b
        if isinstance(op,ast.RShift): return a>>b
        if isinstance(op,ast.BitOr): return a|b
        if isinstance(op,ast.BitAnd): return a&b
        if isinstance(op,ast.BitXor): return a^b
        raise ValueError
    def generic_visit(self,n): raise ValueError

def constants(header, clang):
    p=subprocess.run([clang,'-dM','-E','-DSQLITE_ENABLE_SESSION=1','-DSQLITE_ENABLE_PREUPDATE_HOOK=1',str(header)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    raw={}
    version='unknown'
    for line in p.stdout.splitlines():
        m=re.match(r'#define\s+(SQLITE_[A-Za-z0-9_]+)\s+(.+)$',line)
        if not m or '(' in m.group(1): continue
        name,val=m.groups()
        if name=='SQLITE_VERSION': version=val.strip('"')
        raw[name]=val
    vals={}
    name_re=re.compile(r'\bSQLITE_[A-Za-z0-9_]+\b')
    for _ in range(20):
        changed=False
        for name,v in raw.items():
            if name in vals: continue
            expr=v
            if expr.startswith('"') or "'" in expr or '?' in expr or 'sizeof' in expr: continue
            expr=re.sub(r'(?<=\d)[uUlL]+\b','',expr)
            refs=name_re.findall(expr)
            if any(r not in vals for r in refs): continue
            for r in sorted(set(refs),key=len,reverse=True): expr=re.sub(r'\b'+re.escape(r)+r'\b',str(vals[r]),expr)
            # common C integer casts
            expr=re.sub(r'\((?:unsigned|signed|int|long|sqlite3_[A-Za-z0-9_]+)\s*\*?\)','',expr)
            expr=expr.replace('/','//')
            try: val=Eval().visit(ast.parse(expr,mode='eval'))
            except Exception: continue
            vals[name]=int(val); changed=True
        if not changed: break
    return version, dict(sorted(vals.items()))

def chunks(xs,n=18):
    for i in range(0,len(xs),n): yield xs[i:i+n]

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('header',type=Path); ap.add_argument('-o','--output',type=Path,required=True); ap.add_argument('--clang',default='clang'); ns=ap.parse_args()
    funcs=functions(ns.header,ns.clang); version,consts=constants(ns.header,ns.clang)
    aliases=sorted(set(ALIASES.values()))
    exports=aliases+list(consts)+[f[0] for f in funcs]
    out=['MODULE SQLite3;',f'(* Generated from sqlite3.h {version}; complete discovered raw function surface for this header, including session/preupdate declarations. *)']
    for c in chunks(exports): out.append('EXPORT '+', '.join(c)+';')
    out += ['','FOREIGN "C" LIBRARY "sqlite3";','','TYPE']
    for a in aliases: out.append(f'    {a} = ADDRESS;')
    out += ['','CONST']
    for k,v in consts.items(): out.append(f'    {k} = {v};')
    out.append('')
    for name,ps,ret,varargs in funcs:
        sig='; '.join(f'{n}: {t}' for n,t in ps)
        line=f'FOREIGN "C" PROCEDURE {name}({sig})'
        if ret: line+=f': {ret}'
        if varargs: line+=' VARARGS'
        out.append(line+';')
    out += ['','END SQLite3.','']
    ns.output.write_text('\n'.join(out))
    print(f'generated SQLite3 {version}: {len(funcs)} procedures, {len(consts)} integer constants')
if __name__=='__main__': main()
