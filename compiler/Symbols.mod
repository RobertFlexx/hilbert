IMPLEMENTATION MODULE Symbols;
FROM HStrings IMPORT Assign,Equal;
FROM Diagnostics IMPORT SimpleCode,Severity;
FROM ErrorCodes IMPORT EArenaSymbols,EArenaScopes;
VAR Syms:ARRAY[0..MaxSymbols] OF Symbol; SymN:CARDINAL; Parents:ARRAY[0..MaxScopes] OF ScopeId; ScopeN:CARDINAL;
PROCEDURE Init; BEGIN SymN:=0; ScopeN:=0; Parents[0]:=0 END Init;
PROCEDURE OpenScope(Parent:ScopeId):ScopeId; BEGIN IF ScopeN>=MaxScopes THEN SimpleCode(Fatal,EArenaScopes,'scope arena exhausted'); RETURN 0 END; INC(ScopeN); Parents[ScopeN]:=Parent; RETURN ScopeN END OpenScope;
PROCEDURE Define(Scope:ScopeId; Name:ARRAY OF CHAR; Kind:SymbolKind; Decl:NodeId):SymbolId;
VAR I:SymbolId;
BEGIN IF SymN>=MaxSymbols THEN SimpleCode(Fatal,EArenaSymbols,'symbol table exhausted'); RETURN 0 END; INC(SymN); I:=SymN; Assign(Syms[I].Name,Name); Syms[I].Kind:=Kind; Syms[I].Decl:=Decl; Syms[I].TypeId:=0; Syms[I].Scope:=Scope; Syms[I].Flags:={}; RETURN I END Define;
PROCEDURE LookupLocal(Scope:ScopeId; Name:ARRAY OF CHAR):SymbolId;
VAR I:SymbolId;
BEGIN I:=SymN; WHILE I>0 DO IF (Syms[I].Scope=Scope) AND Equal(Syms[I].Name,Name) THEN RETURN I END; DEC(I) END; RETURN 0 END LookupLocal;
PROCEDURE Lookup(Scope:ScopeId; Name:ARRAY OF CHAR):SymbolId;
VAR S:ScopeId; I:SymbolId;
BEGIN S:=Scope; LOOP I:=SymN; WHILE I>0 DO IF (Syms[I].Scope=S) AND Equal(Syms[I].Name,Name) THEN RETURN I END; DEC(I) END; IF S=0 THEN EXIT END; S:=Parents[S] END; RETURN 0 END Lookup;
PROCEDURE Get(Id:SymbolId):Symbol; BEGIN RETURN Syms[Id] END Get;
PROCEDURE Put(Id:SymbolId; S:Symbol); BEGIN Syms[Id]:=S END Put;
END Symbols.
