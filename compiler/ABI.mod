IMPLEMENTATION MODULE ABI;

IMPORT Types,Layout;
FROM Types IMPORT TypeId,Type,TypeKind;

PROCEDURE ScalarClass(Ty:TypeId):Class;
VAR T:Type;
BEGIN
    IF Ty=0 THEN RETURN NoClass END; T:=Types.Get(Ty);
    IF (T.Kind=TyRange) OR (T.Kind=TyDistinct) OR (T.Kind=TyAtomic) THEN RETURN ScalarClass(T.Base) END;
    IF (T.Kind=TyR32) OR (T.Kind=TyR64) THEN RETURN SSEClass END;
    RETURN IntegerClass
END ScalarClass;

PROCEDURE Merge(A,B:Class):Class;
BEGIN
    IF A=NoClass THEN RETURN B END; IF B=NoClass THEN RETURN A END;
    IF (A=MemoryClass) OR (B=MemoryClass) THEN RETURN MemoryClass END;
    IF (A=IntegerClass) OR (B=IntegerClass) THEN RETURN IntegerClass END;
    RETURN SSEClass
END Merge;


PROCEDURE PlaceRecord(Ty:TypeId; BaseOffset:CARDINAL; VAR A,B:Class; VAR Bad:BOOLEAN);
VAR T:Type; I:CARDINAL; F:Layout.Field;
BEGIN
    T:=Types.Get(Ty);
    IF T.Base#0 THEN PlaceType(T.Base,BaseOffset,A,B,Bad) END;
    I:=1;
    WHILE (I<=Layout.Count()) AND NOT Bad DO
        F:=Layout.Get(I); IF F.Owner=Ty THEN PlaceType(F.TypeId,BaseOffset+F.Offset,A,B,Bad) END; INC(I)
    END
END PlaceRecord;

PROCEDURE PlaceType(Ty:TypeId; BaseOffset:CARDINAL; VAR A,B:Class; VAR Bad:BOOLEAN);
VAR T,Element:Type; C:Class; First,Last,I,Count:CARDINAL;
BEGIN
    IF (Ty=0) OR Bad THEN RETURN END; T:=Types.Get(Ty);
    IF (4 IN T.Flags) AND (T.Arg#0) THEN PlaceType(T.Arg,BaseOffset,A,B,Bad); RETURN END;
    IF (T.Kind=TyRange) OR (T.Kind=TyDistinct) OR (T.Kind=TyAtomic) THEN PlaceType(T.Base,BaseOffset,A,B,Bad); RETURN END;
    IF T.Size=0 THEN RETURN END;
    IF BaseOffset+T.Size>16 THEN Bad:=TRUE; RETURN END;
    IF (T.Kind=TyRecord) OR (T.Kind=TyProtected) THEN PlaceRecord(Ty,BaseOffset,A,B,Bad); RETURN END;
    IF T.Kind=TyArray THEN
        IF T.Base=0 THEN Bad:=TRUE; RETURN END; Element:=Types.Get(T.Base); IF Element.Size=0 THEN Bad:=TRUE; RETURN END;
        Count:=T.Size DIV Element.Size; I:=0;
        WHILE (I<Count) AND NOT Bad DO PlaceType(T.Base,BaseOffset+I*Element.Size,A,B,Bad); INC(I) END;
        RETURN
    END;
    C:=ScalarClass(Ty); First:=BaseOffset DIV 8; Last:=(BaseOffset+T.Size-1) DIV 8;
    IF First=0 THEN A:=Merge(A,C) ELSE B:=Merge(B,C) END;
    IF Last#First THEN IF Last=0 THEN A:=Merge(A,C) ELSE B:=Merge(B,C) END END
END PlaceType;

PROCEDURE ClassifySysV(Ty:TypeId; VAR C:Classification);
VAR T:Type; Bad:BOOLEAN;
BEGIN
    C.Count:=0; C.A:=NoClass; C.B:=NoClass; C.Size:=0; C.Align:=1;
    IF Ty=0 THEN RETURN END; T:=Types.Get(Ty);
    IF (4 IN T.Flags) AND (T.Arg#0) THEN ClassifySysV(T.Arg,C); C.Size:=T.Size; C.Align:=T.Align; RETURN END;
    IF (T.Kind=TyRange) OR (T.Kind=TyDistinct) OR (T.Kind=TyAtomic) THEN ClassifySysV(T.Base,C); C.Size:=T.Size; C.Align:=T.Align; RETURN END;
    C.Size:=T.Size; C.Align:=T.Align; IF T.Size=0 THEN RETURN END;
    IF (T.Kind=TyR32) OR (T.Kind=TyR64) THEN C.Count:=1; C.A:=SSEClass; RETURN END;
    IF (T.Kind=TyRecord) OR (T.Kind=TyProtected) OR (T.Kind=TyArray) THEN
        IF T.Size>16 THEN C.Count:=1; C.A:=MemoryClass; RETURN END;
        Bad:=FALSE; PlaceType(Ty,0,C.A,C.B,Bad);
        IF Bad OR (C.A=MemoryClass) OR (C.B=MemoryClass) THEN C.Count:=1; C.A:=MemoryClass; C.B:=NoClass; RETURN END;
        IF T.Size<=8 THEN C.Count:=1; IF C.A=NoClass THEN C.A:=IntegerClass END
        ELSE C.Count:=2; IF C.A=NoClass THEN C.A:=IntegerClass END; IF C.B=NoClass THEN C.B:=IntegerClass END
        END; RETURN
    END;
    IF T.Size<=8 THEN C.Count:=1; C.A:=IntegerClass; RETURN END;
    IF T.Size<=16 THEN C.Count:=2; C.A:=IntegerClass; C.B:=IntegerClass; RETURN END;
    C.Count:=1; C.A:=MemoryClass
END ClassifySysV;

END ABI.
