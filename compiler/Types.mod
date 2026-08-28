IMPLEMENTATION MODULE Types;
FROM HStrings IMPORT Assign,Equal,Clear;
FROM Diagnostics IMPORT SimpleCode,Severity;
FROM ErrorCodes IMPORT EArenaTypes;
VAR Ts:ARRAY[0..MaxTypes] OF Type; N,BuiltinN:CARDINAL;

PROCEDURE Add(Name:ARRAY OF CHAR; K:TypeKind; Size,Align:CARDINAL):TypeId;
VAR I:TypeId;
BEGIN
    IF N>=MaxTypes THEN SimpleCode(Fatal,EArenaTypes,'type arena exhausted'); RETURN 0 END;
    INC(N); I:=N; Ts[I].Kind:=K; Assign(Ts[I].Name,Name); Ts[I].Base:=0; Ts[I].Arg:=0; Ts[I].Result:=0;
    Ts[I].Lo:=0; Ts[I].Hi:=0; Ts[I].Size:=Size; Ts[I].Align:=Align; Ts[I].Flags:={}; RETURN I
END Add;

PROCEDURE AddBuiltin(Name:ARRAY OF CHAR; K:TypeKind; Size,Align:CARDINAL);
VAR I:TypeId;
BEGIN
    I:=Add(Name,K,Size,Align);
    IF I=0 THEN RETURN END
END AddBuiltin;

PROCEDURE Init;
BEGIN
    N:=0;
    AddBuiltin('VOID',TyVoid,0,1); AddBuiltin('BOOLEAN',TyBoolean,1,1); AddBuiltin('CHAR',TyChar,4,4); AddBuiltin('BYTE',TyByte,1,1);
    AddBuiltin('INTEGER8',TyI8,1,1); AddBuiltin('INTEGER16',TyI16,2,2); AddBuiltin('INTEGER32',TyI32,4,4); AddBuiltin('INTEGER64',TyI64,8,8);
    AddBuiltin('CARDINAL8',TyU8,1,1); AddBuiltin('CARDINAL16',TyU16,2,2); AddBuiltin('CARDINAL32',TyU32,4,4); AddBuiltin('CARDINAL64',TyU64,8,8);
    AddBuiltin('INTEGER',TyInteger,8,8); AddBuiltin('CARDINAL',TyCardinal,8,8); AddBuiltin('SIZE',TySize,8,8); AddBuiltin('ADDRESS',TyAddress,8,8);
    AddBuiltin('REAL32',TyR32,4,4); AddBuiltin('REAL64',TyR64,8,8); AddBuiltin('STRING',TyString,8,8); AddBuiltin('CSTRING',TyCString,8,8);
    BuiltinN:=N
END Init;

PROCEDURE Builtin(Name:ARRAY OF CHAR):TypeId;
VAR I:TypeId;
BEGIN I:=1; WHILE I<=BuiltinN DO IF Equal(Ts[I].Name,Name) THEN RETURN I END; INC(I) END; RETURN 0 END Builtin;

PROCEDURE NewType(K:TypeKind):TypeId;
VAR I:TypeId;
BEGIN
    IF N>=MaxTypes THEN SimpleCode(Fatal,EArenaTypes,'type arena exhausted'); RETURN 0 END; INC(N); I:=N; Ts[I].Kind:=K; Clear(Ts[I].Name); Ts[I].Base:=0; Ts[I].Arg:=0; Ts[I].Result:=0;
    Ts[I].Lo:=0; Ts[I].Hi:=0; Ts[I].Size:=0; Ts[I].Align:=1; Ts[I].Flags:={}; RETURN I
END NewType;

PROCEDURE Get(Id:TypeId):Type; BEGIN RETURN Ts[Id] END Get;
PROCEDURE Put(Id:TypeId; T:Type); BEGIN Ts[Id]:=T END Put;

PROCEDURE IsInteger(T:TypeId):BOOLEAN;
VAR K:TypeKind;
BEGIN
    IF T=0 THEN RETURN FALSE END; K:=Ts[T].Kind;
    IF K=TyRange THEN RETURN IsInteger(Ts[T].Base) END;
    IF K=TyDistinct THEN RETURN IsInteger(Ts[T].Base) END;
    RETURN ((K>=TyI8) AND (K<=TyAddress)) OR (K=TyByte) OR (K=TyChar) OR (K=TyEnum)
END IsInteger;

PROCEDURE IsNumeric(T:TypeId):BOOLEAN;
VAR K:TypeKind;
BEGIN
    IF T=0 THEN RETURN FALSE END; K:=Ts[T].Kind;
    IF (K=TyRange) OR (K=TyDistinct) THEN RETURN IsNumeric(Ts[T].Base) END;
    RETURN IsInteger(T) OR (K=TyR32) OR (K=TyR64)
END IsNumeric;

PROCEDURE PlainInteger(T:TypeId):BOOLEAN;
VAR K:TypeKind;
BEGIN
    IF T=0 THEN RETURN FALSE END; K:=Ts[T].Kind;
    RETURN (K=TyByte) OR ((K>=TyI8) AND (K<=TySize))
END PlainInteger;

PROCEDURE Compatible(A,B:TypeId):BOOLEAN;
BEGIN
    IF A=B THEN RETURN TRUE END; IF (A=0) OR (B=0) THEN RETURN FALSE END;
    IF Ts[A].Kind=TyRange THEN RETURN Compatible(Ts[A].Base,B) END;
    IF Ts[B].Kind=TyRange THEN RETURN Compatible(A,Ts[B].Base) END;
    (* DISTINCT is nominal: it only matched above when A=B. *)
    IF (Ts[A].Kind=TyDistinct) OR (Ts[B].Kind=TyDistinct) THEN RETURN FALSE END;
    IF ((Ts[A].Kind=TyPointer) AND (Ts[B].Kind=TyPointer)) OR ((Ts[A].Kind=TyRef) AND (Ts[B].Kind=TyRef)) THEN RETURN Compatible(Ts[A].Base,Ts[B].Base) END;
    IF ((Ts[A].Kind=TyPointer) OR (Ts[A].Kind=TyRef)) AND (Ts[B].Kind=TyAddress) THEN RETURN TRUE END;
    IF ((Ts[B].Kind=TyPointer) OR (Ts[B].Kind=TyRef)) AND (Ts[A].Kind=TyAddress) THEN RETURN TRUE END;
    IF (Ts[A].Kind=TySlice) AND (Ts[B].Kind=TySlice) THEN RETURN Compatible(Ts[A].Base,Ts[B].Base) END;
    IF (Ts[A].Kind=TySet) AND (Ts[B].Kind=TySet) THEN
        IF (Ts[A].Base=0) OR (Ts[B].Base=0) THEN RETURN TRUE END;
        IF (0 IN Ts[A].Flags) OR (0 IN Ts[B].Flags) THEN RETURN Compatible(Ts[A].Base,Ts[B].Base) END;
        RETURN Ts[A].Base=Ts[B].Base
    END;
    IF ((Ts[A].Kind=TyString) AND (Ts[B].Kind=TyCString)) OR ((Ts[A].Kind=TyCString) AND (Ts[B].Kind=TyString)) THEN RETURN TRUE END;
    IF (Ts[A].Kind=TyEnum) OR (Ts[B].Kind=TyEnum) THEN RETURN FALSE END;
    (* CHAR and ADDRESS are integer-shaped in the ABI, but they are not ordinary
       arithmetic integers.  Keeping them out here stops accidental implicit
       CHAR/ADDRESS conversions while preserving explicit casts. *)
    IF PlainInteger(A) AND PlainInteger(B) THEN RETURN TRUE END;
    RETURN FALSE
END Compatible;

END Types.
