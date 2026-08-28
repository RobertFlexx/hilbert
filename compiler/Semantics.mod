IMPLEMENTATION MODULE Semantics;

IMPORT AST, Symbols, Types, Layout, Signatures, Interfaces, Methods, Generics, GenericProcedures, Divisions;
FROM AST IMPORT NodeId,Node,NodeKind;
FROM Symbols IMPORT OpenScope,Define,Lookup,LookupLocal,Symbol,SymbolId,ScopeId,SymbolKind;
FROM Types IMPORT TypeId,Builtin,NewType,Type,TypeKind,Compatible,IsNumeric;
IMPORT Diagnostics;
FROM Diagnostics IMPORT Report,Severity,HasErrors;
FROM ErrorCodes IMPORT EExitOutsideLoop,EDuplicateDeclaration,EUnknownIdentifier,EUnknownType,EPrivateMember,EUnknownField,ENotProcedure,EWrongArgumentCount,EArgumentType,EAssignmentType,EReturnType,EReturnValueRequired,EVoidReturnValue,EConditionBoolean,EAssertBoolean,EIndexInteger,ENotIndexable,EDerefType,ENotAssignable,EIncompatibleOperands,EBitwiseInteger,EBadRecordBase,ERecursiveValueType,EExportMissing,EInvalidTypeExpression,EInvalidNumber,EAddressableRequired,ERangeBounds,EGenericArity,ETypeConversionArity,EManagedRawConversion,EDistinctConversion,EForIterator,EConstantExpression,EDivisionVisibility,WUnreachable;
FROM Source IMPORT FileName,LineText;
FROM HStrings IMPORT Text,Equal,Assign,Append;
FROM Tokens IMPORT TokenKind,FromOrdinal,IsComparison,TkPlus,TkMinus,TkStar,TkSlash,TkEqual,TkNotEqual,TkLess,TkLessEqual,TkGreater,TkGreaterEqual,KwNOT,KwDIV,KwMOD,KwSHL,KwSHR,KwXOR,KwAND,KwOR;

CONST MaxTypedNodes=200000; MaxDefinitionTypes=1024; MaxTypePairs=4096; MaxDivisions=1024;
VAR NodeTypes:ARRAY[0..MaxTypedNodes] OF TypeId; Global:ScopeId; F,CurrentModule:Text; CurrentReturn:TypeId; CurrentLoopDepth:CARDINAL; GraphReady:BOOLEAN;
    DefinitionPublic,DefinitionActual:ARRAY[0..MaxDefinitionTypes-1] OF TypeId; DefinitionTypeCount:CARDINAL;
    ComparedPublic,ComparedActual:ARRAY[0..MaxTypePairs-1] OF TypeId; ComparedCount:CARDINAL;
    ImportedModules:ARRAY[0..511] OF Text; ImportedModuleScopes:ARRAY[0..511] OF ScopeId; ImportedModuleCount:CARDINAL;
    DivisionNodes:ARRAY[0..MaxDivisions-1] OF NodeId; DivisionScopes:ARRAY[0..MaxDivisions-1] OF ScopeId; DivisionCount:CARDINAL;

PROCEDURE ErrCode(N:Node; Code:CARDINAL; M:ARRAY OF CHAR);
VAR L:Text;
BEGIN LineText(N.Line,L); Diagnostics.CodedContext(Error,Code,F,N.Line,N.Column,M,L) END ErrCode;

PROCEDURE Err(N:Node; M:ARRAY OF CHAR);
BEGIN ErrCode(N,EInvalidTypeExpression,M) END Err;

PROCEDURE WarnCode(N:Node; Code:CARDINAL; M:ARRAY OF CHAR);
VAR L:Text;
BEGIN LineText(N.Line,L); Diagnostics.CodedContext(Warning,Code,F,N.Line,N.Column,M,L) END WarnCode;

PROCEDURE DigitValue(C:CHAR):INTEGER;
BEGIN
    IF (C>='0') AND (C<='9') THEN RETURN ORD(C)-ORD('0') END;
    IF (C>='a') AND (C<='f') THEN RETURN 10+ORD(C)-ORD('a') END;
    IF (C>='A') AND (C<='F') THEN RETURN 10+ORD(C)-ORD('A') END;
    RETURN -1
END DigitValue;

PROCEDURE TryParseLong(S:ARRAY OF CHAR; VAR Out:LONGINT):BOOLEAN;
VAR I:CARDINAL; V:LONGINT; Neg:BOOLEAN; Base,D:INTEGER;
BEGIN
    I:=0; V:=0; Neg:=FALSE; Base:=10;
    IF S[0]='-' THEN Neg:=TRUE; INC(I) END;
    IF (I<=HIGH(S)) AND (S[I]='0') AND (I<HIGH(S)) AND ((S[I+1]='x') OR (S[I+1]='X')) THEN Base:=16; INC(I,2)
    ELSIF (I<=HIGH(S)) AND (S[I]='0') AND (I<HIGH(S)) AND ((S[I+1]='b') OR (S[I+1]='B')) THEN Base:=2; INC(I,2)
    ELSIF (I<=HIGH(S)) AND (S[I]='0') AND (I<HIGH(S)) AND ((S[I+1]='o') OR (S[I+1]='O')) THEN Base:=8; INC(I,2)
    END;
    IF (I>HIGH(S)) OR (S[I]=0C) THEN RETURN FALSE END;
    WHILE (I<=HIGH(S)) AND (S[I]#0C) DO
        D:=DigitValue(S[I]); IF (D<0) OR (D>=Base) THEN RETURN FALSE END;
        IF V>(9223372036854775807-VAL(LONGINT,D)) DIV VAL(LONGINT,Base) THEN RETURN FALSE END;
        V:=V*VAL(LONGINT,Base)+VAL(LONGINT,D); INC(I)
    END;
    IF Neg THEN Out:=-V ELSE Out:=V END; RETURN TRUE
END TryParseLong;

PROCEDURE TryParseCardinal(S:ARRAY OF CHAR; VAR Out:LONGCARD):BOOLEAN;
VAR I:CARDINAL; V,MaxValue:LONGCARD; Base,D:INTEGER;
BEGIN
    I:=0; V:=0; Base:=10; MaxValue:=MAX(LONGCARD);
    IF (I<=HIGH(S)) AND (S[I]='0') AND (I<HIGH(S)) AND ((S[I+1]='x') OR (S[I+1]='X')) THEN Base:=16; INC(I,2)
    ELSIF (I<=HIGH(S)) AND (S[I]='0') AND (I<HIGH(S)) AND ((S[I+1]='b') OR (S[I+1]='B')) THEN Base:=2; INC(I,2)
    ELSIF (I<=HIGH(S)) AND (S[I]='0') AND (I<HIGH(S)) AND ((S[I+1]='o') OR (S[I+1]='O')) THEN Base:=8; INC(I,2)
    END;
    IF (I>HIGH(S)) OR (S[I]=0C) THEN RETURN FALSE END;
    WHILE (I<=HIGH(S)) AND (S[I]#0C) DO
        D:=DigitValue(S[I]); IF (D<0) OR (D>=Base) THEN RETURN FALSE END;
        IF V>(MaxValue-VAL(LONGCARD,D)) DIV VAL(LONGCARD,Base) THEN RETURN FALSE END;
        V:=V*VAL(LONGCARD,Base)+VAL(LONGCARD,D); INC(I)
    END;
    Out:=V; RETURN TRUE
END TryParseCardinal;

PROCEDURE ParseLong(S:ARRAY OF CHAR):LONGINT;
VAR V:LONGINT;
BEGIN IF TryParseLong(S,V) THEN RETURN V END; RETURN 0 END ParseLong;

PROCEDURE SafeAdd(A,B:LONGINT; VAR R:LONGINT):BOOLEAN;
CONST MaxLong=9223372036854775807; MinLong=-9223372036854775807-1;
BEGIN
    IF (B>0) AND (A>MaxLong-B) THEN RETURN FALSE END;
    IF (B<0) AND (A<MinLong-B) THEN RETURN FALSE END;
    R:=A+B; RETURN TRUE
END SafeAdd;

PROCEDURE SafeSub(A,B:LONGINT; VAR R:LONGINT):BOOLEAN;
CONST MaxLong=9223372036854775807; MinLong=-9223372036854775807-1;
BEGIN
    IF (B>0) AND (A<MinLong+B) THEN RETURN FALSE END;
    IF (B<0) AND (A>MaxLong+B) THEN RETURN FALSE END;
    R:=A-B; RETURN TRUE
END SafeSub;

PROCEDURE SafeMul(A,B:LONGINT; VAR R:LONGINT):BOOLEAN;
CONST MaxLong=9223372036854775807; MinLong=-9223372036854775807-1;
BEGIN
    IF (A=0) OR (B=0) THEN R:=0; RETURN TRUE END;
    IF A>0 THEN
        IF B>0 THEN IF A>MaxLong DIV B THEN RETURN FALSE END
        ELSE IF B<MinLong DIV A THEN RETURN FALSE END
        END
    ELSE
        IF B>0 THEN IF A<MinLong DIV B THEN RETURN FALSE END
        ELSE IF A<MaxLong DIV B THEN RETURN FALSE END
        END
    END;
    R:=A*B; RETURN TRUE
END SafeMul;

PROCEDURE SafeBitwise(A,B:LONGINT; K:TokenKind; VAR R:LONGINT):BOOLEAN;
CONST MaxLong=9223372036854775807;
VAR Place:LONGINT; ABit,BBit,Take:BOOLEAN;
BEGIN
    IF (A<0) OR (B<0) THEN RETURN FALSE END;
    R:=0; Place:=1;
    WHILE (A>0) OR (B>0) DO
        ABit:=(A MOD 2)#0; BBit:=(B MOD 2)#0;
        IF K=KwAND THEN Take:=ABit AND BBit
        ELSIF K=KwOR THEN Take:=ABit OR BBit
        ELSE Take:=ABit#BBit
        END;
        IF Take THEN IF NOT SafeAdd(R,Place,R) THEN RETURN FALSE END END;
        A:=A DIV 2; B:=B DIV 2;
        IF (A>0) OR (B>0) THEN IF Place>MaxLong DIV 2 THEN RETURN FALSE END; Place:=Place*2 END
    END;
    RETURN TRUE
END SafeBitwise;

PROCEDURE SafeShift(A,B:LONGINT; Left:BOOLEAN; VAR R:LONGINT):BOOLEAN;
VAR I:LONGINT;
BEGIN
    IF (A<0) OR (B<0) OR (B>=64) THEN RETURN FALSE END;
    R:=A; I:=0;
    WHILE I<B DO
        IF Left THEN IF NOT SafeMul(R,2,R) THEN RETURN FALSE END ELSE R:=R DIV 2 END;
        INC(I)
    END;
    RETURN TRUE
END SafeShift;

PROCEDURE SafeDivMod(A,B:LONGINT; VAR Q,R:LONGINT):BOOLEAN;
CONST MinLong=-9223372036854775807-1;
VAR HostR:LONGINT;
BEGIN
    IF (B=0) OR ((A=MinLong) AND (B=-1)) THEN RETURN FALSE END;
    Q:=A DIV B; HostR:=A MOD B;
    IF (HostR#0) AND ((A<0)#(B<0)) AND ((HostR<0)#(A<0)) THEN
        IF NOT SafeAdd(Q,1,Q) OR NOT SafeSub(HostR,B,HostR) THEN RETURN FALSE END
    END;
    R:=HostR; RETURN TRUE
END SafeDivMod;

PROCEDURE ConstInteger(Nid:NodeId; Scope:ScopeId; VAR V:LONGINT):BOOLEAN;
CONST MinLong=-9223372036854775807-1;
VAR N,D:Node; A,B,Remainder,Quotient:LONGINT; K:TokenKind; S:SymbolId; Sym:Symbol;
BEGIN
    IF Nid=0 THEN RETURN FALSE END; N:=AST.Get(Nid);
    IF N.Kind=NInteger THEN RETURN TryParseLong(N.Text,V) END;
    IF N.Kind=NBoolean THEN V:=N.IntValue; RETURN TRUE END;
    IF N.Kind=NChar THEN V:=N.IntValue; RETURN TRUE END;
    IF N.Kind=NConst THEN RETURN ConstInteger(N.A,Scope,V) END;
    IF ((N.Kind=NName) OR (N.Kind=NSelect)) AND (2 IN N.Flags) AND NOT (7 IN N.Flags) THEN V:=N.IntValue; RETURN TRUE END;
    IF N.Kind=NName THEN
        S:=Lookup(Scope,N.Text); IF S=0 THEN RETURN FALSE END; Sym:=Symbols.Get(S); IF Sym.Kind#SymConst THEN RETURN FALSE END;
        (* Enum members are declared by their NName node.  Expr marks each use as
           an enum literal for lowering, but constant evaluation must read the
           declaration itself: CASE validation runs after Expr on the use and
           the declaration node is intentionally not a lowered expression. *)
        D:=AST.Get(Sym.Decl); IF D.Kind=NName THEN V:=D.IntValue; RETURN TRUE END;
        IF D.Kind=NConst THEN RETURN ConstInteger(D.A,Scope,V) END; RETURN FALSE
    END;
    IF N.Kind=NUnary THEN
        K:=FromOrdinal(N.IntValue);
        IF K=TkMinus THEN
            D:=AST.Get(N.A);
            IF (D.Kind=NInteger) AND Equal(D.Text,'9223372036854775808') THEN V:=MinLong; RETURN TRUE END
        END;
        IF NOT ConstInteger(N.A,Scope,A) THEN RETURN FALSE END;
        IF K=TkMinus THEN IF A=MinLong THEN RETURN FALSE END; V:=-A; RETURN TRUE
        ELSIF K=TkPlus THEN V:=A; RETURN TRUE END; RETURN FALSE
    END;
    IF N.Kind=NBinary THEN
        K:=FromOrdinal(N.IntValue); IF NOT ConstInteger(N.A,Scope,A) OR NOT ConstInteger(N.B,Scope,B) THEN RETURN FALSE END;
        IF K=TkPlus THEN RETURN SafeAdd(A,B,V)
        ELSIF K=TkMinus THEN RETURN SafeSub(A,B,V)
        ELSIF K=TkStar THEN RETURN SafeMul(A,B,V)
        ELSIF K=KwDIV THEN RETURN SafeDivMod(A,B,V,Remainder)
        ELSIF K=KwMOD THEN RETURN SafeDivMod(A,B,Quotient,V)
        ELSIF (K=KwAND) OR (K=KwOR) OR (K=KwXOR) THEN RETURN SafeBitwise(A,B,K,V)
        ELSIF K=KwSHL THEN RETURN SafeShift(A,B,TRUE,V)
        ELSIF K=KwSHR THEN RETURN SafeShift(A,B,FALSE,V)
        END
    END;
    RETURN FALSE
END ConstInteger;

PROCEDURE AlignUp(N,A:CARDINAL):CARDINAL;
BEGIN IF A<=1 THEN RETURN N END; RETURN ((N+A-1) DIV A)*A END AlignUp;


PROCEDURE SymbolType(Id:SymbolId):TypeId;
VAR X:Symbol;
BEGIN X:=Symbols.Get(Id); RETURN X.TypeId END SymbolType;

PROCEDURE SymbolKindOf(Id:SymbolId):SymbolKind;
VAR X:Symbol;
BEGIN X:=Symbols.Get(Id); RETURN X.Kind END SymbolKindOf;

PROCEDURE FindModuleMember(ModuleNode:Node; Scope:ScopeId; Name:ARRAY OF CHAR; VAR Out:Interfaces.Member):BOOLEAN;
VAR S:SymbolId;
BEGIN
    IF ModuleNode.Kind#NName THEN RETURN FALSE END;
    S:=Lookup(Scope,ModuleNode.Text);
    IF (S=0) OR (SymbolKindOf(S)#SymModule) THEN RETURN FALSE END;
    RETURN Interfaces.FindVisible(CurrentModule,ModuleNode.Text,Name,Out)
END FindModuleMember;

PROCEDURE TypeKindOf(Id:TypeId):TypeKind;
VAR X:Type;
BEGIN IF Id=0 THEN RETURN TyInvalid END; X:=Types.Get(Id); RETURN X.Kind END TypeKindOf;

PROCEDURE CheckRange(ValueNode:NodeId; Target:TypeId; Scope:ScopeId);
VAR N,E:Node; T:Type; V:LONGINT; P:NodeId;
BEGIN
    IF (ValueNode=0) OR (Target=0) THEN RETURN END; T:=Types.Get(Target); IF T.Kind=TyDistinct THEN Target:=T.Base; IF Target=0 THEN RETURN END; T:=Types.Get(Target) END;
    IF T.Kind=TySet THEN
        N:=AST.Get(ValueNode); IF N.Kind#NSetLiteral THEN RETURN END; P:=N.A;
        WHILE P#0 DO
            E:=AST.Get(P);
            IF ConstInteger(P,Scope,V) AND ((V<T.Lo) OR (V>T.Hi)) THEN ErrCode(E,ERangeBounds,'set element is outside the target ordinal domain') END;
            P:=E.Next
        END;
        RETURN
    END;
    IF T.Kind#TyRange THEN RETURN END; N:=AST.Get(ValueNode); IF ConstInteger(ValueNode,Scope,V) AND ((V<T.Lo) OR (V>T.Hi)) THEN ErrCode(N,ERangeBounds,'constant value is outside the target range') END
END CheckRange;


PROCEDURE ContainsTypeByValue(Ty,Needle:TypeId):BOOLEAN;
VAR T:Type;
BEGIN
    IF (Ty=0) OR (Needle=0) THEN RETURN FALSE END;
    IF Ty=Needle THEN RETURN TRUE END;
    T:=Types.Get(Ty);
    CASE T.Kind OF
    | TyArray,TyRange,TyDistinct,TyAtomic: RETURN ContainsTypeByValue(T.Base,Needle)
    ELSE RETURN FALSE
    END
END ContainsTypeByValue;

PROCEDURE VariantTagAllowed(Ty:TypeId):BOOLEAN;
VAR T:Type;
BEGIN
    IF Ty=0 THEN RETURN FALSE END; T:=Types.Get(Ty);
    WHILE T.Kind=TyDistinct DO Ty:=T.Base; IF Ty=0 THEN RETURN FALSE END; T:=Types.Get(Ty) END;
    RETURN (T.Kind=TyEnum) OR (T.Kind=TyRange) OR (T.Kind=TyBoolean)
END VariantTagAllowed;

PROCEDURE VariantLabelType(Nid:NodeId; Scope:ScopeId):TypeId;
VAR N:Node; S:SymbolId;
BEGIN
    IF Nid=0 THEN RETURN 0 END; N:=AST.Get(Nid);
    IF N.Kind=NName THEN S:=Lookup(Scope,N.Text); IF S#0 THEN RETURN SymbolType(S) END
    ELSIF N.Kind=NInteger THEN RETURN Builtin('INTEGER')
    ELSIF N.Kind=NBoolean THEN RETURN Builtin('BOOLEAN')
    ELSIF N.Kind=NChar THEN RETURN Builtin('CHAR')
    ELSIF N.Kind=NUnary THEN RETURN VariantLabelType(N.A,Scope)
    END;
    RETURN 0
END VariantLabelType;

PROCEDURE RecordLayoutInto(N:Node; Scope:ScopeId; Kind:TypeKind; Existing:TypeId):TypeId;
VAR Ty,Id,TagTy,LabelTy:TypeId; Fld,Clause,Arm,Label:Node; T,FT,TagType:Type;
    P,Q,L:NodeId; Size,Align,Offset,UnionAlign,UnionBase,ArmEnd,MaxEnd,ArmNo,SeenCount,I:CARDINAL;
    Added:Layout.FieldId; Prior:Layout.Field; TagValue:LONGINT; SeenValues:ARRAY[0..1023] OF LONGINT; Duplicate:BOOLEAN;
BEGIN
    IF Existing=0 THEN Id:=NewType(Kind) ELSE Id:=Existing END;
    T:=Types.Get(Id); T.Kind:=Kind; T.Base:=0; Size:=0; Align:=1;
    IF N.A#0 THEN
        Ty:=ResolveType(N.A,Scope);
        IF Ty#0 THEN
            FT:=Types.Get(Ty);
            IF Ty=Id THEN ErrCode(N,ERecursiveValueType,'record cannot extend itself')
            ELSIF (FT.Kind#TyRecord) AND (FT.Kind#TyProtected) THEN ErrCode(N,EBadRecordBase,'record extension base must be a record')
            ELSE Size:=FT.Size; Align:=FT.Align; T.Base:=Ty
            END
        END
    END;
    P:=N.B;
    WHILE P#0 DO
        Fld:=AST.Get(P);
        IF (Fld.Kind=NField) OR (Fld.Kind=NVar) THEN
            Ty:=ResolveType(Fld.A,Scope);
            IF Ty#0 THEN
                IF ContainsTypeByValue(Ty,Id) THEN ErrCode(Fld,ERecursiveValueType,'record contains itself by value; use REF or POINTER TO for recursion')
                ELSE
                    FT:=Types.Get(Ty);
                    IF Layout.FindField(Id,Fld.Text,Prior) OR ((T.Base#0) AND Layout.FindField(T.Base,Fld.Text,Prior)) THEN ErrCode(Fld,EDuplicateDeclaration,'record field is already declared')
                    ELSE
                        IF FT.Align>Align THEN Align:=FT.Align END;
                        Size:=AlignUp(Size,FT.Align); Offset:=Size; Added:=Layout.AddField(Id,Fld.Text,Ty,Offset,FT.Size,FT.Align,Fld.Flags); IF Added=0 THEN RETURN 0 END; INC(Size,FT.Size)
                    END
                END
            END
        END;
        P:=Fld.Next
    END;
    P:=N.C;
    WHILE P#0 DO
        Fld:=AST.Get(P); Ty:=ResolveType(Fld.A,Scope);
        IF Ty#0 THEN
            IF ContainsTypeByValue(Ty,Id) THEN ErrCode(Fld,ERecursiveValueType,'record contains itself by value; use REF or POINTER TO for recursion')
            ELSE
                FT:=Types.Get(Ty);
                IF Layout.FindField(Id,Fld.Text,Prior) OR ((T.Base#0) AND Layout.FindField(T.Base,Fld.Text,Prior)) THEN ErrCode(Fld,EDuplicateDeclaration,'record field is already declared')
                ELSE
                    IF FT.Align>Align THEN Align:=FT.Align END; Size:=AlignUp(Size,FT.Align); Offset:=Size;
                    Added:=Layout.AddField(Id,Fld.Text,Ty,Offset,FT.Size,FT.Align,Fld.Flags+{0}); IF Added=0 THEN RETURN 0 END; INC(Size,FT.Size)
                END
            END
        END;
        P:=Fld.Next
    END;
    IF N.D#0 THEN
        Clause:=AST.Get(N.D); TagTy:=ResolveType(Clause.A,Scope); IF N.D<=MaxTypedNodes THEN NodeTypes[N.D]:=TagTy END;
        IF (TagTy#0) AND NOT VariantTagAllowed(TagTy) THEN ErrCode(Clause,EInvalidTypeExpression,'variant record tag must be BOOLEAN, an enumeration, or a range') END;
        IF TagTy#0 THEN
            TagType:=Types.Get(TagTy);
            IF Layout.FindField(Id,Clause.Text,Prior) OR ((T.Base#0) AND Layout.FindField(T.Base,Clause.Text,Prior)) THEN ErrCode(Clause,EDuplicateDeclaration,'variant tag field is already declared')
            ELSE
                IF TagType.Align>Align THEN Align:=TagType.Align END; Size:=AlignUp(Size,TagType.Align); Offset:=Size;
                Added:=Layout.AddField(Id,Clause.Text,TagTy,Offset,TagType.Size,TagType.Align,{}); IF Added=0 THEN RETURN 0 END; INC(Size,TagType.Size)
            END
        END;
        UnionAlign:=1; SeenCount:=0; P:=Clause.B;
        WHILE P#0 DO
            Arm:=AST.Get(P); L:=Arm.A;
            WHILE L#0 DO
                Label:=AST.Get(L); LabelTy:=VariantLabelType(L,Scope); IF L<=MaxTypedNodes THEN NodeTypes[L]:=LabelTy END;
                IF (TagTy#0) AND (LabelTy#0) AND NOT Compatible(TagTy,LabelTy) THEN ErrCode(Label,EIncompatibleOperands,'variant label does not match the tag type') END;
                IF NOT ConstInteger(L,Scope,TagValue) THEN ErrCode(Label,EInvalidTypeExpression,'variant label must be an ordinal constant')
                ELSE
                    IF (TagTy#0) AND ((TagValue<TagType.Lo) OR (TagValue>TagType.Hi)) THEN ErrCode(Label,ERangeBounds,'variant label is outside the tag type') END;
                    Duplicate:=FALSE; I:=0; WHILE I<SeenCount DO IF SeenValues[I]=TagValue THEN Duplicate:=TRUE END; INC(I) END;
                    IF Duplicate THEN ErrCode(Label,EDuplicateDeclaration,'variant label is already used by another arm')
                    ELSIF SeenCount>HIGH(SeenValues) THEN ErrCode(Label,EInvalidTypeExpression,'variant record has too many labels')
                    ELSE SeenValues[SeenCount]:=TagValue; INC(SeenCount)
                    END
                END;
                L:=Label.Next
            END;
            Q:=Arm.B;
            WHILE Q#0 DO
                Fld:=AST.Get(Q); Ty:=ResolveType(Fld.A,Scope); IF Q<=MaxTypedNodes THEN NodeTypes[Q]:=Ty END;
                IF Ty#0 THEN
                    IF ContainsTypeByValue(Ty,Id) THEN ErrCode(Fld,ERecursiveValueType,'variant field contains its record by value; use REF or POINTER TO')
                    ELSE FT:=Types.Get(Ty); IF FT.Align>UnionAlign THEN UnionAlign:=FT.Align END
                    END
                END;
                Q:=Fld.Next
            END;
            P:=Arm.Next
        END;
        IF UnionAlign>Align THEN Align:=UnionAlign END; UnionBase:=AlignUp(Size,UnionAlign); MaxEnd:=UnionBase; ArmNo:=0; P:=Clause.B;
        WHILE P#0 DO
            INC(ArmNo); Arm:=AST.Get(P); Offset:=UnionBase; Q:=Arm.B;
            WHILE Q#0 DO
                Fld:=AST.Get(Q); Ty:=NodeTypes[Q];
                IF Ty#0 THEN
                    FT:=Types.Get(Ty); Offset:=AlignUp(Offset,FT.Align);
                    IF Layout.FindField(Id,Fld.Text,Prior) OR ((T.Base#0) AND Layout.FindField(T.Base,Fld.Text,Prior)) THEN ErrCode(Fld,EDuplicateDeclaration,'variant field name is already declared in this record')
                    ELSE
                        Added:=Layout.AddVariantField(Id,Fld.Text,Ty,Offset,FT.Size,FT.Align,ArmNo,Clause.Text,Fld.Flags); IF Added=0 THEN RETURN 0 END;
                        L:=Arm.A; WHILE L#0 DO Label:=AST.Get(L); IF ConstInteger(L,Scope,TagValue) THEN Layout.AddVariantTag(Added,TagValue) END; L:=Label.Next END;
                        INC(Offset,FT.Size)
                    END
                END;
                Q:=Fld.Next
            END;
            ArmEnd:=Offset; IF ArmEnd>MaxEnd THEN MaxEnd:=ArmEnd END; P:=Arm.Next
        END;
        Size:=MaxEnd
    END;
    T.Size:=AlignUp(Size,Align); T.Align:=Align; Types.Put(Id,T); RETURN Id
END RecordLayoutInto;

PROCEDURE RecordLayout(N:Node; Scope:ScopeId; Kind:TypeKind):TypeId;
BEGIN RETURN RecordLayoutInto(N,Scope,Kind,0) END RecordLayout;

PROCEDURE RangeBaseAllowed(Id:TypeId):BOOLEAN;
VAR T:Type; K:TypeKind;
BEGIN
    IF Id=0 THEN RETURN FALSE END; T:=Types.Get(Id);
    WHILE (T.Kind=TyRange) OR (T.Kind=TyDistinct) DO Id:=T.Base; IF Id=0 THEN RETURN FALSE END; T:=Types.Get(Id) END;
    K:=T.Kind;
    RETURN (K=TyByte) OR ((K>=TyI8) AND (K<=TySize)) OR (K=TyChar) OR (K=TyEnum)
END RangeBaseAllowed;

PROCEDURE OrdinalBoundFits(Id:TypeId; Value:LONGINT):BOOLEAN;
VAR T:Type; K:TypeKind;
BEGIN
    IF Id=0 THEN RETURN FALSE END; T:=Types.Get(Id);
    WHILE (T.Kind=TyRange) OR (T.Kind=TyDistinct) DO Id:=T.Base; IF Id=0 THEN RETURN FALSE END; T:=Types.Get(Id) END;
    K:=T.Kind;
    IF K=TyEnum THEN RETURN (Value>=T.Lo) AND (Value<=T.Hi) END;
    IF K=TyChar THEN RETURN (Value>=0) AND (Value<=1114111) END;
    IF (K=TyByte) OR (K=TyU8) THEN RETURN (Value>=0) AND (Value<=255) END;
    IF K=TyU16 THEN RETURN (Value>=0) AND (Value<=65535) END;
    IF K=TyU32 THEN RETURN (Value>=0) AND (Value<=4294967295) END;
    IF (K=TyU64) OR (K=TyCardinal) OR (K=TySize) THEN RETURN Value>=0 END;
    IF K=TyI8 THEN RETURN (Value>=-128) AND (Value<=127) END;
    IF K=TyI16 THEN RETURN (Value>=-32768) AND (Value<=32767) END;
    IF K=TyI32 THEN RETURN (Value>=-2147483647-1) AND (Value<=2147483647) END;
    RETURN (K=TyI64) OR (K=TyInteger)
END OrdinalBoundFits;

PROCEDURE DistinctBaseAllowed(Id:TypeId):BOOLEAN;
VAR T:Type; K:TypeKind;
BEGIN
    IF Id=0 THEN RETURN FALSE END; T:=Types.Get(Id);
    WHILE (T.Kind=TyRange) OR (T.Kind=TyDistinct) DO Id:=T.Base; IF Id=0 THEN RETURN FALSE END; T:=Types.Get(Id) END;
    K:=T.Kind;
    RETURN (K=TyBoolean) OR (K=TyChar) OR (K=TyByte) OR
           ((K>=TyI8) AND (K<=TyR64)) OR (K=TyString) OR (K=TyCString) OR
           (K=TyPointer) OR (K=TyRef) OR (K=TyEnum)
END DistinctBaseAllowed;

PROCEDURE AtomicBaseAllowed(Id:TypeId):BOOLEAN;
VAR T:Type; K:TypeKind;
BEGIN
    IF Id=0 THEN RETURN FALSE END; T:=Types.Get(Id); K:=T.Kind;
    IF K=TyByte THEN RETURN TRUE END;
    RETURN (K>=TyI8) AND (K<=TySize)
END AtomicBaseAllowed;

PROCEDURE SetBaseBounds(Id:TypeId; VAR Lo,Hi:LONGINT):BOOLEAN;
VAR T:Type;
BEGIN
    IF Id=0 THEN RETURN FALSE END; T:=Types.Get(Id);
    WHILE T.Kind=TyDistinct DO Id:=T.Base; IF Id=0 THEN RETURN FALSE END; T:=Types.Get(Id) END;
    IF T.Kind=TyRange THEN Lo:=T.Lo; Hi:=T.Hi
    ELSIF T.Kind=TyEnum THEN Lo:=T.Lo; Hi:=T.Hi
    ELSIF T.Kind=TyBoolean THEN Lo:=0; Hi:=1
    ELSE RETURN FALSE
    END;
    RETURN (Lo>=0) AND (Lo<=Hi) AND (Hi<=63)
END SetBaseBounds;

PROCEDURE ResolveType(Nid:NodeId; Scope:ScopeId):TypeId;
VAR N,A:Node; S:SymbolId; T,BT:Type; I,Base:TypeId; IM:Interfaces.Member; PArg:NodeId; ActualCount:CARDINAL; Actuals:Generics.ActualArray;
BEGIN
    IF Nid=0 THEN RETURN Builtin('VOID') END; N:=AST.Get(Nid);
    CASE N.Kind OF
    | NResolvedType: RETURN VAL(TypeId,N.IntValue)
    | NNamedType:
        IF (N.A#0) AND (0 IN N.Flags) THEN
            Base:=ResolveType(N.A,Scope); I:=NewType(TyDistinct); T:=Types.Get(I); T.Base:=Base;
            IF Base#0 THEN
                BT:=Types.Get(Base); T.Size:=BT.Size; T.Align:=BT.Align;
                IF NOT DistinctBaseAllowed(Base) THEN ErrCode(N,EInvalidTypeExpression,'DISTINCT requires a scalar base type') END
            END;
            Types.Put(I,T); RETURN I
        END;
        I:=Builtin(N.Text); IF I#0 THEN RETURN I END;
        IF Interfaces.FindQualifiedVisible(CurrentModule,N.Text,IM) AND (IM.Kind=Interfaces.MemberType) THEN RETURN IM.TypeId END;
        S:=Lookup(Scope,N.Text); IF S=0 THEN ErrCode(N,EUnknownType,'unknown type'); RETURN 0 END; RETURN SymbolType(S)
    | NPointerType:
        I:=NewType(TyPointer); T:=Types.Get(I); T.Base:=ResolveType(N.A,Scope); T.Size:=8; T.Align:=8; Types.Put(I,T); RETURN I
    | NRefType:
        I:=NewType(TyRef); T:=Types.Get(I); T.Base:=ResolveType(N.A,Scope); T.Size:=8; T.Align:=8; Types.Put(I,T); RETURN I
    | NSliceType:
        I:=NewType(TySlice); T:=Types.Get(I); T.Base:=ResolveType(N.A,Scope); T.Size:=16; T.Align:=8; Types.Put(I,T); RETURN I
    | NSetType:
        I:=NewType(TySet); T:=Types.Get(I); T.Base:=ResolveType(N.A,Scope); T.Size:=8; T.Align:=8;
        IF (T.Base#0) AND NOT SetBaseBounds(T.Base,T.Lo,T.Hi) THEN ErrCode(N,EInvalidTypeExpression,'SET OF requires BOOLEAN, an enumeration, or a range whose ordinal values fit 0..63') END;
        Types.Put(I,T); RETURN I
    | NArrayType:
        I:=NewType(TyArray); T:=Types.Get(I); T.Base:=ResolveType(N.B,Scope); T.Align:=1;
        IF T.Base#0 THEN BT:=Types.Get(T.Base); T.Align:=BT.Align; T.Size:=BT.Size END;
        IF N.A=0 THEN ErrCode(N,EInvalidTypeExpression,'ARRAY needs a fixed positive element count; use SLICE OF for a view')
        ELSIF NOT ConstInteger(N.A,Scope,T.Lo) THEN ErrCode(N,EInvalidTypeExpression,'ARRAY element count must be an integer constant')
        ELSIF T.Lo<=0 THEN ErrCode(N,EInvalidTypeExpression,'ARRAY element count must be positive')
        ELSE T.Size:=T.Size*VAL(CARDINAL,T.Lo)
        END;
        Types.Put(I,T); RETURN I
    | NRangeType:
        I:=NewType(TyRange); T:=Types.Get(I); T.Base:=ResolveType(N.A,Scope);
        IF T.Base#0 THEN BT:=Types.Get(T.Base); T.Size:=BT.Size; T.Align:=BT.Align; IF NOT RangeBaseAllowed(T.Base) THEN ErrCode(N,EInvalidTypeExpression,'RANGE base type must be ordinal') END END;
        IF NOT ConstInteger(N.B,Scope,T.Lo) THEN ErrCode(N,EInvalidTypeExpression,'RANGE lower bound must be an integer constant')
        ELSIF (T.Base#0) AND NOT OrdinalBoundFits(T.Base,T.Lo) THEN ErrCode(N,ERangeBounds,'RANGE lower bound is outside its base type') END;
        IF NOT ConstInteger(N.C,Scope,T.Hi) THEN ErrCode(N,EInvalidTypeExpression,'RANGE upper bound must be an integer constant')
        ELSIF (T.Base#0) AND NOT OrdinalBoundFits(T.Base,T.Hi) THEN ErrCode(N,ERangeBounds,'RANGE upper bound is outside its base type') END;
        IF T.Lo>T.Hi THEN ErrCode(N,ERangeBounds,'range lower bound is greater than upper bound') END; Types.Put(I,T); RETURN I
    | NRecordType: RETURN RecordLayout(N,Scope,TyRecord)
    | NProtectedType: RETURN RecordLayout(N,Scope,TyProtected)
    | NEnumType:
        I:=NewType(TyEnum); T:=Types.Get(I); T.Size:=4; T.Align:=4; T.Lo:=0; T.Hi:=-1; A:=AST.Get(N.A); Base:=N.A;
        WHILE Base#0 DO INC(T.Hi); A:=AST.Get(Base); Base:=A.Next END;
        Types.Put(I,T); RETURN I
    | NVariantType:
        I:=NewType(TyVariant); T:=Types.Get(I); T.Size:=16; T.Align:=8; Types.Put(I,T); RETURN I
    | NProcedureType:
        I:=NewType(TyProcedure); T:=Types.Get(I); T.Result:=ResolveType(N.B,Scope); T.Size:=8; T.Align:=8; Types.Put(I,T);
        Signatures.BeginProcedure(I); A:=AST.Get(N.A);
        Base:=N.A;
        WHILE Base#0 DO A:=AST.Get(Base); Signatures.AddParameter(I,ResolveType(A.A,Scope),0 IN A.Flags); Base:=A.Next END;
        RETURN I
    | NGenericType:
        IF Equal(N.Text,'ATOMIC') THEN
            I:=NewType(TyAtomic); T:=Types.Get(I); T.Base:=ResolveType(N.A,Scope); T.Size:=8; T.Align:=8;
            IF T.Base#0 THEN
                BT:=Types.Get(T.Base); T.Size:=BT.Size; T.Align:=BT.Align;
                IF NOT AtomicBaseAllowed(T.Base) OR ((T.Size#1) AND (T.Size#2) AND (T.Size#4) AND (T.Size#8)) THEN
                    ErrCode(N,EInvalidTypeExpression,'ATOMIC requires a 1, 2, 4, or 8 byte integer type')
                END
            END;
            Types.Put(I,T); RETURN I
        END;
        Base:=0; I:=Builtin(N.Text); IF I#0 THEN Base:=I END;
        IF (Base=0) AND Interfaces.FindQualifiedVisible(CurrentModule,N.Text,IM) AND (IM.Kind=Interfaces.MemberType) THEN Base:=IM.TypeId END;
        IF Base=0 THEN S:=Lookup(Scope,N.Text); IF S#0 THEN Base:=SymbolType(S) END END;
        IF Base=0 THEN ErrCode(N,EUnknownType,'unknown generic type'); RETURN 0 END;
        ActualCount:=0; PArg:=N.A; WHILE (PArg#0) AND (ActualCount<Generics.MaxGenericParams) DO Actuals[ActualCount]:=ResolveType(PArg,Scope); INC(ActualCount); A:=AST.Get(PArg); PArg:=A.Next END;
        IF PArg#0 THEN ErrCode(N,EGenericArity,'too many generic type arguments'); RETURN 0 END;
        RETURN Generics.Instantiate(Base,Actuals,ActualCount)
    ELSE ErrCode(N,EInvalidTypeExpression,'invalid type expression'); RETURN 0
    END
END ResolveType;

PROCEDURE GenericActualType(Nid:NodeId; Scope:ScopeId):TypeId;
VAR N,B:Node; S:SymbolId; Base:TypeId; IM:Interfaces.Member; P:NodeId; Count:CARDINAL; Actuals:Generics.ActualArray;
BEGIN
    IF Nid=0 THEN RETURN 0 END; N:=AST.Get(Nid);
    IF N.Kind=NResolvedType THEN RETURN VAL(TypeId,N.IntValue) END;
    IF N.Kind=NName THEN
        Base:=Builtin(N.Text); IF Base#0 THEN RETURN Base END; S:=Lookup(Scope,N.Text); IF (S#0) AND (SymbolKindOf(S)=SymType) THEN RETURN SymbolType(S) END;
        ErrCode(N,EUnknownType,'unknown generic procedure type argument'); RETURN 0
    ELSIF N.Kind=NSelect THEN
        B:=AST.Get(N.A); IF FindModuleMember(B,Scope,N.Text,IM) AND (IM.Kind=Interfaces.MemberType) THEN RETURN IM.TypeId END;
        ErrCode(N,EUnknownType,'generic procedure type argument is not an exported type'); RETURN 0
    ELSIF N.Kind=NIndex THEN
        Base:=GenericActualType(N.A,Scope); IF (Base=0) OR NOT Generics.IsTemplate(Base) THEN ErrCode(N,EInvalidTypeExpression,'generic type argument base is not a generic type'); RETURN 0 END;
        Count:=0; P:=N.B; WHILE (P#0) AND (Count<Generics.MaxGenericParams) DO Actuals[Count]:=GenericActualType(P,Scope); INC(Count); B:=AST.Get(P); P:=B.Next END;
        IF P#0 THEN ErrCode(N,EGenericArity,'too many nested generic type arguments'); RETURN 0 END;
        RETURN Generics.Instantiate(Base,Actuals,Count)
    END;
    ErrCode(N,EInvalidTypeExpression,'generic procedure arguments must be named types'); RETURN 0
END GenericActualType;

PROCEDURE ResolveGenericProcedure(Nid:NodeId; Scope:ScopeId):TypeId;
VAR N,BaseNode,ModuleNode,Arg:Node; S:SymbolId; Template,Specialized:TypeId; IM:Interfaces.Member;
    Owner,Name,Link,SpecializedLink:Text; Actuals:Generics.ActualArray; Count:CARDINAL; P:NodeId;
BEGIN
    IF Nid=0 THEN RETURN 0 END; N:=AST.Get(Nid); IF N.Kind#NIndex THEN RETURN 0 END; BaseNode:=AST.Get(N.A); Template:=0;
    IF BaseNode.Kind=NName THEN
        S:=Lookup(Scope,BaseNode.Text);
        IF (S#0) AND (SymbolKindOf(S)=SymProc) THEN Template:=SymbolType(S); Assign(Name,BaseNode.Text);
            IF Interfaces.FindSelective(CurrentModule,BaseNode.Text,IM) THEN Assign(Owner,IM.Module); Assign(Name,IM.Name); Assign(Link,IM.LinkName)
            ELSE Assign(Owner,CurrentModule); Assign(Link,CurrentModule); Append(Link,'__'); Append(Link,BaseNode.Text)
            END
        END
    ELSIF BaseNode.Kind=NSelect THEN
        ModuleNode:=AST.Get(BaseNode.A);
        IF FindModuleMember(ModuleNode,Scope,BaseNode.Text,IM) AND (IM.Kind=Interfaces.MemberProcedure) THEN Template:=IM.TypeId; Assign(Owner,IM.Module); Assign(Name,IM.Name); Assign(Link,IM.LinkName) END
    END;
    IF (Template=0) OR NOT Generics.IsTemplate(Template) THEN RETURN 0 END;
    N.Flags:=N.Flags+{6}; AST.Put(Nid,N); Count:=0; P:=N.B;
    WHILE (P#0) AND (Count<Generics.MaxGenericParams) DO Actuals[Count]:=GenericActualType(P,Scope); INC(Count); Arg:=AST.Get(P); P:=Arg.Next END;
    IF P#0 THEN ErrCode(N,EGenericArity,'too many generic procedure type arguments'); RETURN 0 END;
    IF Count#Generics.ParameterCount(Template) THEN ErrCode(N,EGenericArity,'wrong number of generic procedure type arguments'); RETURN 0 END;
    Specialized:=Generics.Instantiate(Template,Actuals,Count); GenericProcedures.Request(Owner,Name,Link,Actuals,Count,SpecializedLink);
    N:=AST.Get(Nid); Assign(N.Text,SpecializedLink); AST.Put(Nid,N); IF Nid<=MaxTypedNodes THEN NodeTypes[Nid]:=Specialized END; RETURN Specialized
END ResolveGenericProcedure;


PROCEDURE CalleeType(Nid:NodeId; Scope:ScopeId):TypeId;
VAR N,B:Node; S:SymbolId; BT:TypeId; T:Type; IM:Interfaces.Member;
BEGIN
    IF Nid=0 THEN RETURN 0 END; N:=AST.Get(Nid);
    IF N.Kind=NName THEN
        S:=Lookup(Scope,N.Text); IF S#0 THEN RETURN SymbolType(S) END
    ELSIF N.Kind=NSelect THEN
        B:=AST.Get(N.A);
        IF FindModuleMember(B,Scope,N.Text,IM) THEN RETURN IM.TypeId END;
        BT:=Expr(Nid,Scope); IF BT#0 THEN T:=Types.Get(BT); IF T.Kind=TyProcedure THEN RETURN BT END END
    ELSIF N.Kind=NIndex THEN
        BT:=ResolveGenericProcedure(Nid,Scope); IF BT#0 THEN RETURN BT END; N:=AST.Get(Nid); IF 6 IN N.Flags THEN RETURN 0 END;
        BT:=Expr(Nid,Scope); IF BT#0 THEN T:=Types.Get(BT); IF T.Kind=TyProcedure THEN RETURN BT END END
    ELSIF N.Kind=NDeref THEN
        BT:=Expr(Nid,Scope); IF BT#0 THEN T:=Types.Get(BT); IF T.Kind=TyProcedure THEN RETURN BT END END
    END;
    RETURN 0
END CalleeType;

PROCEDURE IsAddressable(Nid:NodeId; Scope:ScopeId):BOOLEAN;
VAR N,B:Node; S:SymbolId; IM:Interfaces.Member; Ty:TypeId; T:Type;
BEGIN
    IF Nid=0 THEN RETURN FALSE END; N:=AST.Get(Nid);
    CASE N.Kind OF
    | NName:
        S:=Lookup(Scope,N.Text); IF S=0 THEN RETURN FALSE END; RETURN (SymbolKindOf(S)=SymVar) OR (SymbolKindOf(S)=SymParam)
    | NSelect:
        B:=AST.Get(N.A);
        IF B.Kind=NName THEN
            S:=Lookup(Scope,B.Text);
            IF (S#0) AND (SymbolKindOf(S)=SymModule) THEN RETURN FindModuleMember(B,Scope,N.Text,IM) AND (IM.Kind=Interfaces.MemberVar) END
        END;
        Ty:=Expr(N.A,Scope); IF Ty#0 THEN T:=Types.Get(Ty); IF (T.Kind=TyPointer) OR (T.Kind=TyRef) THEN RETURN TRUE END END;
        RETURN IsAddressable(N.A,Scope)
    | NIndex:
        IF IsAddressable(N.A,Scope) THEN RETURN TRUE END;
        Ty:=Expr(N.A,Scope); RETURN (TypeKindOf(Ty)=TyPointer) OR (TypeKindOf(Ty)=TyRef) OR (TypeKindOf(Ty)=TySlice)
    | NDeref: RETURN TRUE
    ELSE RETURN FALSE
    END
END IsAddressable;

PROCEDURE SameValueType(Expected,Actual:TypeId):BOOLEAN;
VAR E,AType:Type; I:CARDINAL;
BEGIN
    IF Expected=Actual THEN RETURN TRUE END;
    IF (Expected=0) OR (Actual=0) THEN RETURN FALSE END;
    E:=Types.Get(Expected); AType:=Types.Get(Actual);
    IF (E.Kind=TyProcedure) AND (AType.Kind=TyProcedure) THEN
        IF Signatures.IsVariadic(Expected)#Signatures.IsVariadic(Actual) THEN RETURN FALSE END;
        IF Signatures.ParameterCount(Expected)#Signatures.ParameterCount(Actual) THEN RETURN FALSE END;
        IF NOT SameValueType(E.Result,AType.Result) THEN RETURN FALSE END;
        I:=0; WHILE I<Signatures.ParameterCount(Expected) DO
            IF Signatures.ParameterByRef(Expected,I)#Signatures.ParameterByRef(Actual,I) THEN RETURN FALSE END;
            IF NOT SameValueType(Signatures.ParameterType(Expected,I),Signatures.ParameterType(Actual,I)) THEN RETURN FALSE END;
            INC(I)
        END;
        RETURN TRUE
    END;
    RETURN Compatible(Expected,Actual)
END SameValueType;

PROCEDURE PlainIntegerShape(Id:TypeId; VAR Signed:BOOLEAN; VAR Bytes:CARDINAL):BOOLEAN;
VAR T:Type; K:TypeKind;
BEGIN
    IF Id=0 THEN RETURN FALSE END; T:=Types.Get(Id); K:=T.Kind;
    IF K=TyRange THEN RETURN PlainIntegerShape(T.Base,Signed,Bytes) END;
    IF K=TyByte THEN Signed:=FALSE; Bytes:=1; RETURN TRUE END;
    IF ((K>=TyI8) AND (K<=TyI64)) OR (K=TyInteger) THEN Signed:=TRUE; Bytes:=T.Size; RETURN TRUE END;
    IF ((K>=TyU8) AND (K<=TyU64)) OR (K=TyCardinal) OR (K=TySize) THEN Signed:=FALSE; Bytes:=T.Size; RETURN TRUE END;
    RETURN FALSE
END PlainIntegerShape;

PROCEDURE FitsPlainInteger(Target:TypeId; Value:LONGINT):BOOLEAN;
VAR T:Type; Signed:BOOLEAN; Bytes:CARDINAL;
BEGIN
    IF Target=0 THEN RETURN FALSE END; T:=Types.Get(Target);
    IF T.Kind=TyRange THEN RETURN (Value>=T.Lo) AND (Value<=T.Hi) END;
    IF NOT PlainIntegerShape(Target,Signed,Bytes) THEN RETURN FALSE END;
    IF Signed THEN
        CASE Bytes OF
        | 1:RETURN (Value>=-128) AND (Value<=127)
        | 2:RETURN (Value>=-32768) AND (Value<=32767)
        | 4:RETURN (Value>=-2147483647-1) AND (Value<=2147483647)
        ELSE RETURN TRUE
        END
    END;
    IF Value<0 THEN RETURN FALSE END;
    CASE Bytes OF
    | 1:RETURN Value<=255
    | 2:RETURN Value<=65535
    | 4:RETURN Value<=4294967295
    ELSE RETURN TRUE
    END
END FitsPlainInteger;

PROCEDURE ImplicitIntegerCompatible(Expected,Actual:TypeId; ValueNode:NodeId; Scope:ScopeId):BOOLEAN;
VAR E,A:Type; ESigned,ASigned:BOOLEAN; EBytes,ABytes:CARDINAL; UnsignedValue:LONGCARD; V:LONGINT; N:Node;
BEGIN
    IF (Expected=0) OR (Actual=0) THEN RETURN FALSE END; E:=Types.Get(Expected); A:=Types.Get(Actual);
    IF (ValueNode#0) AND PlainIntegerShape(Expected,ESigned,EBytes) AND NOT ESigned AND (EBytes=8) THEN
        N:=AST.Get(ValueNode); IF ((N.Kind=NInteger) OR (7 IN N.Flags)) AND TryParseCardinal(N.Text,UnsignedValue) THEN RETURN TRUE END
    END;
    IF (ValueNode#0) AND ConstInteger(ValueNode,Scope,V) THEN RETURN FitsPlainInteger(Expected,V) END;
    (* A range entry is checked before conversion in lowering.  It is useful
       precisely because a full-width dynamic value may enter a smaller domain
       without silently wrapping first. *)
    IF E.Kind=TyRange THEN RETURN Compatible(E.Base,Actual) END;
    IF A.Kind=TyRange THEN RETURN FitsPlainInteger(Expected,A.Lo) AND FitsPlainInteger(Expected,A.Hi) END;
    IF NOT PlainIntegerShape(Expected,ESigned,EBytes) OR NOT PlainIntegerShape(Actual,ASigned,ABytes) THEN RETURN FALSE END;
    IF ESigned=ASigned THEN RETURN EBytes>=ABytes END;
    IF ESigned AND NOT ASigned THEN RETURN EBytes>ABytes END;
    RETURN FALSE
END ImplicitIntegerCompatible;

PROCEDURE ValueCompatible(Expected,Actual:TypeId; ValueNode:NodeId; Scope:ScopeId):BOOLEAN;
VAR E,AType:Type; N:Node; ExpectedSigned,ActualSigned:BOOLEAN; ExpectedBytes,ActualBytes:CARDINAL;
BEGIN
    IF (Expected=0) OR (Actual=0) THEN RETURN FALSE END;
    E:=Types.Get(Expected);
    IF (TypeKindOf(Actual)=TyAddress) AND (ValueNode#0) THEN
        N:=AST.Get(ValueNode);
        IF (N.Kind=NNil) AND ((E.Kind=TyPointer) OR (E.Kind=TyRef) OR
           (E.Kind=TyAddress) OR (E.Kind=TyString) OR (E.Kind=TyCString) OR (E.Kind=TyProcedure)) THEN RETURN TRUE END
    END;
    (* ADDRESS does not implicitly transfer ownership into REF.
       NIL is the one exception.  Raw addresses can still become REF through
       an explicit conversion inside low-level code. *)
    IF (E.Kind=TyRef) AND (TypeKindOf(Actual)=TyAddress) THEN
        IF ValueNode=0 THEN RETURN FALSE END; N:=AST.Get(ValueNode); RETURN N.Kind=NNil
    END;
    IF (E.Kind=TySlice) AND (TypeKindOf(Actual)=TyArray) THEN AType:=Types.Get(Actual); RETURN Compatible(E.Base,AType.Base) END;
    IF PlainIntegerShape(Expected,ExpectedSigned,ExpectedBytes) AND PlainIntegerShape(Actual,ActualSigned,ActualBytes) THEN
        RETURN ImplicitIntegerCompatible(Expected,Actual,ValueNode,Scope)
    END;
    RETURN SameValueType(Expected,Actual)
END ValueCompatible;

PROCEDURE ContextualIntegerOperands(LeftNode,RightNode:NodeId; VAR LeftTy,RightTy:TypeId; Scope:ScopeId);
VAR Value:LONGINT; LeftSigned,RightSigned:BOOLEAN; LeftBytes,RightBytes:CARDINAL;
BEGIN
    IF (LeftTy=0) OR (RightTy=0) OR (LeftTy=RightTy) THEN RETURN END;
    IF NOT PlainIntegerShape(LeftTy,LeftSigned,LeftBytes) OR NOT PlainIntegerShape(RightTy,RightSigned,RightBytes) THEN RETURN END;
    IF ConstInteger(LeftNode,Scope,Value) AND FitsPlainInteger(RightTy,Value) THEN
        LeftTy:=RightTy; IF LeftNode<=MaxTypedNodes THEN NodeTypes[LeftNode]:=RightTy END
    ELSIF ConstInteger(RightNode,Scope,Value) AND FitsPlainInteger(LeftTy,Value) THEN
        RightTy:=LeftTy; IF RightNode<=MaxTypedNodes THEN NodeTypes[RightNode]:=LeftTy END
    END
END ContextualIntegerOperands;

PROCEDURE RawToManaged(Expected,Actual:TypeId; ValueNode:NodeId):BOOLEAN;
VAR N:Node;
BEGIN
    IF (Expected=0) OR (Actual=0) THEN RETURN FALSE END;
    IF (TypeKindOf(Expected)#TyRef) OR (TypeKindOf(Actual)#TyAddress) THEN RETURN FALSE END;
    IF ValueNode#0 THEN N:=AST.Get(ValueNode); IF N.Kind=NNil THEN RETURN FALSE END END;
    RETURN TRUE
END RawToManaged;

PROCEDURE ScalarKindOf(Id:TypeId):TypeKind;
VAR T:Type;
BEGIN
    IF Id=0 THEN RETURN TyInvalid END; T:=Types.Get(Id);
    WHILE (T.Kind=TyRange) OR (T.Kind=TyDistinct) DO Id:=T.Base; IF Id=0 THEN RETURN TyInvalid END; T:=Types.Get(Id) END;
    RETURN T.Kind
END ScalarKindOf;

PROCEDURE ArithmeticInteger(Id:TypeId):BOOLEAN;
VAR K:TypeKind;
BEGIN
    K:=ScalarKindOf(Id);
    RETURN (K=TyByte) OR ((K>=TyI8) AND (K<=TySize))
END ArithmeticInteger;

PROCEDURE ArithmeticNumeric(Id:TypeId):BOOLEAN;
VAR K:TypeKind;
BEGIN
    K:=ScalarKindOf(Id); RETURN ArithmeticInteger(Id) OR (K=TyR32) OR (K=TyR64)
END ArithmeticNumeric;

PROCEDURE OrderedScalar(Id:TypeId):BOOLEAN;
VAR K:TypeKind;
BEGIN
    K:=ScalarKindOf(Id); RETURN ArithmeticNumeric(Id) OR (K=TyChar) OR (K=TyEnum)
END OrderedScalar;

PROCEDURE ConversionAllowed(ToTy,FromTy:TypeId):BOOLEAN;
VAR TK,FK:TypeKind;
BEGIN
    IF (ToTy=0) OR (FromTy=0) THEN RETURN FALSE END; IF ToTy=FromTy THEN RETURN TRUE END;
    TK:=ScalarKindOf(ToTy); FK:=ScalarKindOf(FromTy);
    IF Types.IsNumeric(ToTy) AND Types.IsNumeric(FromTy) THEN RETURN TRUE END;
    IF (TK=TyBoolean) OR (FK=TyBoolean) THEN RETURN (TK=TyBoolean) AND (FK=TyBoolean) END;
    IF ((TK=TyPointer) OR (TK=TyRef)) AND ((FK=TyPointer) OR (FK=TyRef) OR (FK=TyAddress)) THEN RETURN TRUE END;
    IF ((FK=TyPointer) OR (FK=TyRef)) AND (TK=TyAddress) THEN RETURN TRUE END;
    IF ((TK=TyString) OR (TK=TyCString)) AND ((FK=TyString) OR (FK=TyCString) OR (FK=TyAddress)) THEN RETURN TRUE END;
    IF ((FK=TyString) OR (FK=TyCString)) AND (TK=TyAddress) THEN RETURN TRUE END;
    IF (TypeKindOf(ToTy)=TySet) AND (TypeKindOf(FromTy)=TySet) THEN RETURN Compatible(ToTy,FromTy) END;
    RETURN FALSE
END ConversionAllowed;

PROCEDURE EqualityScalar(Ty:TypeId):BOOLEAN;
VAR K:TypeKind;
BEGIN
    K:=ScalarKindOf(Ty); RETURN Types.IsNumeric(Ty) OR (TypeKindOf(Ty)=TySet) OR (K=TyBoolean) OR (K=TyEnum) OR (K=TyPointer) OR (K=TyRef) OR (K=TyAddress) OR (K=TyString) OR (K=TyCString) OR (K=TyProcedure)
END EqualityScalar;

PROCEDURE SetElementType(Id:TypeId):TypeId;
VAR T:Type;
BEGIN IF Id=0 THEN RETURN 0 END; T:=Types.Get(Id); IF T.Kind=TySet THEN RETURN T.Base END; RETURN 0 END SetElementType;

PROCEDURE SetElementAllowed(Id:TypeId):BOOLEAN;
VAR T:Type; Lo,Hi:LONGINT;
BEGIN
    IF Id=0 THEN RETURN FALSE END; T:=Types.Get(Id);
    IF SetBaseBounds(Id,Lo,Hi) THEN RETURN TRUE END;
    RETURN Types.IsInteger(Id) AND (T.Kind#TyEnum)
END SetElementAllowed;

PROCEDURE NilComparable(Ty:TypeId):BOOLEAN;
VAR K:TypeKind;
BEGIN
    K:=ScalarKindOf(Ty);
    RETURN (K=TyPointer) OR (K=TyRef) OR (K=TyAddress) OR (K=TyString) OR (K=TyCString) OR (K=TyProcedure)
END NilComparable;

PROCEDURE Expr(Nid:NodeId; Scope:ScopeId):TypeId;
VAR N,Bn,Callee:Node; A,B,C,BaseTy,ConversionTy:TypeId; S:SymbolId; Sym:Symbol; T:Type; P:NodeId; Fld:Layout.Field; Count,Index,MethodOffset:CARDINAL; UnsignedLiteral:LONGCARD; SignedLiteral:LONGINT; Expected:TypeId; IM:Interfaces.Member; Meth:Methods.Method; K:TokenKind;
BEGIN
    IF Nid=0 THEN RETURN 0 END; N:=AST.Get(Nid);
    CASE N.Kind OF
    | NInteger:
        IF NOT TryParseLong(N.Text,SignedLiteral) AND NOT TryParseCardinal(N.Text,UnsignedLiteral) THEN ErrCode(N,EInvalidNumber,'integer literal exceeds 64 bits') END;
        A:=Builtin('INTEGER')
    | NReal: A:=Builtin('REAL64')
    | NString: A:=Builtin('STRING')
    | NChar: A:=Builtin('CHAR')
    | NBoolean: A:=Builtin('BOOLEAN')
    | NNil: A:=Builtin('ADDRESS')
    | NSetLiteral:
        A:=0; P:=N.A;
        WHILE P#0 DO
            Bn:=AST.Get(P); B:=Expr(P,Scope);
            IF (B#0) AND NOT SetElementAllowed(B) THEN ErrCode(Bn,EIncompatibleOperands,'set elements must have a finite ordinal type')
            ELSIF A=0 THEN A:=B
            ELSIF (B#0) AND NOT Compatible(A,B) THEN ErrCode(Bn,EIncompatibleOperands,'set literal elements have incompatible ordinal types')
            END;
            P:=Bn.Next
        END;
        BaseTy:=A; A:=NewType(TySet); T:=Types.Get(A); T.Base:=BaseTy; T.Size:=8; T.Align:=8; T.Lo:=0; T.Hi:=63; T.Flags:=T.Flags+{0};
        IF (BaseTy#0) AND SetBaseBounds(BaseTy,T.Lo,T.Hi) THEN END;
        Types.Put(A,T)
    | NName:
        S:=Lookup(Scope,N.Text); IF S=0 THEN ErrCode(N,EUnknownIdentifier,'unknown identifier'); A:=0
        ELSE
            A:=SymbolType(S); Sym:=Symbols.Get(S);
            IF (Sym.Kind=SymConst) AND (1 IN Sym.Flags) AND Interfaces.FindSelective(CurrentModule,N.Text,IM) AND IM.HasConst THEN
                N.IntValue:=IM.ConstValue; N.Flags:=N.Flags+{2}; IF IM.ConstText[0]#0C THEN Assign(N.Text,IM.ConstText); N.Flags:=N.Flags+{7} END; AST.Put(Nid,N)
            ELSIF (Sym.Kind=SymConst) AND NOT (1 IN Sym.Flags) AND (A#0) THEN T:=Types.Get(A); IF T.Kind=TyEnum THEN
                Bn:=AST.Get(Sym.Decl); IF Bn.Kind=NName THEN N.IntValue:=Bn.IntValue; N.Flags:=N.Flags+{2}; AST.Put(Nid,N) END
            END END
        END
    | NUnary:
        K:=FromOrdinal(N.IntValue); A:=Expr(N.A,Scope);
        IF K=KwNOT THEN IF A#Builtin('BOOLEAN') THEN Err(N,'NOT expects BOOLEAN') END
        ELSIF (K=TkPlus) OR (K=TkMinus) THEN IF (A#0) AND NOT ArithmeticNumeric(A) THEN ErrCode(N,EIncompatibleOperands,'unary sign expects an arithmetic value') END
        END
    | NBinary:
        K:=FromOrdinal(N.IntValue); A:=Expr(N.A,Scope); B:=Expr(N.B,Scope);
        ContextualIntegerOperands(N.A,N.B,A,B,Scope);
        IF (K=TkPlus) OR (K=TkMinus) OR (K=TkStar) THEN
            IF (TypeKindOf(A)=TySet) AND (TypeKindOf(B)=TySet) THEN
                IF NOT Compatible(A,B) THEN ErrCode(N,EIncompatibleOperands,'set operands have incompatible element types') END
            ELSIF ((A#0) AND NOT ArithmeticNumeric(A)) OR ((B#0) AND NOT ArithmeticNumeric(B)) THEN ErrCode(N,EIncompatibleOperands,'arithmetic expects integer or real operands')
            ELSIF (A#0) AND (B#0) AND NOT Compatible(A,B) THEN ErrCode(N,EIncompatibleOperands,'numeric operands need compatible types or an explicit conversion') END
        ELSIF K=TkSlash THEN
            IF (A#0) AND (B#0) AND (((ScalarKindOf(A)#TyR32) AND (ScalarKindOf(A)#TyR64)) OR ((ScalarKindOf(B)#TyR32) AND (ScalarKindOf(B)#TyR64))) THEN ErrCode(N,EIncompatibleOperands,'/ is real division; use DIV for integers')
            ELSIF (A#0) AND (B#0) AND NOT Compatible(A,B) THEN ErrCode(N,EIncompatibleOperands,'real operands need the same type or an explicit conversion') END
        ELSIF (K=KwDIV) OR (K=KwMOD) OR (K=KwSHL) OR (K=KwSHR) OR (K=KwXOR) THEN
            IF ((A#0) AND NOT ArithmeticInteger(A)) OR ((B#0) AND NOT ArithmeticInteger(B)) THEN ErrCode(N,EBitwiseInteger,'integer operator expects integer operands')
            ELSIF (A#0) AND (B#0) AND NOT Compatible(A,B) THEN ErrCode(N,EIncompatibleOperands,'integer operands are incompatible') END
        ELSIF (K=KwAND) OR (K=KwOR) THEN
            IF (A=Builtin('BOOLEAN')) AND (B=Builtin('BOOLEAN')) THEN
            ELSIF ArithmeticInteger(A) AND ArithmeticInteger(B) THEN IF NOT Compatible(A,B) THEN ErrCode(N,EIncompatibleOperands,'integer operands are incompatible') END
            ELSE ErrCode(N,EIncompatibleOperands,'AND and OR expect BOOLEAN values or integer operands') END
        ELSIF K=KwIN THEN
            IF TypeKindOf(B)#TySet THEN ErrCode(N,EIncompatibleOperands,'right operand of IN must be a finite set')
            ELSIF (A#0) AND (SetElementType(B)#0) AND NOT Compatible(SetElementType(B),A) THEN ErrCode(N,EIncompatibleOperands,'IN element does not match the set element type') END
        ELSIF IsComparison(K) THEN
            IF (K=TkEqual) OR (K=TkNotEqual) THEN
                Bn:=AST.Get(N.A); Callee:=AST.Get(N.B);
                IF ((Bn.Kind=NNil) AND NilComparable(B)) OR ((Callee.Kind=NNil) AND NilComparable(A)) THEN
                ELSIF (A#0) AND (B#0) AND ((NOT EqualityScalar(A)) OR (NOT EqualityScalar(B)) OR (NOT SameValueType(A,B))) THEN ErrCode(N,EIncompatibleOperands,'these values cannot be compared') END
            ELSE
                IF (A#0) AND (B#0) AND ((NOT OrderedScalar(A)) OR (NOT OrderedScalar(B)) OR (NOT Compatible(A,B))) THEN ErrCode(N,EIncompatibleOperands,'ordered comparison expects compatible numeric or ordinal values') END
            END
        END;
        IF IsComparison(K) THEN A:=Builtin('BOOLEAN') END
    | NCall:
        Count:=0; P:=N.B; WHILE P#0 DO Bn:=AST.Get(P); B:=Expr(P,Scope); INC(Count); P:=Bn.Next END;
        Callee:=AST.Get(N.A); BaseTy:=0;
        IF Callee.Kind=NSelect THEN
            BaseTy:=Expr(Callee.A,Scope);
            IF BaseTy#0 THEN
                T:=Types.Get(BaseTy);
                IF T.Kind=TyAtomic THEN
                    IF Equal(Callee.Text,'Load') THEN
                        IF Count#0 THEN ErrCode(N,EWrongArgumentCount,'atomic Load takes no arguments') END; A:=T.Base; IF Nid<=MaxTypedNodes THEN NodeTypes[Nid]:=A END; RETURN A
                    ELSIF Equal(Callee.Text,'Store') THEN
                        IF Count#1 THEN ErrCode(N,EWrongArgumentCount,'atomic Store expects one value')
                        ELSIF (N.B#0) AND NOT ValueCompatible(T.Base,NodeTypes[N.B],N.B,Scope) THEN ErrCode(AST.Get(N.B),EArgumentType,'atomic Store value has the wrong type') END;
                        A:=Builtin('VOID'); IF Nid<=MaxTypedNodes THEN NodeTypes[Nid]:=A END; RETURN A
                    ELSIF Equal(Callee.Text,'FetchAdd') THEN
                        IF Count#1 THEN ErrCode(N,EWrongArgumentCount,'atomic FetchAdd expects one value')
                        ELSIF (N.B#0) AND NOT ValueCompatible(T.Base,NodeTypes[N.B],N.B,Scope) THEN ErrCode(AST.Get(N.B),EArgumentType,'atomic FetchAdd value has the wrong type') END;
                        A:=T.Base; IF Nid<=MaxTypedNodes THEN NodeTypes[Nid]:=A END; RETURN A
                    ELSIF Equal(Callee.Text,'CompareExchange') THEN
                        IF Count#2 THEN ErrCode(N,EWrongArgumentCount,'atomic CompareExchange expects expected and desired values')
                        ELSIF N.B#0 THEN
                            Bn:=AST.Get(N.B); IF NOT ValueCompatible(T.Base,NodeTypes[N.B],N.B,Scope) THEN ErrCode(Bn,EArgumentType,'atomic expected value has the wrong type') END;
                            IF (Bn.Next#0) AND NOT ValueCompatible(T.Base,NodeTypes[Bn.Next],Bn.Next,Scope) THEN ErrCode(AST.Get(Bn.Next),EArgumentType,'atomic desired value has the wrong type') END
                        END;
                        A:=Builtin('BOOLEAN'); IF Nid<=MaxTypedNodes THEN NodeTypes[Nid]:=A END; RETURN A
                    END
                END
            END
        END;
        (* A type name in call position is an explicit conversion, not a procedure call. *)
        ConversionTy:=0;
        IF Callee.Kind=NResolvedType THEN ConversionTy:=VAL(TypeId,Callee.IntValue)
        ELSIF Callee.Kind=NName THEN
            ConversionTy:=Builtin(Callee.Text);
            IF ConversionTy=0 THEN S:=Lookup(Scope,Callee.Text); IF S#0 THEN Sym:=Symbols.Get(S); IF Sym.Kind=SymType THEN ConversionTy:=Sym.TypeId END END END
        ELSIF Callee.Kind=NSelect THEN
            Bn:=AST.Get(Callee.A); IF FindModuleMember(Bn,Scope,Callee.Text,IM) AND (IM.Kind=Interfaces.MemberType) THEN ConversionTy:=IM.TypeId END
        END;
        IF ConversionTy#0 THEN
            IF Count#1 THEN ErrCode(N,ETypeConversionArity,'type conversion requires exactly one value')
            ELSIF N.B#0 THEN B:=NodeTypes[N.B]; IF (B#0) AND NOT ConversionAllowed(ConversionTy,B) THEN ErrCode(N,EDistinctConversion,'explicit conversion is not defined for these types') END; CheckRange(N.B,ConversionTy,Scope)
            END;
            A:=ConversionTy; IF N.A<=MaxTypedNodes THEN NodeTypes[N.A]:=ConversionTy END
        ELSE
            MethodOffset:=0;
            IF Callee.Kind=NSelect THEN BaseTy:=TypeOf(Callee.A); IF BaseTy#0 THEN T:=Types.Get(BaseTy); IF (T.Kind=TyRef) OR (T.Kind=TyPointer) THEN BaseTy:=T.Base END; IF Methods.Find(BaseTy,Callee.Text,Meth) THEN MethodOffset:=1 END END END;
            C:=CalleeType(N.A,Scope); IF (N.A<=MaxTypedNodes) AND (C#0) THEN NodeTypes[N.A]:=C END;
            IF C#0 THEN
                T:=Types.Get(C);
                IF T.Kind=TyProcedure THEN
                    IF ((NOT Signatures.IsVariadic(C)) AND (Signatures.ParameterCount(C)#(Count+MethodOffset))) OR
                       (Signatures.IsVariadic(C) AND ((Count+MethodOffset)<Signatures.ParameterCount(C))) THEN ErrCode(N,EWrongArgumentCount,'wrong number of procedure arguments')
                    ELSE
                        Index:=MethodOffset; P:=N.B;
                        WHILE P#0 DO Bn:=AST.Get(P); B:=NodeTypes[P];
                            IF Index<Signatures.ParameterCount(C) THEN
                                Expected:=Signatures.ParameterType(C,Index);
                                IF Signatures.ParameterByRef(C,Index) AND NOT IsAddressable(P,Scope) THEN ErrCode(Bn,EAddressableRequired,'VAR argument must be an addressable variable') END;
                                IF (Expected#0) AND (B#0) AND RawToManaged(Expected,B,P) THEN ErrCode(Bn,EManagedRawConversion,'raw ADDRESS cannot implicitly become REF; use an explicit conversion in UNSAFE code')
                                ELSIF (Expected#0) AND (B#0) AND NOT ValueCompatible(Expected,B,P,Scope) THEN ErrCode(Bn,EArgumentType,'procedure argument type mismatch') END; CheckRange(P,Expected,Scope)
                            END;
                            INC(Index); P:=Bn.Next
                        END
                    END;
                    A:=T.Result
                ELSE ErrCode(N,ENotProcedure,'called expression is not a procedure'); A:=0
                END
            ELSE ErrCode(N,EUnknownIdentifier,'unknown procedure or type name'); A:=0 END
        END
    | NSelect:
        Bn:=AST.Get(N.A);
        IF Bn.Kind=NName THEN
            S:=Lookup(Scope,Bn.Text);
            IF (S#0) AND (SymbolKindOf(S)=SymModule) THEN
                IF FindModuleMember(Bn,Scope,N.Text,IM) THEN A:=IM.TypeId; IF IM.HasConst THEN N.IntValue:=IM.ConstValue; N.Flags:=N.Flags+{2}; IF IM.ConstText[0]#0C THEN Assign(N.Text,IM.ConstText); N.Flags:=N.Flags+{7} END; AST.Put(Nid,N) END ELSE ErrCode(N,EPrivateMember,'module member is not exported'); A:=0 END
            ELSE
                BaseTy:=Expr(N.A,Scope);
                IF BaseTy#0 THEN T:=Types.Get(BaseTy); IF (T.Kind=TyRef) OR (T.Kind=TyPointer) THEN BaseTy:=T.Base; T:=Types.Get(BaseTy) END END;
                IF (BaseTy#0) AND ((T.Kind=TySlice) OR (T.Kind=TyArray)) AND Equal(N.Text,'Length') THEN A:=Builtin('SIZE')
                ELSIF (BaseTy#0) AND (T.Kind=TySlice) AND Equal(N.Text,'Data') THEN A:=Builtin('ADDRESS')
                ELSIF (BaseTy#0) AND ((T.Kind=TyString) OR (T.Kind=TyCString)) AND Equal(N.Text,'Length') THEN A:=Builtin('SIZE')
                ELSIF (BaseTy#0) AND ((T.Kind=TyString) OR (T.Kind=TyCString)) AND Equal(N.Text,'Data') THEN A:=Builtin('CSTRING')
                ELSIF (BaseTy#0) AND Layout.FindField(BaseTy,N.Text,Fld) THEN A:=Fld.TypeId; N.IntValue:=VAL(LONGINT,Fld.Offset); AST.Put(Nid,N)
                ELSIF (BaseTy#0) AND Methods.Find(BaseTy,N.Text,Meth) THEN A:=Meth.ProcType
                ELSE ErrCode(N,EUnknownField,'unknown field or built-in view member'); A:=0 END
            END
        ELSE
            BaseTy:=Expr(N.A,Scope);
            IF BaseTy#0 THEN T:=Types.Get(BaseTy); IF (T.Kind=TyRef) OR (T.Kind=TyPointer) THEN BaseTy:=T.Base; T:=Types.Get(BaseTy) END END;
            IF (BaseTy#0) AND ((T.Kind=TySlice) OR (T.Kind=TyArray)) AND Equal(N.Text,'Length') THEN A:=Builtin('SIZE')
            ELSIF (BaseTy#0) AND (T.Kind=TySlice) AND Equal(N.Text,'Data') THEN A:=Builtin('ADDRESS')
            ELSIF (BaseTy#0) AND ((T.Kind=TyString) OR (T.Kind=TyCString)) AND Equal(N.Text,'Length') THEN A:=Builtin('SIZE')
            ELSIF (BaseTy#0) AND ((T.Kind=TyString) OR (T.Kind=TyCString)) AND Equal(N.Text,'Data') THEN A:=Builtin('CSTRING')
            ELSIF (BaseTy#0) AND Layout.FindField(BaseTy,N.Text,Fld) THEN A:=Fld.TypeId; N.IntValue:=VAL(LONGINT,Fld.Offset); AST.Put(Nid,N)
            ELSIF (BaseTy#0) AND Methods.Find(BaseTy,N.Text,Meth) THEN A:=Meth.ProcType
            ELSE ErrCode(N,EUnknownField,'unknown field or built-in view member'); A:=0 END
        END
    | NIndex:
        A:=ResolveGenericProcedure(Nid,Scope); N:=AST.Get(Nid);
        IF (A=0) AND NOT (6 IN N.Flags) THEN
            Bn:=AST.Get(N.B); IF Bn.Next#0 THEN ErrCode(N,EIndexInteger,'ordinary indexing accepts one index') END;
            A:=Expr(N.A,Scope); B:=Expr(N.B,Scope); IF (B#0) AND NOT ArithmeticInteger(B) THEN ErrCode(N,EIndexInteger,'array index must be an integer') END;
            IF A#0 THEN T:=Types.Get(A); IF (T.Kind=TyArray) OR (T.Kind=TySlice) OR (T.Kind=TyPointer) OR (T.Kind=TyRef) THEN A:=T.Base ELSIF (T.Kind=TyString) OR (T.Kind=TyCString) THEN A:=Builtin('CHAR') ELSE ErrCode(N,ENotIndexable,'indexed expression is not indexable'); A:=0 END END
        END
    | NDeref:
        A:=Expr(N.A,Scope); IF A#0 THEN T:=Types.Get(A); IF (T.Kind=TyPointer) OR (T.Kind=TyRef) THEN A:=T.Base ELSE ErrCode(N,EDerefType,'^ expects POINTER or REF'); A:=0 END END
    | NAddressOf:
        B:=Expr(N.A,Scope); IF NOT IsAddressable(N.A,Scope) THEN ErrCode(N,EAddressableRequired,'ADR expects an addressable variable, field, element, or dereference') END; A:=Builtin('ADDRESS')
    | NSizeOf:
        BaseTy:=ResolveType(N.A,Scope); IF BaseTy#0 THEN T:=Types.Get(BaseTy); N.IntValue:=VAL(LONGINT,T.Size); AST.Put(Nid,N) END; A:=Builtin('SIZE')
    | NAlignOf:
        BaseTy:=ResolveType(N.A,Scope); IF BaseTy#0 THEN T:=Types.Get(BaseTy); N.IntValue:=VAL(LONGINT,T.Align); AST.Put(Nid,N) END; A:=Builtin('SIZE')
    | NNew:
        BaseTy:=ResolveType(N.A,Scope); IF BaseTy#0 THEN T:=Types.Get(BaseTy); N.IntValue:=VAL(LONGINT,T.Size); AST.Put(Nid,N) END;
        A:=NewType(TyRef); T:=Types.Get(A); T.Base:=BaseTy; T.Size:=8; T.Align:=8; Types.Put(A,T)
    | NStart:
        Bn:=AST.Get(N.A); C:=0;
        IF Bn.Kind=NCall THEN
            B:=Expr(N.A,Scope); IF Bn.B#0 THEN ErrCode(Bn,EWrongArgumentCount,'START accepts a zero-argument procedure or task') END; C:=CalleeType(Bn.A,Scope)
        ELSE
            B:=Expr(N.A,Scope); C:=CalleeType(N.A,Scope)
        END;
        IF C=0 THEN ErrCode(N,ENotProcedure,'START expects a procedure or task')
        ELSE T:=Types.Get(C); IF (T.Kind#TyProcedure) OR (Signatures.ParameterCount(C)#0) THEN ErrCode(N,EWrongArgumentCount,'START accepts a zero-argument procedure or task') END
        END;
        A:=Builtin('ADDRESS')
    | NAwait: B:=Expr(N.A,Scope); A:=Builtin('VOID')
    ELSE A:=0
    END;
    IF Nid<=MaxTypedNodes THEN NodeTypes[Nid]:=A END; RETURN A
END Expr;

PROCEDURE IsConstantExpression(Nid:NodeId; Scope:ScopeId):BOOLEAN;
VAR N,Callee,Base,Arg,Decl:Node; S:SymbolId; Sym:Symbol; P:NodeId; IM:Interfaces.Member; Ty:TypeId; T:Type;
BEGIN
    IF Nid=0 THEN RETURN FALSE END; N:=AST.Get(Nid);
    CASE N.Kind OF
    | NInteger,NReal,NString,NChar,NBoolean,NNil,NSizeOf,NAlignOf:
        RETURN TRUE
    | NSetLiteral:
        P:=N.A; WHILE P#0 DO Arg:=AST.Get(P); IF NOT IsConstantExpression(P,Scope) THEN RETURN FALSE END; P:=Arg.Next END; RETURN TRUE
    | NUnary:
        RETURN IsConstantExpression(N.A,Scope)
    | NBinary:
        RETURN IsConstantExpression(N.A,Scope) AND IsConstantExpression(N.B,Scope)
    | NName:
        S:=Lookup(Scope,N.Text); IF S=0 THEN RETURN FALSE END; Sym:=Symbols.Get(S); IF Sym.Kind#SymConst THEN RETURN FALSE END;
        IF 1 IN Sym.Flags THEN RETURN TRUE END;
        Decl:=AST.Get(Sym.Decl); IF Decl.Kind=NName THEN RETURN TRUE END;
        IF Decl.Kind=NConst THEN RETURN IsConstantExpression(Decl.A,Scope) END; RETURN FALSE
    | NSelect:
        Base:=AST.Get(N.A);
        IF (Base.Kind=NName) AND FindModuleMember(Base,Scope,N.Text,IM) THEN RETURN IM.Kind=Interfaces.MemberConst END;
        Ty:=TypeOf(N.A); IF Ty#0 THEN T:=Types.Get(Ty); RETURN (T.Kind=TyArray) AND Equal(N.Text,'Length') END;
        RETURN FALSE
    | NCall:
        Callee:=AST.Get(N.A); Ty:=0;
        IF Callee.Kind=NResolvedType THEN Ty:=VAL(TypeId,Callee.IntValue)
        ELSIF Callee.Kind=NName THEN
            Ty:=Builtin(Callee.Text); IF Ty=0 THEN S:=Lookup(Scope,Callee.Text); IF S#0 THEN Sym:=Symbols.Get(S); IF Sym.Kind=SymType THEN Ty:=Sym.TypeId END END END
        ELSIF Callee.Kind=NSelect THEN
            Base:=AST.Get(Callee.A); IF FindModuleMember(Base,Scope,Callee.Text,IM) AND (IM.Kind=Interfaces.MemberType) THEN Ty:=IM.TypeId END
        END;
        IF Ty=0 THEN RETURN FALSE END;
        P:=N.B; IF P=0 THEN RETURN FALSE END; Arg:=AST.Get(P); IF Arg.Next#0 THEN RETURN FALSE END; RETURN IsConstantExpression(P,Scope)
    ELSE
        RETURN FALSE
    END
END IsConstantExpression;


PROCEDURE EarlierCaseValue(Arms,Stop:NodeId; Scope:ScopeId; Value:LONGINT):BOOLEAN;
VAR Arm,Label:NodeId; ArmNode,LabelNode:Node; Prior:LONGINT;
BEGIN
    Arm:=Arms;
    WHILE Arm#0 DO
        ArmNode:=AST.Get(Arm); Label:=ArmNode.A;
        WHILE Label#0 DO
            IF Label=Stop THEN RETURN FALSE END;
            LabelNode:=AST.Get(Label);
            IF ConstInteger(Label,Scope,Prior) AND (Prior=Value) THEN RETURN TRUE END;
            Label:=LabelNode.Next
        END;
        Arm:=ArmNode.Next
    END;
    RETURN FALSE
END EarlierCaseValue;

PROCEDURE Statement(Nid:NodeId; Scope:ScopeId);
VAR N,Aarm,BaseNode:Node; A,B,LabelTy:TypeId; Child:ScopeId; P:NodeId; S:SymbolId; Sym:Symbol; T:Type; IM:Interfaces.Member; ConstantValue:LONGINT;
BEGIN
    IF Nid=0 THEN RETURN END; N:=AST.Get(Nid);
    CASE N.Kind OF
    | NBlock:
        Child:=OpenScope(Scope); WalkList(N.A,Child); IF N.B#0 THEN Statement(N.B,Child) END
    | NAssign:
        Aarm:=AST.Get(N.A);
        IF Aarm.Kind=NName THEN
            P:=Lookup(Scope,Aarm.Text); IF (P#0) AND ((SymbolKindOf(P)=SymConst) OR (SymbolKindOf(P)=SymType)) THEN ErrCode(N,ENotAssignable,'left side is not assignable') END
        ELSIF Aarm.Kind=NSelect THEN
            BaseNode:=AST.Get(Aarm.A);
            IF FindModuleMember(BaseNode,Scope,Aarm.Text,IM) AND (IM.Kind=Interfaces.MemberConst) THEN ErrCode(N,ENotAssignable,'imported constant is not assignable') END
        END;
        IF NOT IsAddressable(N.A,Scope) THEN ErrCode(N,ENotAssignable,'left side is not an addressable variable, field, element, or dereference') END;
        A:=Expr(N.A,Scope); B:=Expr(N.B,Scope);
        IF (A#0) AND (B#0) AND RawToManaged(A,B,N.B) THEN ErrCode(N,EManagedRawConversion,'raw ADDRESS cannot implicitly become REF; use an explicit conversion in UNSAFE code')
        ELSIF (A#0) AND (B#0) AND NOT ValueCompatible(A,B,N.B,Scope) THEN ErrCode(N,EAssignmentType,'assignment type mismatch') END; CheckRange(N.B,A,Scope)
    | NReturn:
        IF N.A=0 THEN IF CurrentReturn#Builtin('VOID') THEN ErrCode(N,EReturnValueRequired,'value-returning procedure requires RETURN expression') END
        ELSE A:=Expr(N.A,Scope); IF CurrentReturn=Builtin('VOID') THEN ErrCode(N,EVoidReturnValue,'void procedure cannot return a value')
             ELSIF (A#0) AND RawToManaged(CurrentReturn,A,N.A) THEN ErrCode(N,EManagedRawConversion,'raw ADDRESS cannot implicitly become REF in a return value')
             ELSIF (A#0) AND NOT ValueCompatible(CurrentReturn,A,N.A,Scope) THEN ErrCode(N,EReturnType,'return type mismatch') END; CheckRange(N.A,CurrentReturn,Scope)
        END
    | NIf: IF Expr(N.A,Scope)#Builtin('BOOLEAN') THEN ErrCode(N,EConditionBoolean,'IF condition must be BOOLEAN') END; Statement(N.B,Scope); Statement(N.C,Scope)
    | NWhile: IF Expr(N.A,Scope)#Builtin('BOOLEAN') THEN ErrCode(N,EConditionBoolean,'WHILE condition must be BOOLEAN') END; INC(CurrentLoopDepth); Statement(N.B,Scope); DEC(CurrentLoopDepth)
    | NRepeat: INC(CurrentLoopDepth); Statement(N.A,Scope); DEC(CurrentLoopDepth); IF Expr(N.B,Scope)#Builtin('BOOLEAN') THEN ErrCode(N,EConditionBoolean,'UNTIL condition must be BOOLEAN') END
    | NLoop: INC(CurrentLoopDepth); Statement(N.A,Scope); DEC(CurrentLoopDepth)
    | NExit: IF CurrentLoopDepth=0 THEN ErrCode(N,EExitOutsideLoop,'EXIT is only valid inside a loop') END
    | NFor:
        S:=Lookup(Scope,N.Text);
        IF S=0 THEN ErrCode(N,EForIterator,'FOR control variable must be declared'); LabelTy:=Builtin('INTEGER')
        ELSE Sym:=Symbols.Get(S); LabelTy:=Sym.TypeId;
            IF (Sym.Kind#SymVar) AND (Sym.Kind#SymParam) THEN ErrCode(N,EForIterator,'FOR control variable must be mutable storage') END;
            IF (LabelTy=0) OR NOT ArithmeticInteger(LabelTy) THEN ErrCode(N,EForIterator,'FOR control variable must have an integer type') END
        END;
        IF Nid<=MaxTypedNodes THEN NodeTypes[Nid]:=LabelTy END;
        A:=Expr(N.A,Scope); IF (A#0) AND NOT ValueCompatible(LabelTy,A,N.A,Scope) THEN ErrCode(N,EForIterator,'FOR start value does not fit the control variable') END;
        B:=Expr(N.B,Scope); IF (B#0) AND NOT ValueCompatible(LabelTy,B,N.B,Scope) THEN ErrCode(N,EForIterator,'FOR end value does not fit the control variable') END;
        IF N.C#0 THEN
            A:=Expr(N.C,Scope); IF (A#0) AND NOT ValueCompatible(LabelTy,A,N.C,Scope) THEN ErrCode(N,EForIterator,'FOR BY value does not fit the control variable') END;
            IF ConstInteger(N.C,Scope,ConstantValue) AND (ConstantValue=0) THEN ErrCode(N,EForIterator,'FOR BY value cannot be zero') END
        END;
        INC(CurrentLoopDepth); Statement(N.D,Scope); DEC(CurrentLoopDepth)
    | NForIn:
        Child:=OpenScope(Scope); A:=Expr(N.A,Scope); B:=0;
        IF A#0 THEN T:=Types.Get(A); IF (T.Kind=TyArray) OR (T.Kind=TySlice) THEN B:=T.Base ELSE ErrCode(N,ENotIndexable,'FOR IN expects an ARRAY or SLICE') END END;
        S:=Define(Child,N.Text,SymVar,Nid); IF S#0 THEN Sym:=Symbols.Get(S); Sym.TypeId:=B; Symbols.Put(S,Sym) END;
        IF Nid<=MaxTypedNodes THEN NodeTypes[Nid]:=B END; INC(CurrentLoopDepth); Statement(N.D,Child); DEC(CurrentLoopDepth)
    | NCase:
        A:=Expr(N.A,Scope); IF (A#0) AND NOT RangeBaseAllowed(A) THEN ErrCode(N,EIncompatibleOperands,'CASE selector must be an ordinal value') END;
        P:=N.B; WHILE P#0 DO
            Aarm:=AST.Get(P); B:=Aarm.A;
            WHILE B#0 DO
                BaseNode:=AST.Get(B); LabelTy:=Expr(B,Scope);
                IF NOT ConstInteger(B,Scope,ConstantValue) THEN ErrCode(BaseNode,EInvalidTypeExpression,'CASE label must be an integer or enum constant')
                ELSIF EarlierCaseValue(N.B,B,Scope,ConstantValue) THEN ErrCode(BaseNode,EDuplicateDeclaration,'CASE label value is already used')
                END;
                IF (A#0) AND (LabelTy#0) AND NOT Compatible(A,LabelTy) THEN ErrCode(BaseNode,EIncompatibleOperands,'CASE label does not match the selector type') END; B:=BaseNode.Next
            END;
            Statement(Aarm.B,Scope); P:=Aarm.Next
        END; Statement(N.C,Scope)
    | NAssert: IF Expr(N.A,Scope)#Builtin('BOOLEAN') THEN ErrCode(N,EAssertBoolean,'ASSERT expects BOOLEAN') END
    | NRaise: A:=Expr(N.A,Scope)
    | NStart,NAwait: A:=Expr(Nid,Scope)
    | NUnsafe,NDefer: Statement(N.A,Scope)
    | NParallel:
        IF N.A#0 THEN
            Aarm:=AST.Get(N.A);
            IF Aarm.Kind=NForIn THEN Statement(N.A,Scope)
            ELSE P:=N.A; WHILE P#0 DO Aarm:=AST.Get(P); Statement(P,Scope); P:=Aarm.Next END
            END
        END
    | NWith: A:=Expr(N.A,Scope); Statement(N.B,Scope)
    | NExcept:
        P:=N.A; WHILE P#0 DO Aarm:=AST.Get(P); Statement(Aarm.B,Scope); P:=Aarm.Next END
    ELSE A:=Expr(Nid,Scope)
    END
END Statement;

PROCEDURE WalkList(Nid:NodeId; Scope:ScopeId);
VAR I:NodeId; N:Node; Unreachable:BOOLEAN;
BEGIN
    I:=Nid; Unreachable:=FALSE;
    WHILE I#0 DO
        N:=AST.Get(I); IF Unreachable THEN WarnCode(N,WUnreachable,'statement is unreachable') END;
        Statement(I,Scope);
        IF (N.Kind=NReturn) OR (N.Kind=NExit) THEN Unreachable:=TRUE END;
        I:=N.Next
    END
END WalkList;

PROCEDURE DefineGenericParams(Meta:NodeId; Scope:ScopeId);
VAR P:NodeId; N:Node; S:SymbolId; Sym:Symbol; Ty:TypeId; T:Type;
BEGIN
    P:=Meta;
    WHILE P#0 DO
        N:=AST.Get(P);
        IF N.Kind=NGenericParam THEN
            IF LookupLocal(Scope,N.Text)#0 THEN ErrCode(N,EDuplicateDeclaration,'generic parameter is already declared')
            ELSE
                Ty:=NewType(TyGeneric); T:=Types.Get(Ty); Assign(T.Name,N.Text); T.Size:=8; T.Align:=8; Types.Put(Ty,T);
                S:=Define(Scope,N.Text,SymType,P); Sym:=Symbols.Get(S); Sym.TypeId:=Ty; Symbols.Put(S,Sym)
            END
        END;
        P:=N.Next
    END
END DefineGenericParams;

PROCEDURE ReceiverNode(Meta:NodeId):NodeId;
VAR P:NodeId; N:Node;
BEGIN P:=Meta; WHILE P#0 DO N:=AST.Get(P); IF N.Kind=NReceiver THEN RETURN P END; P:=N.Next END; RETURN 0 END ReceiverNode;

PROCEDURE MethodLink(N:Node; Receiver:NodeId; VAR Link:Text);
VAR R,TN:Node;
BEGIN
    Assign(Link,CurrentModule); Append(Link,'__'); R:=AST.Get(Receiver); TN:=AST.Get(R.A);
    IF TN.Kind=NNamedType THEN Append(Link,TN.Text); Append(Link,'__') END; Append(Link,N.Text)
END MethodLink;

PROCEDURE ProcedureType(N:Node; Scope:ScopeId):TypeId;
VAR I,PT:TypeId; T:Type; GS:ScopeId; P,R:NodeId; PN:Node; S:SymbolId; GenericCount:CARDINAL; GenericParams:Generics.ActualArray;
BEGIN
    GS:=OpenScope(Scope); DefineGenericParams(N.D,GS);
    I:=NewType(TyProcedure); T:=Types.Get(I); T.Result:=ResolveType(N.B,GS); T.Size:=8; T.Align:=8; Types.Put(I,T);
    Signatures.BeginProcedure(I);
    R:=ReceiverNode(N.D); IF R#0 THEN PN:=AST.Get(R); PT:=ResolveType(PN.A,GS); Signatures.AddParameter(I,PT,0 IN PN.Flags) END;
    P:=N.A; WHILE P#0 DO PN:=AST.Get(P); PT:=ResolveType(PN.A,GS); Signatures.AddParameter(I,PT,0 IN PN.Flags); P:=PN.Next END;
    GenericCount:=0; P:=N.D;
    WHILE (P#0) AND (GenericCount<Generics.MaxGenericParams) DO
        PN:=AST.Get(P); IF PN.Kind=NGenericParam THEN S:=Lookup(GS,PN.Text); IF S#0 THEN GenericParams[GenericCount]:=SymbolType(S); INC(GenericCount) END END; P:=PN.Next
    END;
    IF GenericCount>0 THEN Generics.RegisterTemplate(I,GenericParams,GenericCount) END;
    RETURN I
END ProcedureType;

PROCEDURE HasGenericParams(Meta:NodeId):BOOLEAN;
VAR P:NodeId; N:Node;
BEGIN P:=Meta; WHILE P#0 DO N:=AST.Get(P); IF N.Kind=NGenericParam THEN RETURN TRUE END; P:=N.Next END; RETURN FALSE END HasGenericParams;

PROCEDURE DefineEnumMembers(TypeNode:NodeId; Scope:ScopeId; Ty:TypeId);
VAR N,M:Node; P:NodeId; S:SymbolId; Sym:Symbol; Ordinal:LONGINT;
BEGIN
    N:=AST.Get(TypeNode); IF (N.Kind#NEnumType) THEN RETURN END; P:=N.A; Ordinal:=0;
    WHILE P#0 DO
        M:=AST.Get(P); M.IntValue:=Ordinal; AST.Put(P,M);
        IF LookupLocal(Scope,M.Text)#0 THEN ErrCode(M,EDuplicateDeclaration,'enum member is already declared')
        ELSE S:=Define(Scope,M.Text,SymConst,P); Sym:=Symbols.Get(S); Sym.TypeId:=Ty; Symbols.Put(S,Sym)
        END;
        INC(Ordinal); P:=M.Next
    END
END DefineEnumMembers;

PROCEDURE ImportedSymbolKind(K:Interfaces.MemberKind):SymbolKind;
BEGIN
    CASE K OF
    | Interfaces.MemberType:RETURN SymType
    | Interfaces.MemberProcedure:RETURN SymProc
    | Interfaces.MemberConst:RETURN SymConst
    | Interfaces.MemberVar:RETURN SymVar
    | Interfaces.MemberException:RETURN SymException
    ELSE RETURN SymNone
    END
END ImportedSymbolKind;

PROCEDURE DeclareImport(Decl:NodeId; N:Node; Scope:ScopeId);
VAR LocalNode,MemberNode:Node; LocalId,P:NodeId; LocalName:Text; S:SymbolId; Sym:Symbol; IM:Interfaces.Member; K:SymbolKind; I:CARDINAL;
BEGIN
    I:=0; WHILE I<ImportedModuleCount DO IF Equal(ImportedModules[I],N.Text) AND (ImportedModuleScopes[I]=Scope) THEN ErrCode(N,EDuplicateDeclaration,'module is imported more than once in this scope'); RETURN END; INC(I) END;
    IF ImportedModuleCount<=HIGH(ImportedModules) THEN Assign(ImportedModules[ImportedModuleCount],N.Text); ImportedModuleScopes[ImportedModuleCount]:=Scope; INC(ImportedModuleCount) END;
    IF N.B=0 THEN
        IF N.A#0 THEN LocalNode:=AST.Get(N.A); Assign(LocalName,LocalNode.Text); LocalId:=N.A
        ELSE Assign(LocalName,N.Text); LocalId:=Decl
        END;
        IF LookupLocal(Scope,LocalName)#0 THEN ErrCode(AST.Get(LocalId),EDuplicateDeclaration,'import name is already declared in this scope'); RETURN END;
        S:=Define(Scope,LocalName,SymModule,Decl); Interfaces.RegisterAlias(CurrentModule,LocalName,N.Text); RETURN
    END;
    P:=N.B;
    WHILE P#0 DO
        MemberNode:=AST.Get(P);
        IF LookupLocal(Scope,MemberNode.Text)#0 THEN ErrCode(MemberNode,EDuplicateDeclaration,'selective import name is already declared in this scope')
        ELSIF NOT Interfaces.Find(N.Text,MemberNode.Text,IM) THEN ErrCode(MemberNode,EPrivateMember,'module does not export this name')
        ELSE
            K:=ImportedSymbolKind(IM.Kind);
            IF K=SymNone THEN ErrCode(MemberNode,EPrivateMember,'module member cannot be imported')
            ELSE
                S:=Define(Scope,MemberNode.Text,K,P); Sym:=Symbols.Get(S); Sym.TypeId:=IM.TypeId; Sym.Flags:=Sym.Flags+{1}; Symbols.Put(S,Sym);
                IF P<=MaxTypedNodes THEN NodeTypes[P]:=IM.TypeId END;
                Interfaces.RegisterSelective(CurrentModule,MemberNode.Text,N.Text,MemberNode.Text)
            END
        END;
        P:=MemberNode.Next
    END
END DeclareImport;

PROCEDURE DeclareList(Nid:NodeId; Scope:ScopeId);
VAR I,P:NodeId; N,TN:Node; K:SymbolKind; S:SymbolId; Sym:Symbol; Ty,InitTy:TypeId; OpaqueType:Type; Link:Text; GScope:ScopeId; GenericCount:CARDINAL; GenericParams:Generics.ActualArray; Predeclared:BOOLEAN;
BEGIN
    I:=Nid;
    WHILE I#0 DO
        N:=AST.Get(I); K:=SymNone; Ty:=0; Predeclared:=FALSE;
        CASE N.Kind OF
        | NImport: DeclareImport(I,N,Scope)
        | NConst:
            K:=SymConst; Ty:=Expr(N.A,Scope);
            IF NOT IsConstantExpression(N.A,Scope) THEN ErrCode(N,EConstantExpression,'CONST initializer must be a side-effect-free constant expression') END
        | NType,NSubtype:
            K:=SymType; GScope:=OpenScope(Scope); DefineGenericParams(N.D,GScope);
            GenericCount:=0; P:=N.D;
            WHILE (P#0) AND (GenericCount<Generics.MaxGenericParams) DO
                TN:=AST.Get(P); IF TN.Kind=NGenericParam THEN S:=Lookup(GScope,TN.Text); IF S#0 THEN GenericParams[GenericCount]:=SymbolType(S); INC(GenericCount) END END; P:=TN.Next
            END;
            IF (N.Kind=NType) AND (N.A=0) AND (0 IN N.Flags) THEN
                IF N.D#0 THEN ErrCode(N,EInvalidTypeExpression,'opaque generic types are not supported') END;
                Ty:=NewType(TyRecord); OpaqueType:=Types.Get(Ty); OpaqueType.Size:=0; OpaqueType.Align:=1; OpaqueType.Flags:=OpaqueType.Flags+{4}; Types.Put(Ty,OpaqueType)
            ELSE
                TN:=AST.Get(N.A);
                IF (N.Kind=NType) AND (TN.Kind=NRecordType) AND (LookupLocal(Scope,N.Text)=0) THEN
                Ty:=NewType(TyRecord); S:=Define(Scope,N.Text,SymType,I); Sym:=Symbols.Get(S); Sym.TypeId:=Ty; Symbols.Put(S,Sym); Predeclared:=TRUE;
                IF N.D#0 THEN Generics.RegisterTemplate(Ty,GenericParams,GenericCount) END;
                Ty:=RecordLayoutInto(TN,GScope,TyRecord,Ty)
                ELSE Ty:=ResolveType(N.A,GScope)
                END
            END;
            IF (N.Kind=NType) AND (N.D#0) THEN Generics.RegisterTemplate(Ty,GenericParams,GenericCount) END
        | NVar: K:=SymVar; Ty:=ResolveType(N.A,Scope)
        | NProcedure: K:=SymProc; Ty:=ProcedureType(N,Scope)
        | NTask: K:=SymTask; Ty:=ProcedureType(N,Scope)
        | NException: K:=SymException; Ty:=Builtin('INTEGER')
        | NForeign: K:=SymForeign; Ty:=ProcedureType(N,Scope); IF 1 IN N.Flags THEN Signatures.SetVariadic(Ty,TRUE) END
        ELSE
        END;
        IF K#SymNone THEN
            IF Predeclared THEN
                Sym:=Symbols.Get(S); Sym.TypeId:=Ty; Symbols.Put(S,Sym); IF I<=MaxTypedNodes THEN NodeTypes[I]:=Ty END
            ELSIF LookupLocal(Scope,N.Text)#0 THEN ErrCode(N,EDuplicateDeclaration,'name is already declared in this scope')
            ELSE
                S:=Define(Scope,N.Text,K,I); Sym:=Symbols.Get(S); Sym.TypeId:=Ty; Symbols.Put(S,Sym); IF I<=MaxTypedNodes THEN NodeTypes[I]:=Ty END;
                IF (N.Kind=NProcedure) AND (ReceiverNode(N.D)#0) THEN
                    P:=ReceiverNode(N.D); TN:=AST.Get(P); InitTy:=ResolveType(TN.A,Scope); MethodLink(N,P,Link); Methods.Add(InitTy,N.Text,Ty,Link,0 IN TN.Flags)
                END
            END;
            IF N.Kind=NVar THEN
                IF N.B#0 THEN InitTy:=Expr(N.B,Scope);
                    IF (Ty#0) AND (InitTy#0) AND RawToManaged(Ty,InitTy,N.B) THEN ErrCode(N,EManagedRawConversion,'raw ADDRESS cannot implicitly initialize a REF')
                    ELSIF (Ty#0) AND (InitTy#0) AND NOT ValueCompatible(Ty,InitTy,N.B,Scope) THEN ErrCode(N,EAssignmentType,'variable initializer has the wrong type') END; CheckRange(N.B,Ty,Scope)
                END
            END;
            IF (N.Kind=NType) OR (N.Kind=NSubtype) THEN TN:=AST.Get(N.A); IF TN.Kind=NEnumType THEN DefineEnumMembers(N.A,Scope,Ty) END END
        END;
        I:=N.Next
    END
END DeclareList;

PROCEDURE HasImplementationName(N:Node):BOOLEAN;
BEGIN
    RETURN (N.Kind=NConst) OR (N.Kind=NType) OR (N.Kind=NSubtype) OR (N.Kind=NVar) OR
           (N.Kind=NProcedure) OR (N.Kind=NTask) OR (N.Kind=NForeign) OR (N.Kind=NException)
END HasImplementationName;

PROCEDURE ImplementationConflict(N:Node; Existing:SymbolId);
VAR Prior:Symbol; Previous:Node; L:Text;
BEGIN
    ErrCode(N,EDuplicateDeclaration,'implementation name is provided by more than one active declaration');
    IF Existing#0 THEN Prior:=Symbols.Get(Existing); Previous:=AST.Get(Prior.Decl); LineText(Previous.Line,L); Diagnostics.ReportContext(Note,F,Previous.Line,Previous.Column,'previous active declaration is here',L) END;
    Diagnostics.Help('active divisions and their containing module use one object-file symbol namespace')
END ImplementationConflict;

PROCEDURE RegisterImplementationNames(Declarations:NodeId; Scope:ScopeId);
VAR I,P,S:NodeId; N,M:Node; Name:Text; Existing:SymbolId;
BEGIN
    I:=Declarations;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF HasImplementationName(N) OR (N.Kind=NImport) THEN
            IF N.Kind=NImport THEN
                IF N.B#0 THEN P:=N.B; WHILE P#0 DO M:=AST.Get(P); Existing:=LookupLocal(Scope,M.Text); IF Existing#0 THEN ImplementationConflict(M,Existing) ELSE S:=Define(Scope,M.Text,SymVar,P) END; P:=M.Next END; Name[0]:=0C
                ELSIF N.A#0 THEN M:=AST.Get(N.A); Assign(Name,M.Text)
                ELSE Assign(Name,N.Text)
                END
            ELSE Assign(Name,N.Text)
            END;
            Existing:=LookupLocal(Scope,Name);
            IF (Name[0]#0C) AND (Existing#0) THEN
                ImplementationConflict(N,Existing)
            ELSIF Name[0]#0C THEN S:=Define(Scope,Name,SymVar,I)
            END
        END;
        I:=N.Next
    END
END RegisterImplementationNames;

PROCEDURE PromoteDivisionExports(Division:Node; Scope:ScopeId);
VAR P:NodeId; E:Node; Local,Public:SymbolId; Sym,Copy:Symbol;
BEGIN
    P:=Division.C;
    WHILE P#0 DO
        E:=AST.Get(P); Local:=LookupLocal(Scope,E.Text);
        IF Local=0 THEN ErrCode(E,EExportMissing,'division export is not declared in that division')
        ELSIF LookupLocal(Global,E.Text)#0 THEN
            ErrCode(E,EDivisionVisibility,'division export conflicts with a containing module declaration')
        ELSE
            Sym:=Symbols.Get(Local); Public:=Define(Global,E.Text,Sym.Kind,Sym.Decl); Copy:=Symbols.Get(Public);
            Copy.TypeId:=Sym.TypeId; Copy.Flags:=Sym.Flags; Symbols.Put(Public,Copy)
        END;
        P:=E.Next
    END
END PromoteDivisionExports;

PROCEDURE DeclareDivisions(Declarations:NodeId; ImplementationScope:ScopeId);
VAR I:NodeId; N:Node; S:ScopeId;
BEGIN
    DivisionCount:=0; I:=Declarations;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF (N.Kind=NDivision) AND (6 IN N.Flags) THEN
            IF DivisionCount>=MaxDivisions THEN ErrCode(N,EDivisionVisibility,'module contains too many divisions'); RETURN END;
            RegisterImplementationNames(N.B,ImplementationScope);
            S:=OpenScope(Global); DeclareList(N.B,S); PromoteDivisionExports(N,S);
            DivisionNodes[DivisionCount]:=I; DivisionScopes[DivisionCount]:=S; INC(DivisionCount)
        END;
        I:=N.Next
    END
END DeclareDivisions;

PROCEDURE DivisionBodies;
VAR I:CARDINAL; N:Node;
BEGIN
    I:=0;
    WHILE I<DivisionCount DO N:=AST.Get(DivisionNodes[I]); Bodies(N.B,DivisionScopes[I]); INC(I) END
END DivisionBodies;

PROCEDURE FlattenDivisions(Root:NodeId);
VAR R,N,M:Node; I,Next,P,PNext,H,T:NodeId;
BEGIN
    R:=AST.Get(Root); I:=R.A; H:=0; T:=0;
    WHILE I#0 DO
        N:=AST.Get(I); Next:=N.Next; N.Next:=0; AST.Put(I,N);
        IF N.Kind=NDivision THEN
            IF 6 IN N.Flags THEN
                P:=N.B;
                WHILE P#0 DO
                    M:=AST.Get(P); PNext:=M.Next; M.Next:=0; AST.Put(P,M); AST.Append(H,T,P); P:=PNext
                END
            END
        ELSE AST.Append(H,T,I)
        END;
        I:=Next
    END;
    R.A:=H; AST.Put(Root,R)
END FlattenDivisions;

PROCEDURE StatementReturns(Nid:NodeId):BOOLEAN;
VAR N,A:Node; P:NodeId;
BEGIN
    IF Nid=0 THEN RETURN FALSE END; N:=AST.Get(Nid);
    CASE N.Kind OF
    | NReturn: RETURN TRUE
    | NBlock:
        P:=N.A; WHILE P#0 DO IF StatementReturns(P) THEN RETURN TRUE END; A:=AST.Get(P); P:=A.Next END; RETURN FALSE
    | NIf:
        RETURN (N.B#0) AND (N.C#0) AND StatementReturns(N.B) AND StatementReturns(N.C)
    | NCase:
        IF N.C=0 THEN RETURN FALSE END; P:=N.B;
        WHILE P#0 DO A:=AST.Get(P); IF NOT StatementReturns(A.B) THEN RETURN FALSE END; P:=A.Next END;
        RETURN StatementReturns(N.C)
    | NUnsafe: RETURN StatementReturns(N.A)
    ELSE RETURN FALSE
    END
END StatementReturns;

PROCEDURE Bodies(Nid:NodeId; Scope:ScopeId);
VAR I,P:NodeId; N,PN:Node; ProcScope:ScopeId; S:SymbolId; Sym:Symbol; Ignored:TypeId;
BEGIN
    I:=Nid;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF ((N.Kind=NProcedure) OR (N.Kind=NTask)) AND NOT HasGenericParams(N.D) THEN
            ProcScope:=OpenScope(Scope); DefineGenericParams(N.D,ProcScope); P:=N.A;
            WHILE P#0 DO
                PN:=AST.Get(P);
                IF LookupLocal(ProcScope,PN.Text)#0 THEN ErrCode(PN,EDuplicateDeclaration,'formal parameter is already declared')
                ELSE S:=Define(ProcScope,PN.Text,SymParam,P); Sym:=Symbols.Get(S); Sym.TypeId:=ResolveType(PN.A,ProcScope); Symbols.Put(S,Sym); IF P<=MaxTypedNodes THEN NodeTypes[P]:=Sym.TypeId END
                END;
                P:=PN.Next
            END;
            CurrentReturn:=ResolveType(N.B,ProcScope);
            IF N.Kind=NTask THEN CurrentReturn:=Builtin('VOID') END;
            (* Metadata contains generic parameters, receiver, contracts and local declarations. *)
            P:=N.D;
            WHILE P#0 DO
                PN:=AST.Get(P);
                IF PN.Kind=NReceiver THEN
                    IF LookupLocal(ProcScope,PN.Text)#0 THEN ErrCode(PN,EDuplicateDeclaration,'receiver name conflicts with a formal parameter')
                    ELSE S:=Define(ProcScope,PN.Text,SymParam,P); Sym:=Symbols.Get(S); Sym.TypeId:=ResolveType(PN.A,ProcScope); Symbols.Put(S,Sym); IF P<=MaxTypedNodes THEN NodeTypes[P]:=Sym.TypeId END
                    END;
                    P:=PN.Next
                ELSIF (PN.Kind=NConst) OR (PN.Kind=NType) OR (PN.Kind=NSubtype) OR (PN.Kind=NVar) OR (PN.Kind=NException) THEN
                    DeclareList(P,ProcScope); P:=0
                ELSIF (PN.Kind=NPre) OR (PN.Kind=NPost) OR (PN.Kind=NInvariant) THEN
                    Ignored:=Expr(PN.A,ProcScope); IF (Ignored#0) AND (Ignored#Builtin('BOOLEAN')) THEN ErrCode(PN,EAssertBoolean,'contract expression must have type BOOLEAN') END; P:=PN.Next
                ELSE
                    P:=PN.Next
                END
            END;
            Statement(N.C,ProcScope);
            IF (CurrentReturn#Builtin('VOID')) AND NOT StatementReturns(N.C) THEN ErrCode(N,EReturnValueRequired,'value-returning procedure can reach its end without RETURN') END;
            CurrentReturn:=Builtin('VOID')
        END;
        I:=N.Next
    END
END Bodies;

PROCEDURE InitGraph;
BEGIN
    Types.Init; Layout.Init; Signatures.Init; Interfaces.Init; Methods.Init; Generics.Init; GenericProcedures.Init; GraphReady:=TRUE
END InitGraph;

PROCEDURE UnsignedConstText(Nid:NodeId; VAR Out:Text):BOOLEAN;
VAR N:Node; SignedValue:LONGINT; UnsignedValue:LONGCARD;
BEGIN
    IF Nid=0 THEN RETURN FALSE END; N:=AST.Get(Nid);
    IF N.Kind=NConst THEN RETURN UnsignedConstText(N.A,Out) END;
    IF (N.Kind=NInteger) AND NOT TryParseLong(N.Text,SignedValue) AND TryParseCardinal(N.Text,UnsignedValue) THEN Assign(Out,N.Text); RETURN TRUE END;
    RETURN FALSE
END UnsignedConstText;

PROCEDURE PublishExports(Root:NodeId; Scope:ScopeId);
VAR R,N,D,E,TN,MN:Node; I,P:NodeId; S:SymbolId; Sym:Symbol; K:Interfaces.MemberKind; Link,UnsignedText:Text; Imported:Interfaces.Member; Value:LONGINT;
BEGIN
    R:=AST.Get(Root); IF 0 IN R.Flags THEN Interfaces.RegisterDefinition(R.Text) ELSE Interfaces.RegisterModule(R.Text) END; I:=R.A;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF (N.Kind=NExport) OR ((0 IN R.Flags) AND ((N.Kind=NConst) OR (N.Kind=NType) OR (N.Kind=NSubtype) OR (N.Kind=NVar) OR (N.Kind=NProcedure) OR (N.Kind=NTask) OR (N.Kind=NForeign) OR (N.Kind=NException))) THEN
            S:=Lookup(Scope,N.Text);
            IF S=0 THEN ErrCode(N,EExportMissing,'exported name is not declared')
            ELSE
                Sym:=Symbols.Get(S); K:=Interfaces.MemberNone; Link[0]:=0C;
                IF (1 IN Sym.Flags) AND Interfaces.FindSelective(CurrentModule,N.Text,Imported) THEN
                    K:=Imported.Kind; Assign(Link,Imported.LinkName)
                ELSE CASE Sym.Kind OF
                | SymType:K:=Interfaces.MemberType
                | SymConst:K:=Interfaces.MemberConst; Assign(Link,R.Text); Append(Link,'__'); Append(Link,N.Text)
                | SymVar:K:=Interfaces.MemberVar; Assign(Link,R.Text); Append(Link,'__'); Append(Link,N.Text)
                | SymProc,SymTask:K:=Interfaces.MemberProcedure; Assign(Link,R.Text); Append(Link,'__'); Append(Link,N.Text)
                | SymForeign:
                    K:=Interfaces.MemberProcedure; D:=AST.Get(Sym.Decl);
                    IF D.C#0 THEN E:=AST.Get(D.C); Assign(Link,E.Text) ELSE Assign(Link,D.Text) END
                | SymException:K:=Interfaces.MemberException
                ELSE K:=Interfaces.MemberNone
                END END;
                IF K#Interfaces.MemberNone THEN
                    IF (K=Interfaces.MemberConst) AND (1 IN Sym.Flags) AND Imported.HasConst AND (Imported.ConstText[0]#0C) THEN Interfaces.AddConstText(R.Text,N.Text,Sym.TypeId,Imported.ConstText)
                    ELSIF (K=Interfaces.MemberConst) AND (1 IN Sym.Flags) AND Imported.HasConst THEN Interfaces.AddConst(R.Text,N.Text,Sym.TypeId,Imported.ConstValue)
                    ELSIF (K=Interfaces.MemberConst) AND ConstInteger(Sym.Decl,Scope,Value) THEN Interfaces.AddConst(R.Text,N.Text,Sym.TypeId,Value)
                    ELSIF (K=Interfaces.MemberConst) AND UnsignedConstText(Sym.Decl,UnsignedText) THEN Interfaces.AddConstText(R.Text,N.Text,Sym.TypeId,UnsignedText)
                    ELSE Interfaces.Add(R.Text,N.Text,K,Sym.TypeId,Link)
                    END
                END
            END
        END;
        IF (0 IN R.Flags) AND ((N.Kind=NType) OR (N.Kind=NSubtype)) AND (N.A#0) THEN
            TN:=AST.Get(N.A);
            IF TN.Kind=NEnumType THEN
                P:=TN.A; WHILE P#0 DO MN:=AST.Get(P); S:=Lookup(Scope,MN.Text); IF S#0 THEN Sym:=Symbols.Get(S); Interfaces.AddConst(R.Text,MN.Text,Sym.TypeId,MN.IntValue) END; P:=MN.Next END
            END
        END;
        I:=N.Next
    END
END PublishExports;

PROCEDURE DefinitionActualType(Public:TypeId; VAR Actual:TypeId):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<DefinitionTypeCount DO IF DefinitionPublic[I]=Public THEN Actual:=DefinitionActual[I]; RETURN TRUE END; INC(I) END; RETURN FALSE END DefinitionActualType;

PROCEDURE RememberTypePair(Public,Actual:TypeId):BOOLEAN;
VAR I:CARDINAL;
BEGIN
    I:=0; WHILE I<ComparedCount DO IF (ComparedPublic[I]=Public) AND (ComparedActual[I]=Actual) THEN RETURN FALSE END; INC(I) END;
    IF ComparedCount<MaxTypePairs THEN ComparedPublic[ComparedCount]:=Public; ComparedActual[ComparedCount]:=Actual; INC(ComparedCount) END;
    RETURN TRUE
END RememberTypePair;

PROCEDURE DirectFieldCount(Owner:TypeId):CARDINAL;
VAR I,N:CARDINAL; Fld:Layout.Field;
BEGIN I:=1; N:=0; WHILE I<=Layout.Count() DO Fld:=Layout.Get(I); IF Fld.Owner=Owner THEN INC(N) END; INC(I) END; RETURN N END DirectFieldCount;

PROCEDURE DefinitionTypeMatches(Public,Actual:TypeId):BOOLEAN;
VAR P,A:Type; Mapped:TypeId; I,J:CARDINAL; PF,AF:Layout.Field;
BEGIN
    IF Public=Actual THEN RETURN TRUE END; IF (Public=0) OR (Actual=0) THEN RETURN FALSE END;
    P:=Types.Get(Public); A:=Types.Get(Actual);
    IF DefinitionActualType(Public,Mapped) THEN
        IF Mapped#Actual THEN RETURN FALSE END;
        IF 4 IN P.Flags THEN RETURN TRUE END
    END;
    IF NOT RememberTypePair(Public,Actual) THEN RETURN TRUE END;
    IF P.Kind#A.Kind THEN RETURN FALSE END;
    IF (P.Size#A.Size) OR (P.Align#A.Align) THEN RETURN FALSE END;
    CASE P.Kind OF
    | TyRange:
        RETURN (P.Lo=A.Lo) AND (P.Hi=A.Hi) AND DefinitionTypeMatches(P.Base,A.Base)
    | TyDistinct,TyPointer,TyRef,TySlice,TySet,TyAtomic:
        RETURN DefinitionTypeMatches(P.Base,A.Base)
    | TyArray:
        RETURN DefinitionTypeMatches(P.Base,A.Base)
    | TyProcedure:
        IF Signatures.IsVariadic(Public)#Signatures.IsVariadic(Actual) THEN RETURN FALSE END;
        IF Signatures.ParameterCount(Public)#Signatures.ParameterCount(Actual) THEN RETURN FALSE END;
        IF NOT DefinitionTypeMatches(P.Result,A.Result) THEN RETURN FALSE END;
        I:=0; WHILE I<Signatures.ParameterCount(Public) DO
            IF Signatures.ParameterByRef(Public,I)#Signatures.ParameterByRef(Actual,I) THEN RETURN FALSE END;
            IF NOT DefinitionTypeMatches(Signatures.ParameterType(Public,I),Signatures.ParameterType(Actual,I)) THEN RETURN FALSE END;
            INC(I)
        END;
        RETURN TRUE
    | TyRecord,TyProtected:
        IF NOT DefinitionTypeMatches(P.Base,A.Base) THEN RETURN FALSE END;
        IF DirectFieldCount(Public)#DirectFieldCount(Actual) THEN RETURN FALSE END;
        I:=1;
        WHILE I<=Layout.Count() DO
            PF:=Layout.Get(I);
            IF PF.Owner=Public THEN
                IF NOT Layout.FindField(Actual,PF.Name,AF) OR (AF.Owner#Actual) THEN RETURN FALSE END;
                IF (PF.Offset#AF.Offset) OR (PF.Size#AF.Size) OR (PF.Align#AF.Align) OR (PF.VariantArm#AF.VariantArm) OR (PF.VariantTagCount#AF.VariantTagCount) THEN RETURN FALSE END;
                IF NOT DefinitionTypeMatches(PF.TypeId,AF.TypeId) THEN RETURN FALSE END;
                J:=0; WHILE J<PF.VariantTagCount DO IF Layout.VariantTag(PF.Id,J)#Layout.VariantTag(AF.Id,J) THEN RETURN FALSE END; INC(J) END
            END;
            INC(I)
        END;
        RETURN TRUE
    | TyEnum:
        RETURN (P.Lo=A.Lo) AND (P.Hi=A.Hi)
    | TyGeneric:
        RETURN Equal(P.Name,A.Name)
    ELSE
        RETURN TRUE
    END
END DefinitionTypeMatches;

PROCEDURE InterfaceKindForSymbol(K:SymbolKind):Interfaces.MemberKind;
BEGIN
    CASE K OF
    | SymType:RETURN Interfaces.MemberType
    | SymProc,SymTask,SymForeign:RETURN Interfaces.MemberProcedure
    | SymConst:RETURN Interfaces.MemberConst
    | SymVar:RETURN Interfaces.MemberVar
    | SymException:RETURN Interfaces.MemberException
    ELSE RETURN Interfaces.MemberNone
    END
END InterfaceKindForSymbol;

PROCEDURE ValidateDefinition(Root:NodeId; Scope:ScopeId);
VAR R,Decl:Node; I:CARDINAL; M:Interfaces.Member; S:SymbolId; Sym:Symbol; PublicType,ActualType:Type; ActualId:TypeId;
BEGIN
    R:=AST.Get(Root); DefinitionTypeCount:=0; ComparedCount:=0; I:=0;
    WHILE I<Interfaces.Count() DO
        M:=Interfaces.Get(I);
        IF Equal(M.Module,R.Text) AND (M.Kind=Interfaces.MemberType) THEN
            S:=Lookup(Scope,M.Name);
            IF (S=0) OR (SymbolKindOf(S)#SymType) THEN ErrCode(R,EExportMissing,'definition module type is missing from its implementation')
            ELSIF DefinitionTypeCount>=MaxDefinitionTypes THEN ErrCode(R,EInvalidTypeExpression,'definition module has too many named types')
            ELSE
                DefinitionPublic[DefinitionTypeCount]:=M.TypeId; DefinitionActual[DefinitionTypeCount]:=SymbolType(S); INC(DefinitionTypeCount)
            END
        END;
        INC(I)
    END;
    I:=0;
    WHILE I<DefinitionTypeCount DO
        PublicType:=Types.Get(DefinitionPublic[I]); ActualType:=Types.Get(DefinitionActual[I]);
        IF 4 IN PublicType.Flags THEN
            IF ActualType.Size=0 THEN Decl:=R; ErrCode(Decl,EInvalidTypeExpression,'opaque type implementation has no storage representation')
            ELSE PublicType.Size:=ActualType.Size; PublicType.Align:=ActualType.Align; PublicType.Arg:=DefinitionActual[I]; Types.Put(DefinitionPublic[I],PublicType)
            END
        ELSIF NOT DefinitionTypeMatches(DefinitionPublic[I],DefinitionActual[I]) THEN
            S:=0; Decl:=R; ErrCode(Decl,EInvalidTypeExpression,'public type representation does not match its definition module')
        END;
        INC(I)
    END;
    ComparedCount:=0; I:=0;
    WHILE I<Interfaces.Count() DO
        M:=Interfaces.Get(I);
        IF Equal(M.Module,R.Text) THEN
            S:=Lookup(Scope,M.Name);
            IF S=0 THEN ErrCode(R,EExportMissing,'definition module declaration is missing from its implementation')
            ELSE
                Sym:=Symbols.Get(S); Decl:=AST.Get(Sym.Decl); ActualId:=Sym.TypeId;
                IF InterfaceKindForSymbol(Sym.Kind)#M.Kind THEN ErrCode(Decl,EInvalidTypeExpression,'implementation declaration kind does not match its definition module')
                ELSIF NOT DefinitionTypeMatches(M.TypeId,ActualId) THEN ErrCode(Decl,EInvalidTypeExpression,'implementation declaration type does not match its definition module')
                END
            END
        END;
        INC(I)
    END
END ValidateDefinition;

PROCEDURE DefineBuiltinProcedure(Name:ARRAY OF CHAR; Param,Result:TypeId);
VAR P:TypeId; T:Type; S:SymbolId; Sym:Symbol;
BEGIN
    P:=NewType(TyProcedure); T:=Types.Get(P); T.Result:=Result; T.Size:=8; T.Align:=8; Types.Put(P,T);
    Signatures.BeginProcedure(P); IF Param#0 THEN Signatures.AddParameter(P,Param,FALSE) END;
    S:=Define(Global,Name,SymProc,0); Sym:=Symbols.Get(S); Sym.TypeId:=P; Symbols.Put(S,Sym)
END DefineBuiltinProcedure;

PROCEDURE InstallBuiltins;
BEGIN
    (* Unicode scalar values fit comfortably in INTEGER32.  Keeping ORD at
       that truthful width also avoids an implicit 64-to-32 narrowing at the
       ordinary C putchar boundary. *)
    DefineBuiltinProcedure('ORD',Builtin('CHAR'),Builtin('INTEGER32'));
    DefineBuiltinProcedure('CHR',Builtin('INTEGER'),Builtin('CHAR'))
END InstallBuiltins;

PROCEDURE CheckInternal(Root:NodeId; AgainstDefinition:BOOLEAN):BOOLEAN;
VAR R:Node; I:CARDINAL; ImplementationScope:ScopeId;
BEGIN
    IF NOT GraphReady THEN InitGraph END; FileName(F); Symbols.Init; R:=AST.Get(Root); Assign(CurrentModule,R.Text);
    Divisions.Mark(R.A,TRUE);
    IF NOT (0 IN R.Flags) THEN GenericProcedures.Materialize(R.Text,R.A); AST.Put(Root,R) END;
    I:=0;
    WHILE (I<=AST.Count()) AND (I<=MaxTypedNodes) DO NodeTypes[I]:=0; INC(I) END;
    Global:=OpenScope(0); ImplementationScope:=OpenScope(0); CurrentReturn:=Builtin('VOID'); CurrentLoopDepth:=0; ImportedModuleCount:=0; DivisionCount:=0; InstallBuiltins;
    RegisterImplementationNames(R.A,ImplementationScope); DeclareList(R.A,Global); DeclareDivisions(R.A,ImplementationScope);
    IF NOT (0 IN R.Flags) THEN Bodies(R.A,Global); DivisionBodies; Statement(R.B,Global) END;
    IF NOT HasErrors() THEN IF AgainstDefinition THEN ValidateDefinition(Root,Global) ELSE PublishExports(Root,Global) END END;
    IF NOT HasErrors() AND NOT (0 IN R.Flags) THEN FlattenDivisions(Root) END;
    RETURN NOT HasErrors()
END CheckInternal;

PROCEDURE Check(Root:NodeId):BOOLEAN;
BEGIN RETURN CheckInternal(Root,FALSE) END Check;

PROCEDURE CheckImplementation(Root:NodeId):BOOLEAN;
BEGIN RETURN CheckInternal(Root,TRUE) END CheckImplementation;

PROCEDURE TypeOf(N:NodeId):CARDINAL;
BEGIN IF N<=MaxTypedNodes THEN RETURN NodeTypes[N] ELSE RETURN 0 END END TypeOf;

END Semantics.
