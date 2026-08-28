IMPLEMENTATION MODULE Lower;

IMPORT AST, HIR, Types, Interfaces, ABI, Signatures, Methods, Layout;
FROM AST IMPORT NodeId,Node,NodeKind;
FROM Layout IMPORT Field;
FROM HIR IMPORT FuncId,ValueId,InstId,Inst,Func,Op,NewFunc,Emit,NewValue,GetInst,PutInst,GetFunc,PutFunc;
FROM Tokens IMPORT TokenKind,FromOrdinal,TkPlus,TkMinus,TkStar,TkSlash,TkEqual,TkNotEqual,TkLess,TkLessEqual,TkGreater,TkGreaterEqual,KwDIV,KwMOD,KwAND,KwOR,KwXOR,KwSHL,KwSHR,KwIN,KwIS;
FROM Semantics IMPORT TypeOf;
FROM Types IMPORT Type,TypeKind,TypeId;
FROM HStrings IMPORT Text,Assign,Append,Equal;
FROM Diagnostics IMPORT HasErrors,Simple,SimpleCode,Severity;
FROM ErrorCodes IMPORT EAddressableRequired,ETooManyCallArgs,EUnsupportedABIArg,EUnsupportedABIReturn,EExitOutsideLoop,EForIterator,EDeferLowering,EParallelLowering,EExceptionLowering,ETaskLowering,EIntrinsicArity,ETypeConversionArity,EInternalInvariant,EBackendUnsupportedOp;

CONST
    MaxLocals = 2048;
    MaxParallelBranches = 64;
    MaxForeign = 512;
    MaxTypeNames = 2048;
    MaxCallArgs = 64;
    LocSSE = 16;
    LocStack = 32;

TYPE
    LocalEntry = RECORD Name:Text; Slot:ValueId; TypeId:TypeId; Slots:CARDINAL; ByRef:BOOLEAN END;

VAR
    Current: FuncId;
    ModuleName: Text;
    Declarations: NodeId;
    NextLabel: CARDINAL;
    Locals: ARRAY [0..MaxLocals-1] OF LocalEntry;
    LocalCount: CARDINAL;
    ForeignNames: ARRAY [0..MaxForeign-1] OF Text;
    ForeignTargets: ARRAY [0..MaxForeign-1] OF Text;
    ForeignCount: CARDINAL;
    TypeNames: ARRAY [0..MaxTypeNames-1] OF Text;
    TypeNameCount: CARDINAL;
    LoopEnds: ARRAY [0..127] OF CARDINAL;
    LoopDeferBase: ARRAY [0..127] OF CARDINAL;
    LoopDepth: CARDINAL;
    Defers:ARRAY [0..255] OF NodeId; DeferCount:CARDINAL;
    CurrentReturn: TypeId;

PROCEDURE Label():CARDINAL;
BEGIN INC(NextLabel); RETURN NextLabel END Label;

PROCEDURE ResetLocals;
BEGIN LocalCount:=0; LoopDepth:=0; DeferCount:=0 END ResetLocals;
PROCEDURE PushLoop(EndLabel:CARDINAL);
BEGIN
    IF LoopDepth<128 THEN LoopEnds[LoopDepth]:=EndLabel; LoopDeferBase[LoopDepth]:=DeferCount; INC(LoopDepth)
    ELSE SimpleCode(Fatal,EInternalInvariant,'loop nesting limit exceeded')
    END
END PushLoop;

PROCEDURE PopLoop;
BEGIN IF LoopDepth>0 THEN DEC(LoopDepth) END END PopLoop;

PROCEDURE EmitJump(Target:CARDINAL);
VAR I:InstId; X:Inst;
BEGIN I:=Emit(Current,OpJump,0,0,0,0); X:=GetInst(I); X.Label:=Target; PutInst(I,X) END EmitJump;

PROCEDURE EmitLabel(Target:CARDINAL);
VAR I:InstId; X:Inst;
BEGIN I:=Emit(Current,OpLabel,0,0,0,0); X:=GetInst(I); X.Label:=Target; PutInst(I,X) END EmitLabel;

PROCEDURE EmitDiscard(O:Op; D,A,B:ValueId; Imm:LONGINT);
VAR Ignored:InstId;
BEGIN Ignored:=Emit(Current,O,D,A,B,Imm) END EmitDiscard;


PROCEDURE TypeSlots(Ty:TypeId):CARDINAL;
VAR T:Type; N:CARDINAL;
BEGIN
    IF Ty=0 THEN RETURN 1 END; T:=Types.Get(Ty); IF T.Size=0 THEN RETURN 1 END; N:=(T.Size+7) DIV 8; IF N=0 THEN N:=1 END; RETURN N
END TypeSlots;

PROCEDURE NewTypedValue(Ty:TypeId):ValueId;
VAR I,N:CARDINAL; V:ValueId;
BEGIN
    N:=TypeSlots(Ty); I:=0; V:=0; WHILE I<N DO V:=NewValue(Current); INC(I) END; RETURN V
END NewTypedValue;

PROCEDURE AddLocal(Name:ARRAY OF CHAR; Ty:TypeId; ByRef:BOOLEAN):ValueId;
VAR V:ValueId; N:CARDINAL;
BEGIN
    IF LocalCount>=MaxLocals THEN SimpleCode(Fatal,EInternalInvariant,'too many locals in procedure'); RETURN 0 END;
    IF ByRef THEN N:=1; V:=NewValue(Current) ELSE N:=TypeSlots(Ty); V:=NewTypedValue(Ty) END; Assign(Locals[LocalCount].Name,Name); Locals[LocalCount].Slot:=V; Locals[LocalCount].TypeId:=Ty; Locals[LocalCount].Slots:=N; Locals[LocalCount].ByRef:=ByRef; INC(LocalCount); RETURN V
END AddLocal;

PROCEDURE ZeroLocal(Slot:ValueId; Ty:TypeId);
VAR I,Count:CARDINAL; InstNo:InstId; X:Inst;
BEGIN
    IF Slot=0 THEN RETURN END; Count:=TypeSlots(Ty); I:=0;
    WHILE I<Count DO
        InstNo:=Emit(Current,OpConstI,Slot-I,0,0,0); X:=GetInst(InstNo); X.TypeId:=Ty; PutInst(InstNo,X); INC(I)
    END
END ZeroLocal;

PROCEDURE FindLocal(Name:ARRAY OF CHAR):ValueId;
VAR I:CARDINAL;
BEGIN
    I:=LocalCount;
    WHILE I>0 DO DEC(I); IF Equal(Locals[I].Name,Name) THEN RETURN Locals[I].Slot END END;
    RETURN 0
END FindLocal;

PROCEDURE FindLocalType(Name:ARRAY OF CHAR):TypeId;
VAR I:CARDINAL;
BEGIN I:=LocalCount; WHILE I>0 DO DEC(I); IF Equal(Locals[I].Name,Name) THEN RETURN Locals[I].TypeId END END; RETURN 0 END FindLocalType;

PROCEDURE LocalByRef(Name:ARRAY OF CHAR):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=LocalCount; WHILE I>0 DO DEC(I); IF Equal(Locals[I].Name,Name) THEN RETURN Locals[I].ByRef END END; RETURN FALSE END LocalByRef;

PROCEDURE IsAggregate(Ty:TypeId):BOOLEAN;
VAR T:Type;
BEGIN IF Ty=0 THEN RETURN FALSE END; T:=Types.Get(Ty); RETURN ((T.Kind=TyRecord) OR (T.Kind=TyProtected) OR (T.Kind=TyArray) OR (T.Kind=TySlice) OR (T.Kind=TyVariant)) AND (T.Size>8) END IsAggregate;

PROCEDURE ForeignTarget(Name:ARRAY OF CHAR; VAR Out:Text):BOOLEAN;
VAR I:CARDINAL;
BEGIN
    I:=0;
    WHILE I<ForeignCount DO
        IF Equal(ForeignNames[I],Name) THEN Assign(Out,ForeignTargets[I]); RETURN TRUE END;
        INC(I)
    END;
    RETURN FALSE
END ForeignTarget;

PROCEDURE MangleLocal(Name:ARRAY OF CHAR; VAR Out:Text);
VAR IM:Interfaces.Member;
BEGIN
    IF ForeignTarget(Name,Out) THEN RETURN END;
    IF Interfaces.FindSelective(ModuleName,Name,IM) THEN
        IF IM.LinkName[0]#0C THEN Assign(Out,IM.LinkName)
        ELSE Assign(Out,IM.Module); Append(Out,'__'); Append(Out,IM.Name)
        END;
        RETURN
    END;
    Assign(Out,ModuleName); Append(Out,'__'); Append(Out,Name)
END MangleLocal;

PROCEDURE IsBuiltinType(Name:ARRAY OF CHAR):BOOLEAN;
BEGIN
    RETURN Equal(Name,'BOOLEAN') OR Equal(Name,'CHAR') OR Equal(Name,'BYTE') OR
           Equal(Name,'INTEGER8') OR Equal(Name,'INTEGER16') OR Equal(Name,'INTEGER32') OR Equal(Name,'INTEGER64') OR
           Equal(Name,'CARDINAL8') OR Equal(Name,'CARDINAL16') OR Equal(Name,'CARDINAL32') OR Equal(Name,'CARDINAL64') OR
           Equal(Name,'INTEGER') OR Equal(Name,'CARDINAL') OR Equal(Name,'SIZE') OR Equal(Name,'ADDRESS') OR
           Equal(Name,'REAL32') OR Equal(Name,'REAL64') OR Equal(Name,'STRING') OR Equal(Name,'CSTRING')
END IsBuiltinType;

PROCEDURE IsTypeName(Name:ARRAY OF CHAR):BOOLEAN;
VAR I:CARDINAL; IM:Interfaces.Member;
BEGIN
    IF IsBuiltinType(Name) THEN RETURN TRUE END;
    IF Interfaces.FindSelective(ModuleName,Name,IM) AND (IM.Kind=Interfaces.MemberType) THEN RETURN TRUE END;
    I:=0; WHILE I<TypeNameCount DO IF Equal(TypeNames[I],Name) THEN RETURN TRUE END; INC(I) END; RETURN FALSE
END IsTypeName;

PROCEDURE RegisterTypeNames(Decl:NodeId);
VAR I:NodeId; N:Node;
BEGIN
    TypeNameCount:=0; I:=Decl;
    WHILE I#0 DO N:=AST.Get(I); IF (N.Kind=NType) OR (N.Kind=NSubtype) THEN IF TypeNameCount<MaxTypeNames THEN Assign(TypeNames[TypeNameCount],N.Text); INC(TypeNameCount) END END; I:=N.Next END
END RegisterTypeNames;

PROCEDURE MethodOwner(Ty:TypeId):TypeId;
VAR T:Type;
BEGIN
    IF Ty=0 THEN RETURN 0 END; T:=Types.Get(Ty);
    IF (T.Kind=TyRef) OR (T.Kind=TyPointer) THEN RETURN T.Base END;
    RETURN Ty
END MethodOwner;

PROCEDURE DeclaredProcedureTarget(Name:ARRAY OF CHAR; VAR Out:Text):BOOLEAN;
VAR I,P:NodeId; N,M,TN:Node; IM:Interfaces.Member;
BEGIN
    IF ForeignTarget(Name,Out) THEN RETURN TRUE END;
    IF Interfaces.FindSelective(ModuleName,Name,IM) AND (IM.Kind=Interfaces.MemberProcedure) THEN
        IF IM.LinkName[0]#0C THEN Assign(Out,IM.LinkName) ELSE Assign(Out,IM.Module); Append(Out,'__'); Append(Out,IM.Name) END;
        RETURN TRUE
    END;
    I:=Declarations;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF Equal(N.Text,Name) AND ((N.Kind=NProcedure) OR (N.Kind=NTask) OR (N.Kind=NForeign)) THEN
            IF N.Kind=NForeign THEN MangleLocal(Name,Out); RETURN TRUE END;
            Assign(Out,ModuleName); Append(Out,'__'); P:=N.D;
            WHILE P#0 DO
                M:=AST.Get(P);
                IF M.Kind=NReceiver THEN TN:=AST.Get(M.A); IF TN.Kind=NNamedType THEN Append(Out,TN.Text); Append(Out,'__') END; P:=0
                ELSE P:=M.Next
                END
            END;
            Append(Out,N.Text); RETURN TRUE
        END;
        I:=N.Next
    END;
    Out[0]:=0C; RETURN FALSE
END DeclaredProcedureTarget;

PROCEDURE DirectCallee(Nid:NodeId; VAR Out:Text):BOOLEAN;
VAR N,B:Node; IM:Interfaces.Member; Meth:Methods.Method;
BEGIN
    Out[0]:=0C; IF Nid=0 THEN RETURN FALSE END; N:=AST.Get(Nid);
    IF N.Kind=NName THEN
        IF FindLocal(N.Text)#0 THEN RETURN FALSE END;
        RETURN DeclaredProcedureTarget(N.Text,Out)
    ELSIF (N.Kind=NIndex) AND (N.Text[0]#0C) THEN Assign(Out,N.Text); RETURN TRUE
    ELSIF N.Kind=NSelect THEN
        B:=AST.Get(N.A);
        IF (B.Kind=NName) AND Interfaces.FindVisible(ModuleName,B.Text,N.Text,IM) AND (IM.Kind=Interfaces.MemberProcedure) THEN
            IF IM.LinkName[0]#0C THEN Assign(Out,IM.LinkName) ELSE Assign(Out,IM.Module); Append(Out,'__'); Append(Out,IM.Name) END; RETURN TRUE
        END;
        IF (TypeOf(N.A)#0) AND Methods.Find(MethodOwner(TypeOf(N.A)),N.Text,Meth) THEN Assign(Out,Meth.LinkName); RETURN TRUE END
    END;
    RETURN FALSE
END DirectCallee;

PROCEDURE CalleeName(Nid:NodeId; VAR Out:Text);
BEGIN IF NOT DirectCallee(Nid,Out) THEN Assign(Out,'<indirect>') END
END CalleeName;

PROCEDURE ScalarKind(Ty:TypeId):TypeKind;
VAR T:Type;
BEGIN
    IF Ty=0 THEN RETURN TyInvalid END; T:=Types.Get(Ty);
    WHILE (T.Kind=TyRange) OR (T.Kind=TyDistinct) OR (T.Kind=TyAtomic) DO Ty:=T.Base; IF Ty=0 THEN RETURN TyInvalid END; T:=Types.Get(Ty) END;
    RETURN T.Kind
END ScalarKind;

PROCEDURE IsRealType(Ty:TypeId):BOOLEAN;
VAR K:TypeKind;
BEGIN K:=ScalarKind(Ty); RETURN (K=TyR32) OR (K=TyR64) END IsRealType;


PROCEDURE ConvertValue(V:ValueId; FromTy,ToTy:TypeId):ValueId;
VAR R:ValueId; I:InstId; X:Inst;
BEGIN
    IF (V=0) OR (FromTy=0) OR (ToTy=0) OR (FromTy=ToTy) THEN RETURN V END;
    R:=NewTypedValue(ToTy); I:=Emit(Current,OpConvert,R,V,0,0); X:=GetInst(I);
    X.TypeId:=ToTy; X.Label:=FromTy; PutInst(I,X); RETURN R
END ConvertValue;


PROCEDURE ABIInfo(Ty:TypeId; VAR C:ABI.Classification; VAR Supported:BOOLEAN);
BEGIN
    ABI.ClassifySysV(Ty,C); Supported:=TRUE; IF (C.Count>2) OR (C.A=ABI.MemoryClass) OR (C.B=ABI.MemoryClass) THEN Supported:=FALSE END
END ABIInfo;

PROCEDURE PartSSE(C:ABI.Classification; Part:CARDINAL):BOOLEAN;
BEGIN IF Part=0 THEN RETURN C.A=ABI.SSEClass ELSE RETURN C.B=ABI.SSEClass END END PartSSE;

PROCEDURE AllocateABI(C:ABI.Classification; VAR GPR,SSE,StackNo,LocA,LocB:CARDINAL);
VAR NeedG,NeedS:CARDINAL;
BEGIN
    LocA:=0; LocB:=0; NeedG:=0; NeedS:=0;
    IF C.Count>=1 THEN IF C.A=ABI.SSEClass THEN INC(NeedS) ELSE INC(NeedG) END END;
    IF C.Count>=2 THEN IF C.B=ABI.SSEClass THEN INC(NeedS) ELSE INC(NeedG) END END;
    IF (C.Count>1) AND ((GPR+NeedG>6) OR (SSE+NeedS>8)) THEN
        LocA:=LocStack+StackNo; INC(StackNo); LocB:=LocStack+StackNo; INC(StackNo); RETURN
    END;
    IF C.Count>=1 THEN
        IF C.A=ABI.SSEClass THEN IF SSE<8 THEN LocA:=LocSSE+SSE; INC(SSE) ELSE LocA:=LocStack+StackNo; INC(StackNo) END
        ELSE IF GPR<6 THEN LocA:=GPR; INC(GPR) ELSE LocA:=LocStack+StackNo; INC(StackNo) END END
    END;
    IF C.Count>=2 THEN
        IF C.B=ABI.SSEClass THEN IF SSE<8 THEN LocB:=LocSSE+SSE; INC(SSE) ELSE LocB:=LocStack+StackNo; INC(StackNo) END
        ELSE IF GPR<6 THEN LocB:=GPR; INC(GPR) ELSE LocB:=LocStack+StackNo; INC(StackNo) END END
    END
END AllocateABI;


PROCEDURE ReceiverNode(Meta:NodeId):NodeId;
VAR P:NodeId; N:Node;
BEGIN P:=Meta; WHILE P#0 DO N:=AST.Get(P); IF N.Kind=NReceiver THEN RETURN P END; P:=N.Next END; RETURN 0 END ReceiverNode;

PROCEDURE HasGenericParams(Meta:NodeId):BOOLEAN;
VAR P:NodeId; N:Node;
BEGIN P:=Meta; WHILE P#0 DO N:=AST.Get(P); IF N.Kind=NGenericParam THEN RETURN TRUE END; P:=N.Next END; RETURN FALSE END HasGenericParams;

PROCEDURE ProcedureLink(N:Node; VAR Out:Text);
VAR R,TN:Node; Rid:NodeId;
BEGIN
    Assign(Out,ModuleName); Append(Out,'__'); Rid:=ReceiverNode(N.D);
    IF Rid#0 THEN R:=AST.Get(Rid); TN:=AST.Get(R.A); IF TN.Kind=NNamedType THEN Append(Out,TN.Text); Append(Out,'__') END END; Append(Out,N.Text)
END ProcedureLink;

PROCEDURE TaskTarget(Nid:NodeId; VAR Out:Text):BOOLEAN;
VAR N,C:Node;
BEGIN
    Out[0]:=0C; IF Nid=0 THEN RETURN FALSE END; N:=AST.Get(Nid);
    IF N.Kind=NCall THEN
        IF N.B#0 THEN RETURN FALSE END; CalleeName(N.A,Out); RETURN Out[0]#0C
    ELSIF (N.Kind=NName) OR (N.Kind=NSelect) THEN
        CalleeName(Nid,Out); RETURN Out[0]#0C
    END;
    RETURN FALSE
END TaskTarget;

PROCEDURE PartValue(Base,Part:CARDINAL):CARDINAL;
BEGIN IF Part=0 THEN RETURN Base ELSE RETURN Base-Part END END PartValue;

PROCEDURE AddressOfSlot(Slot:ValueId):ValueId;
VAR V:ValueId;
BEGIN V:=NewValue(Current); EmitDiscard(OpAddrLocal,V,Slot,0,0); RETURN V END AddressOfSlot;

PROCEDURE LoadAggregate(Ptr:ValueId; Ty:TypeId):ValueId;
VAR Base,P,A,V:ValueId; I,N,Remaining:CARDINAL; X:Inst; T:Type;
BEGIN
    Base:=NewTypedValue(Ty); N:=TypeSlots(Ty); T:=Types.Get(Ty); I:=0;
    WHILE I<N DO
        IF I=0 THEN A:=Ptr ELSE A:=NewValue(Current); EmitDiscard(OpLeaOffset,A,Ptr,0,VAL(LONGINT,I*8)) END;
        V:=PartValue(Base,I); P:=Emit(Current,OpLoadPtr,V,A,0,0); X:=GetInst(P); X.TypeId:=Types.Builtin('CARDINAL64');
        Remaining:=T.Size-I*8; IF Remaining<8 THEN X.Imm:=VAL(LONGINT,Remaining) END;
        PutInst(P,X); INC(I)
    END; RETURN Base
END LoadAggregate;

PROCEDURE CopyAggregate(Dst,Src:ValueId; Ty:TypeId);
VAR I,N:CARDINAL;
BEGIN N:=TypeSlots(Ty); I:=0; WHILE I<N DO EmitDiscard(OpMove,PartValue(Dst,I),PartValue(Src,I),0,0); INC(I) END END CopyAggregate;

PROCEDURE StoreAggregate(Ptr,Src:ValueId; Ty:TypeId);
VAR I,N,Remaining:CARDINAL; A:ValueId; P:InstId; X:Inst; T:Type;
BEGIN
    N:=TypeSlots(Ty); T:=Types.Get(Ty); I:=0;
    WHILE I<N DO
        IF I=0 THEN A:=Ptr ELSE A:=NewValue(Current); EmitDiscard(OpLeaOffset,A,Ptr,0,VAL(LONGINT,I*8)) END;
        P:=Emit(Current,OpStorePtr,0,A,PartValue(Src,I),0); X:=GetInst(P); X.TypeId:=Types.Builtin('CARDINAL64');
        Remaining:=T.Size-I*8; IF Remaining<8 THEN X.Imm:=VAL(LONGINT,Remaining) END;
        PutInst(P,X); INC(I)
    END
END StoreAggregate;

PROCEDURE AssertVariantField(Base:ValueId; Fld:Field);
VAR Tag:Field; TagPtr,TagValue,Want,Cmp,Valid,NextValid:ValueId; I:InstId; X:Inst; J:CARDINAL;
BEGIN
    IF (Base=0) OR (Fld.VariantArm=0) THEN RETURN END;
    IF NOT Layout.FindField(Fld.Owner,Fld.TagName,Tag) THEN SimpleCode(Error,EInternalInvariant,'variant field has no tag field'); RETURN END;
    TagPtr:=NewValue(Current); EmitDiscard(OpLeaOffset,TagPtr,Base,0,VAL(LONGINT,Tag.Offset));
    TagValue:=NewTypedValue(Tag.TypeId); I:=Emit(Current,OpLoadPtr,TagValue,TagPtr,0,0); X:=GetInst(I); X.TypeId:=Tag.TypeId; PutInst(I,X);
    Valid:=NewTypedValue(Types.Builtin('BOOLEAN')); EmitDiscard(OpConstI,Valid,0,0,0); J:=0;
    WHILE J<Fld.VariantTagCount DO
        Want:=NewTypedValue(Tag.TypeId); EmitDiscard(OpConstI,Want,0,0,Layout.VariantTag(Fld.Id,J));
        Cmp:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpCmpEq,Cmp,TagValue,Want,0); X:=GetInst(I); X.TypeId:=Tag.TypeId; PutInst(I,X);
        NextValid:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpOr,NextValid,Valid,Cmp,0); X:=GetInst(I); X.TypeId:=Types.Builtin('BOOLEAN'); PutInst(I,X); Valid:=NextValid; INC(J)
    END;
    EmitDiscard(OpAssert,0,Valid,0,0)
END AssertVariantField;

PROCEDURE AddressOfExpr(Nid:NodeId):ValueId;
VAR N,Bn:Node; Base,Index,Scale,Off,V,Slot,LenV,Cmp,Zero,SliceV:ValueId; I:InstId; X:Inst; Name:Text; Ty,ContainerTy:TypeId; T,CT:Type; IM:Interfaces.Member; Fld:Field;
BEGIN
    IF Nid=0 THEN RETURN 0 END; N:=AST.Get(Nid);
    CASE N.Kind OF
    | NName:
        IF 2 IN N.Flags THEN SimpleCode(Error,EAddressableRequired,'enum value is not addressable'); RETURN 0 END;
        Slot:=FindLocal(N.Text);
        IF (Slot#0) AND LocalByRef(N.Text) THEN RETURN Slot END;
        V:=NewValue(Current);
        IF Slot#0 THEN EmitDiscard(OpAddrLocal,V,Slot,0,0)
        ELSE I:=Emit(Current,OpAddrGlobal,V,0,0,0); X:=GetInst(I); MangleLocal(N.Text,Name); Assign(X.Text,Name); PutInst(I,X)
        END; RETURN V
    | NDeref:
        RETURN Expr(N.A)
    | NSelect:
        IF 2 IN N.Flags THEN SimpleCode(Error,EAddressableRequired,'constant is not addressable'); RETURN 0 END;
        Bn:=AST.Get(N.A);
        IF (Bn.Kind=NName) AND Interfaces.FindVisible(ModuleName,Bn.Text,N.Text,IM) AND (IM.Kind=Interfaces.MemberVar) THEN
            V:=NewValue(Current); I:=Emit(Current,OpAddrGlobal,V,0,0,0); X:=GetInst(I); IF IM.LinkName[0]#0C THEN Assign(X.Text,IM.LinkName) ELSE Assign(X.Text,Bn.Text); Append(X.Text,'__'); Append(X.Text,N.Text) END; PutInst(I,X); RETURN V
        END;
        Ty:=TypeOf(N.A); IF Ty#0 THEN T:=Types.Get(Ty) END;
        IF (Ty#0) AND ((T.Kind=TyPointer) OR (T.Kind=TyRef)) THEN Base:=Expr(N.A)
        ELSE Base:=AddressOfExpr(N.A)
        END;
        IF Base=0 THEN RETURN 0 END;
        IF Ty#0 THEN IF (T.Kind=TyPointer) OR (T.Kind=TyRef) THEN Ty:=T.Base END; IF Layout.FindField(Ty,N.Text,Fld) THEN AssertVariantField(Base,Fld) END END;
        V:=NewValue(Current); EmitDiscard(OpLeaOffset,V,Base,0,N.IntValue); RETURN V
    | NIndex:
        Ty:=TypeOf(Nid); IF Ty=0 THEN RETURN 0 END; T:=Types.Get(Ty); ContainerTy:=TypeOf(N.A); Index:=Expr(N.B);
        IF ContainerTy#0 THEN
            CT:=Types.Get(ContainerTy);
            IF CT.Kind=TyArray THEN
                Base:=AddressOfExpr(N.A); LenV:=NewValue(Current); IF T.Size=0 THEN V:=0 ELSE V:=CT.Size DIV T.Size END; EmitDiscard(OpConstI,LenV,0,0,VAL(LONGINT,V));
                Zero:=NewValue(Current); EmitDiscard(OpConstI,Zero,0,0,0); Cmp:=NewValue(Current); I:=Emit(Current,OpCmpGe,Cmp,Index,Zero,0); X:=GetInst(I); X.TypeId:=TypeOf(N.B); PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0);
                Cmp:=NewValue(Current); I:=Emit(Current,OpCmpLt,Cmp,Index,LenV,0); X:=GetInst(I); X.TypeId:=TypeOf(N.B); PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0)
            ELSIF CT.Kind=TySlice THEN
                SliceV:=Expr(N.A); Base:=PartValue(SliceV,0); LenV:=PartValue(SliceV,1);
                Zero:=NewValue(Current); EmitDiscard(OpConstI,Zero,0,0,0); Cmp:=NewValue(Current); I:=Emit(Current,OpCmpGe,Cmp,Index,Zero,0); X:=GetInst(I); X.TypeId:=TypeOf(N.B); PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0);
                Cmp:=NewValue(Current); I:=Emit(Current,OpCmpLt,Cmp,Index,LenV,0); X:=GetInst(I); X.TypeId:=TypeOf(N.B); PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0)
            ELSIF (CT.Kind=TyString) OR (CT.Kind=TyCString) THEN
                Base:=Expr(N.A);
                IF CT.Kind=TyString THEN
                    I:=Emit(Current,OpArg,0,Base,0,0); X:=GetInst(I); X.TypeId:=Types.Builtin('CSTRING'); PutInst(I,X);
                    LenV:=NewValue(Current); I:=Emit(Current,OpCall,LenV,0,0,0); X:=GetInst(I); Assign(X.Text,'strlen'); X.TypeId:=Types.Builtin('SIZE'); PutInst(I,X);
                    Zero:=NewValue(Current); EmitDiscard(OpConstI,Zero,0,0,0); Cmp:=NewValue(Current); I:=Emit(Current,OpCmpGe,Cmp,Index,Zero,0); X:=GetInst(I); X.TypeId:=TypeOf(N.B); PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0);
                    Cmp:=NewValue(Current); I:=Emit(Current,OpCmpLt,Cmp,Index,LenV,0); X:=GetInst(I); X.TypeId:=TypeOf(N.B); PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0)
                END
            ELSE Base:=Expr(N.A) END
        ELSE Base:=Expr(N.A) END;
        Scale:=NewValue(Current);
        IF (ContainerTy#0) AND ((CT.Kind=TyString) OR (CT.Kind=TyCString)) THEN EmitDiscard(OpConstI,Scale,0,0,1)
        ELSE EmitDiscard(OpConstI,Scale,0,0,VAL(LONGINT,T.Size))
        END;
        Off:=NewValue(Current); EmitDiscard(OpMul,Off,Index,Scale,0); V:=NewValue(Current); EmitDiscard(OpAdd,V,Base,Off,0); RETURN V
    ELSE SimpleCode(Error,EAddressableRequired,'expression is not addressable'); RETURN 0
    END
END AddressOfExpr;

PROCEDURE AssertRangeValue(V:ValueId; Ty,CompareTy:TypeId);
VAR T:Type; RangeTy:TypeId; LoV,HiV,Cmp:ValueId; I:InstId; X:Inst;
BEGIN
    IF (V=0) OR (Ty=0) OR (CompareTy=0) THEN RETURN END;
    RangeTy:=Ty; T:=Types.Get(RangeTy);
    IF T.Kind=TyDistinct THEN RangeTy:=T.Base; IF RangeTy=0 THEN RETURN END; T:=Types.Get(RangeTy) END;
    IF T.Kind#TyRange THEN RETURN END;
    LoV:=NewTypedValue(CompareTy); I:=Emit(Current,OpConstI,LoV,0,0,T.Lo); X:=GetInst(I); X.TypeId:=CompareTy; PutInst(I,X);
    Cmp:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpCmpGe,Cmp,V,LoV,0); X:=GetInst(I); X.TypeId:=CompareTy; PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0);
    HiV:=NewTypedValue(CompareTy); I:=Emit(Current,OpConstI,HiV,0,0,T.Hi); X:=GetInst(I); X.TypeId:=CompareTy; PutInst(I,X);
    Cmp:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpCmpLe,Cmp,V,HiV,0); X:=GetInst(I); X.TypeId:=CompareTy; PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0)
END AssertRangeValue;

PROCEDURE SetValidMask(Ty:TypeId):ValueId;
VAR T:Type; Mask,One,Shift,Part:ValueId;
BEGIN
    Mask:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpConstI,Mask,0,0,-1);
    IF Ty=0 THEN RETURN Mask END; T:=Types.Get(Ty); IF T.Kind#TySet THEN RETURN Mask END;
    One:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpConstI,One,0,0,1);
    IF T.Lo>0 THEN
        Shift:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpConstI,Shift,0,0,T.Lo);
        Part:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpShl,Part,One,Shift,0);
        Shift:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpConstI,Shift,0,0,1);
        EmitDiscard(OpSub,Part,Part,Shift,0); EmitDiscard(OpXor,Mask,Mask,Part,0)
    END;
    IF T.Hi<63 THEN
        Shift:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpConstI,Shift,0,0,T.Hi+1);
        Part:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpShl,Part,One,Shift,0);
        Shift:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpConstI,Shift,0,0,1);
        EmitDiscard(OpSub,Part,Part,Shift,0); EmitDiscard(OpAnd,Mask,Mask,Part,0)
    END;
    RETURN Mask
END SetValidMask;

PROCEDURE AssertSetValue(V:ValueId; Ty:TypeId);
VAR Mask,Outside,All,Cmp,Zero:ValueId; I:InstId; X:Inst;
BEGIN
    IF (V=0) OR (Ty=0) THEN RETURN END;
    Mask:=SetValidMask(Ty); All:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpConstI,All,0,0,-1);
    Outside:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpXor,Outside,Mask,All,0); EmitDiscard(OpAnd,Outside,Outside,V,0);
    Zero:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpConstI,Zero,0,0,0);
    Cmp:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpCmpEq,Cmp,Outside,Zero,0); X:=GetInst(I); X.TypeId:=Types.Builtin('CARDINAL64'); PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0)
END AssertSetValue;

PROCEDURE AssertSetElement(V:ValueId; SetTy:TypeId);
VAR T:Type; Lo,Hi,Cmp:ValueId; I:InstId; X:Inst;
BEGIN
    IF (V=0) OR (SetTy=0) THEN RETURN END; T:=Types.Get(SetTy);
    Lo:=NewTypedValue(Types.Builtin('INTEGER')); EmitDiscard(OpConstI,Lo,0,0,T.Lo);
    Cmp:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpCmpGe,Cmp,V,Lo,0); X:=GetInst(I); X.TypeId:=Types.Builtin('INTEGER'); PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0);
    Hi:=NewTypedValue(Types.Builtin('INTEGER')); EmitDiscard(OpConstI,Hi,0,0,T.Hi);
    Cmp:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpCmpLe,Cmp,V,Hi,0); X:=GetInst(I); X.TypeId:=Types.Builtin('INTEGER'); PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0)
END AssertSetElement;

PROCEDURE AssertShiftCount(V:ValueId; ValueTy:TypeId);
VAR T:Type; Zero,Width,Cmp:ValueId; I:InstId; X:Inst;
BEGIN
    IF (V=0) OR (ValueTy=0) THEN RETURN END; T:=Types.Get(ValueTy);
    Zero:=NewTypedValue(ValueTy); EmitDiscard(OpConstI,Zero,0,0,0);
    Cmp:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpCmpGe,Cmp,V,Zero,0); X:=GetInst(I); X.TypeId:=ValueTy; PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0);
    Width:=NewTypedValue(ValueTy); EmitDiscard(OpConstI,Width,0,0,VAL(LONGINT,T.Size*8));
    Cmp:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpCmpLt,Cmp,V,Width,0); X:=GetInst(I); X.TypeId:=ValueTy; PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0)
END AssertShiftCount;

PROCEDURE CoerceValue(V:ValueId; ValueNode:NodeId; FromTy,ToTy:TypeId):ValueId;
VAR F,T,E:Type; R,Ptr,LenV:ValueId; Count:CARDINAL;
BEGIN
    IF (V=0) OR (FromTy=0) OR (ToTy=0) THEN RETURN V END;
    IF FromTy=ToTy THEN RETURN V END;
    F:=Types.Get(FromTy); T:=Types.Get(ToTy);
    IF (F.Kind=TySlice) AND (T.Kind=TySlice) AND Types.Compatible(F.Base,T.Base) THEN RETURN V END;
    IF (F.Kind=TySet) AND (T.Kind=TySet) THEN AssertSetValue(V,ToTy); RETURN V END;
    IF (F.Kind=TyArray) AND (T.Kind=TySlice) AND Types.Compatible(F.Base,T.Base) THEN
        Ptr:=AddressOfExpr(ValueNode); E:=Types.Get(F.Base); IF E.Size=0 THEN Count:=0 ELSE Count:=F.Size DIV E.Size END;
        LenV:=NewTypedValue(Types.Builtin('SIZE')); EmitDiscard(OpConstI,LenV,0,0,VAL(LONGINT,Count));
        R:=NewTypedValue(ToTy); EmitDiscard(OpMove,PartValue(R,0),Ptr,0,0); EmitDiscard(OpMove,PartValue(R,1),LenV,0,0); RETURN R
    END;
    T:=Types.Get(ToTy);
    E:=T; IF (T.Kind=TyDistinct) AND (T.Base#0) THEN E:=Types.Get(T.Base) END;
    IF ((T.Kind=TyRange) OR ((T.Kind=TyDistinct) AND (E.Kind=TyRange))) AND Types.IsInteger(FromTy) THEN
        AssertRangeValue(V,ToTy,FromTy); RETURN ConvertValue(V,FromTy,ToTy)
    END;
    R:=ConvertValue(V,FromTy,ToTy); AssertRangeValue(R,ToTy,ToTy); RETURN R
END CoerceValue;

PROCEDURE Expr(Nid:NodeId):ValueId;
VAR N,CalleeN,Arg1N,Bn:Node; A,B,V,Slot,Ptr,SizeV,ExpectedV,DesiredV,CalleeValue:ValueId; I:InstId; X:Inst; O:Op; Name,TaskName:Text;
    ArgNode:NodeId; AN:Node; Args:ARRAY[0..MaxCallArgs-1] OF ValueId;
    ArgTypes:ARRAY[0..MaxCallArgs-1] OF TypeId; ArgLocA,ArgLocB:ARRAY[0..MaxCallArgs-1] OF CARDINAL;
    ArgClass:ARRAY[0..MaxCallArgs-1] OF ABI.Classification;
    AC,J,GPR,SSE,StackArgs,Part:CARDINAL; Ty,CalleeTy:TypeId; T,ElemT:Type; RetClass:ABI.Classification; Meth:Methods.Method; IM:Interfaces.Member; RealOp,ArgSupported,Direct:BOOLEAN; K:TokenKind;
BEGIN
    IF Nid=0 THEN RETURN 0 END; N:=AST.Get(Nid);
    CASE N.Kind OF
    | NInteger:
        V:=NewValue(Current); I:=Emit(Current,OpConstI,V,0,0,0); X:=GetInst(I); Assign(X.Text,N.Text); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
    | NReal:
        V:=NewValue(Current); I:=Emit(Current,OpConstF,V,0,0,0); X:=GetInst(I); Assign(X.Text,N.Text); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
    | NString:
        V:=NewValue(Current); I:=Emit(Current,OpConstS,V,0,0,0); X:=GetInst(I); Assign(X.Text,N.Text); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
    | NChar:
        V:=NewValue(Current); I:=Emit(Current,OpConstI,V,0,0,N.IntValue); X:=GetInst(I); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
    | NBoolean:
        V:=NewValue(Current); I:=Emit(Current,OpConstI,V,0,0,N.IntValue); X:=GetInst(I); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
    | NNil:
        V:=NewValue(Current); I:=Emit(Current,OpConstI,V,0,0,0); X:=GetInst(I); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
    | NSetLiteral:
        V:=NewTypedValue(TypeOf(Nid)); EmitDiscard(OpConstI,V,0,0,0); ArgNode:=N.A;
        WHILE ArgNode#0 DO
            AN:=AST.Get(ArgNode); A:=Expr(ArgNode); AssertSetElement(A,TypeOf(Nid));
            B:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpConstI,B,0,0,1);
            Ptr:=NewTypedValue(Types.Builtin('CARDINAL64')); I:=Emit(Current,OpShl,Ptr,B,A,0); X:=GetInst(I); X.TypeId:=Types.Builtin('CARDINAL64'); PutInst(I,X);
            EmitDiscard(OpOr,V,V,Ptr,0); ArgNode:=AN.Next
        END;
        RETURN V
    | NName:
        IF 2 IN N.Flags THEN V:=NewValue(Current); I:=Emit(Current,OpConstI,V,0,0,N.IntValue); X:=GetInst(I); IF 7 IN N.Flags THEN Assign(X.Text,N.Text) END; X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V END;
        Slot:=FindLocal(N.Text);
        IF Slot#0 THEN
            IF LocalByRef(N.Text) THEN IF IsAggregate(TypeOf(Nid)) THEN RETURN LoadAggregate(Slot,TypeOf(Nid)) END; V:=NewTypedValue(TypeOf(Nid)); I:=Emit(Current,OpLoadPtr,V,Slot,0,0); X:=GetInst(I); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V END;
            IF IsAggregate(TypeOf(Nid)) THEN RETURN Slot END;
            (* A VAR/foreign call may have written only the declared one-, two-
               or four-byte scalar width into this eight-byte value slot.  A
               typed move normalizes that load before any boolean test or
               arithmetic consumer observes it. *)
            T:=Types.Get(TypeOf(Nid));
            IF T.Size<8 THEN
                V:=NewTypedValue(TypeOf(Nid)); I:=Emit(Current,OpMove,V,Slot,0,0);
                X:=GetInst(I); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
            END;
            RETURN Slot
        END;
        IF DeclaredProcedureTarget(N.Text,Name) THEN
            V:=NewValue(Current); I:=Emit(Current,OpAddrGlobal,V,0,0,0); X:=GetInst(I); Assign(X.Text,Name); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
        END;
        IF IsAggregate(TypeOf(Nid)) THEN
            Ptr:=NewValue(Current); I:=Emit(Current,OpAddrGlobal,Ptr,0,0,0); X:=GetInst(I); MangleLocal(N.Text,Name); Assign(X.Text,Name); PutInst(I,X); RETURN LoadAggregate(Ptr,TypeOf(Nid))
        END;
        V:=NewTypedValue(TypeOf(Nid)); I:=Emit(Current,OpLoad,V,0,0,0); X:=GetInst(I); MangleLocal(N.Text,Name); Assign(X.Text,Name); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
    | NUnary:
        K:=FromOrdinal(N.IntValue);
        A:=Expr(N.A); IF K=TkPlus THEN RETURN A END; V:=NewValue(Current);
        IF K=TkMinus THEN IF IsRealType(TypeOf(N.A)) THEN O:=OpFNeg ELSE O:=OpNeg END ELSE O:=OpNot END;
        I:=Emit(Current,O,V,A,0,0); X:=GetInst(I); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
    | NBinary:
        K:=FromOrdinal(N.IntValue);
        IF (K=KwAND) AND NOT Types.IsInteger(TypeOf(N.A)) THEN
            V:=NewValue(Current); EmitDiscard(OpConstI,V,0,0,0); A:=Expr(N.A); J:=Label();
            I:=Emit(Current,OpBranch,0,A,0,0); X:=GetInst(I); X.Label:=J; PutInst(I,X); B:=Expr(N.B); EmitDiscard(OpMove,V,B,0,0); EmitLabel(J); RETURN V
        ELSIF (K=KwOR) AND NOT Types.IsInteger(TypeOf(N.A)) THEN
            V:=NewValue(Current); EmitDiscard(OpConstI,V,0,0,1); A:=Expr(N.A); J:=Label(); AC:=Label();
            I:=Emit(Current,OpBranch,0,A,0,0); X:=GetInst(I); X.Label:=J; PutInst(I,X); EmitJump(AC); EmitLabel(J); B:=Expr(N.B); EmitDiscard(OpMove,V,B,0,0); EmitLabel(AC); RETURN V
        END;
        A:=Expr(N.A); B:=Expr(N.B);
        IF K=KwIN THEN
            AssertSetElement(A,TypeOf(N.B)); V:=NewTypedValue(Types.Builtin('CARDINAL64')); I:=Emit(Current,OpShr,V,B,A,0); X:=GetInst(I); X.TypeId:=Types.Builtin('CARDINAL64'); PutInst(I,X);
            A:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpConstI,A,0,0,1); B:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpAnd,B,V,A,0); X:=GetInst(I); X.TypeId:=Types.Builtin('BOOLEAN'); PutInst(I,X); RETURN B
        END;
        IF (TypeOf(N.A)#0) AND (TypeOf(N.B)#0) THEN
            T:=Types.Get(TypeOf(N.A)); IF T.Kind=TySet THEN AssertSetValue(B,TypeOf(N.A)) END
        END;
        IF Types.IsInteger(TypeOf(N.A)) AND Types.IsInteger(TypeOf(N.B)) THEN B:=ConvertValue(B,TypeOf(N.B),TypeOf(N.A)) END;
        IF (K=KwSHL) OR (K=KwSHR) THEN AssertShiftCount(B,TypeOf(N.A)) END;
        V:=NewValue(Current); RealOp:=IsRealType(TypeOf(N.A));
        CASE K OF
        | TkPlus:IF TypeOf(Nid)#0 THEN T:=Types.Get(TypeOf(Nid)) END; IF T.Kind=TySet THEN O:=OpOr ELSIF RealOp THEN O:=OpFAdd ELSE O:=OpAdd END
        | TkMinus:
            IF TypeOf(Nid)#0 THEN T:=Types.Get(TypeOf(Nid)) END;
            IF T.Kind=TySet THEN Ptr:=NewTypedValue(Types.Builtin('CARDINAL64')); EmitDiscard(OpConstI,Ptr,0,0,-1); EmitDiscard(OpXor,B,B,Ptr,0); O:=OpAnd
            ELSIF RealOp THEN O:=OpFSub ELSE O:=OpSub END
        | TkStar:IF TypeOf(Nid)#0 THEN T:=Types.Get(TypeOf(Nid)) END; IF T.Kind=TySet THEN O:=OpAnd ELSIF RealOp THEN O:=OpFMul ELSE O:=OpMul END
        | TkSlash:IF RealOp THEN O:=OpFDiv ELSE O:=OpDiv END
        | KwDIV:O:=OpDiv
        | KwMOD:O:=OpMod
        | KwAND:O:=OpAnd
        | KwOR:O:=OpOr
        | KwXOR:O:=OpXor
        | KwSHL:O:=OpShl
        | KwSHR:O:=OpShr
        | TkEqual:IF RealOp THEN O:=OpFCmpEq ELSE O:=OpCmpEq END
        | TkNotEqual:IF RealOp THEN O:=OpFCmpNe ELSE O:=OpCmpNe END
        | TkLess:IF RealOp THEN O:=OpFCmpLt ELSE O:=OpCmpLt END
        | TkLessEqual:IF RealOp THEN O:=OpFCmpLe ELSE O:=OpCmpLe END
        | TkGreater:IF RealOp THEN O:=OpFCmpGt ELSE O:=OpCmpGt END
        | TkGreaterEqual:IF RealOp THEN O:=OpFCmpGe ELSE O:=OpCmpGe END
        ELSE SimpleCode(Error,EBackendUnsupportedOp,'binary operator has no lowering'); RETURN 0
        END;
        I:=Emit(Current,O,V,A,B,0); X:=GetInst(I); IF RealOp OR (O=OpCmpEq) OR (O=OpCmpNe) OR (O=OpCmpLt) OR (O=OpCmpLe) OR (O=OpCmpGt) OR (O=OpCmpGe) THEN X.TypeId:=TypeOf(N.A) ELSE X.TypeId:=TypeOf(Nid) END; PutInst(I,X); RETURN V
    | NCall:
        AN:=AST.Get(N.A);
        IF AN.Kind=NSelect THEN
            Ty:=TypeOf(AN.A);
            IF Ty#0 THEN
                T:=Types.Get(Ty);
                IF T.Kind=TyAtomic THEN
                    Ptr:=AddressOfExpr(AN.A);
                    IF Equal(AN.Text,'Load') THEN
                        V:=NewTypedValue(T.Base); I:=Emit(Current,OpAtomicLoad,V,Ptr,0,0); X:=GetInst(I); X.TypeId:=T.Base; PutInst(I,X); RETURN V
                    ELSIF Equal(AN.Text,'Store') THEN
                        IF N.B=0 THEN SimpleCode(Error,EIntrinsicArity,'atomic Store requires a value'); RETURN 0 END; B:=Expr(N.B); B:=CoerceValue(B,N.B,TypeOf(N.B),T.Base); I:=Emit(Current,OpAtomicStore,0,Ptr,B,0); X:=GetInst(I); X.TypeId:=T.Base; PutInst(I,X); RETURN 0
                    ELSIF Equal(AN.Text,'FetchAdd') THEN
                        IF N.B=0 THEN SimpleCode(Error,EIntrinsicArity,'atomic FetchAdd requires a value'); RETURN 0 END; B:=Expr(N.B); B:=CoerceValue(B,N.B,TypeOf(N.B),T.Base); V:=NewTypedValue(T.Base); I:=Emit(Current,OpAtomicAdd,V,Ptr,B,0); X:=GetInst(I); X.TypeId:=T.Base; PutInst(I,X); RETURN V
                    ELSIF Equal(AN.Text,'CompareExchange') THEN
                        IF N.B=0 THEN SimpleCode(Error,EIntrinsicArity,'atomic CompareExchange requires expected and desired values'); RETURN 0 END;
                        Arg1N:=AST.Get(N.B); IF Arg1N.Next=0 THEN SimpleCode(Error,EIntrinsicArity,'atomic CompareExchange requires desired value'); RETURN 0 END;
                        ExpectedV:=Expr(N.B); ExpectedV:=CoerceValue(ExpectedV,N.B,TypeOf(N.B),T.Base); DesiredV:=Expr(Arg1N.Next); DesiredV:=CoerceValue(DesiredV,Arg1N.Next,TypeOf(Arg1N.Next),T.Base); V:=NewValue(Current); I:=Emit(Current,OpAtomicCAS,V,Ptr,DesiredV,0); X:=GetInst(I); X.Label:=ExpectedV; X.TypeId:=T.Base; PutInst(I,X); RETURN V
                    END
                END
            END
        END;
        IF (AN.Kind=NName) AND (Equal(AN.Text,'ORD') OR Equal(AN.Text,'CHR')) THEN
            IF N.B=0 THEN SimpleCode(Error,EIntrinsicArity,'intrinsic requires one argument'); RETURN 0 END;
            A:=Expr(N.B); RETURN ConvertValue(A,TypeOf(N.B),TypeOf(Nid))
        END;
        CalleeN:=AN;
        IF AN.Kind=NSelect THEN CalleeN:=AST.Get(AN.A) END;
        IF (AN.Kind=NResolvedType) OR ((AN.Kind=NName) AND IsTypeName(AN.Text)) OR
           ((AN.Kind=NSelect) AND (CalleeN.Kind=NName) AND Interfaces.FindVisible(ModuleName,CalleeN.Text,AN.Text,IM) AND (IM.Kind=Interfaces.MemberType)) THEN
            IF N.B=0 THEN SimpleCode(Error,ETypeConversionArity,'type conversion requires one value'); RETURN 0 END; ArgNode:=N.B; AN:=AST.Get(ArgNode);
            IF AN.Next#0 THEN SimpleCode(Error,ETypeConversionArity,'type conversion accepts one value') END;
            A:=Expr(ArgNode); RETURN CoerceValue(A,ArgNode,TypeOf(ArgNode),TypeOf(Nid))
        END;
        AC:=0; CalleeTy:=TypeOf(N.A); Direct:=DirectCallee(N.A,Name); CalleeValue:=0;
        IF (AN.Kind=NSelect) AND (TypeOf(AN.A)#0) AND Methods.Find(MethodOwner(TypeOf(AN.A)),AN.Text,Meth) THEN
            IF Meth.ByRef THEN Args[0]:=AddressOfExpr(AN.A); ArgTypes[0]:=Types.Builtin('ADDRESS') ELSE Args[0]:=Expr(AN.A); ArgTypes[0]:=TypeOf(AN.A) END; AC:=1
        ELSIF NOT Direct THEN CalleeValue:=Expr(N.A)
        END;
        ArgNode:=N.B;
        WHILE (ArgNode#0) AND (AC<MaxCallArgs) DO
            AN:=AST.Get(ArgNode);
            IF (CalleeTy#0) AND (AC<Signatures.ParameterCount(CalleeTy)) AND Signatures.ParameterByRef(CalleeTy,AC) THEN Args[AC]:=AddressOfExpr(ArgNode); ArgTypes[AC]:=Types.Builtin('ADDRESS')
            ELSE
                Args[AC]:=Expr(ArgNode); ArgTypes[AC]:=TypeOf(ArgNode);
                IF (CalleeTy#0) AND (AC<Signatures.ParameterCount(CalleeTy)) THEN
                    Ty:=Signatures.ParameterType(CalleeTy,AC); Args[AC]:=CoerceValue(Args[AC],ArgNode,ArgTypes[AC],Ty); ArgTypes[AC]:=Ty
                ELSIF (CalleeTy#0) AND Signatures.IsVariadic(CalleeTy) THEN
                    IF ScalarKind(ArgTypes[AC])=TyR32 THEN Ty:=Types.Builtin('REAL64'); Args[AC]:=ConvertValue(Args[AC],ArgTypes[AC],Ty); ArgTypes[AC]:=Ty
                    ELSIF ScalarKind(ArgTypes[AC])=TyBoolean THEN Ty:=Types.Builtin('INTEGER32'); Args[AC]:=ConvertValue(Args[AC],ArgTypes[AC],Ty); ArgTypes[AC]:=Ty
                    ELSIF Types.IsInteger(ArgTypes[AC]) THEN T:=Types.Get(ArgTypes[AC]); IF T.Size<4 THEN Ty:=Types.Builtin('INTEGER32'); Args[AC]:=ConvertValue(Args[AC],ArgTypes[AC],Ty); ArgTypes[AC]:=Ty END
                    END
                END
            END;
            INC(AC); ArgNode:=AN.Next
        END;
        IF ArgNode#0 THEN SimpleCode(Error,ETooManyCallArgs,'more than 64 call arguments are not supported by native ABI lowering') END;
        GPR:=0; SSE:=0; StackArgs:=0; J:=0;
        WHILE J<AC DO
            ABIInfo(ArgTypes[J],ArgClass[J],ArgSupported);
            IF NOT ArgSupported THEN
                SimpleCode(Error,EUnsupportedABIArg,'SysV ABI passes this argument through memory; use REF/POINTER for this C interface');
                ArgClass[J].Count:=1; ArgClass[J].A:=ABI.IntegerClass
            END;
            AllocateABI(ArgClass[J],GPR,SSE,StackArgs,ArgLocA[J],ArgLocB[J]); INC(J)
        END;
        (* Stack arguments are emitted from right to left.  Two-eightbyte aggregates put the high eightbyte first. *)
        J:=AC; WHILE J>0 DO DEC(J);
            IF (ArgClass[J].Count>=2) AND (ArgLocB[J]>=LocStack) THEN I:=Emit(Current,OpArg,0,Args[J],0,VAL(LONGINT,ArgLocB[J])); X:=GetInst(I); X.TypeId:=ArgTypes[J]; X.Label:=StackArgs*2+1; PutInst(I,X) END;
            IF (ArgClass[J].Count>=1) AND (ArgLocA[J]>=LocStack) THEN I:=Emit(Current,OpArg,0,Args[J],0,VAL(LONGINT,ArgLocA[J])); X:=GetInst(I); X.TypeId:=ArgTypes[J]; X.Label:=StackArgs*2; PutInst(I,X) END
        END;
        J:=0; WHILE J<AC DO
            IF (ArgClass[J].Count>=1) AND (ArgLocA[J]<LocStack) THEN I:=Emit(Current,OpArg,0,Args[J],0,VAL(LONGINT,ArgLocA[J])); X:=GetInst(I); X.TypeId:=ArgTypes[J]; X.Label:=StackArgs*2; PutInst(I,X) END;
            IF (ArgClass[J].Count>=2) AND (ArgLocB[J]<LocStack) THEN I:=Emit(Current,OpArg,0,Args[J],0,VAL(LONGINT,ArgLocB[J])); X:=GetInst(I); X.TypeId:=ArgTypes[J]; X.Label:=StackArgs*2+1; PutInst(I,X) END;
            INC(J)
        END;
        ABI.ClassifySysV(TypeOf(Nid),RetClass); IF RetClass.A=ABI.MemoryClass THEN SimpleCode(Error,EUnsupportedABIReturn,'return values larger than 16 bytes must use an explicit result pointer') END;
        V:=NewTypedValue(TypeOf(Nid));
        IF Direct THEN I:=Emit(Current,OpCall,V,0,0,VAL(LONGINT,StackArgs))
        ELSE I:=Emit(Current,OpCallIndirect,V,CalleeValue,0,VAL(LONGINT,StackArgs))
        END;
        X:=GetInst(I); IF Direct THEN Assign(X.Text,Name) END; X.TypeId:=TypeOf(Nid); X.Label:=SSE; PutInst(I,X); RETURN V
    | NAddressOf:
        RETURN AddressOfExpr(N.A)
    | NSelect:
        IF 2 IN N.Flags THEN V:=NewValue(Current); I:=Emit(Current,OpConstI,V,0,0,N.IntValue); X:=GetInst(I); IF 7 IN N.Flags THEN Assign(X.Text,N.Text) END; X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V END;
        Bn:=AST.Get(N.A);
        IF (Bn.Kind=NName) AND Interfaces.FindVisible(ModuleName,Bn.Text,N.Text,IM) AND (IM.Kind=Interfaces.MemberProcedure) THEN
            V:=NewValue(Current); I:=Emit(Current,OpAddrGlobal,V,0,0,0); X:=GetInst(I);
            IF IM.LinkName[0]#0C THEN Assign(X.Text,IM.LinkName) ELSE Assign(X.Text,IM.Module); Append(X.Text,'__'); Append(X.Text,IM.Name) END;
            X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
        END;
        Ty:=TypeOf(N.A);
        IF (Ty#0) AND Methods.Find(MethodOwner(Ty),N.Text,Meth) THEN
            V:=NewValue(Current); I:=Emit(Current,OpAddrGlobal,V,0,0,0); X:=GetInst(I); Assign(X.Text,Meth.LinkName); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
        END;
        IF (Bn.Kind=NName) AND Interfaces.FindVisible(ModuleName,Bn.Text,N.Text,IM) AND ((IM.Kind=Interfaces.MemberConst) OR (IM.Kind=Interfaces.MemberVar)) THEN
            IF IsAggregate(TypeOf(Nid)) THEN
                Ptr:=NewValue(Current); I:=Emit(Current,OpAddrGlobal,Ptr,0,0,0); X:=GetInst(I);
                IF IM.LinkName[0]#0C THEN Assign(X.Text,IM.LinkName) ELSE Assign(X.Text,Bn.Text); Append(X.Text,'__'); Append(X.Text,N.Text) END; PutInst(I,X); RETURN LoadAggregate(Ptr,TypeOf(Nid))
            END;
            V:=NewTypedValue(TypeOf(Nid)); I:=Emit(Current,OpLoad,V,0,0,0); X:=GetInst(I);
            IF IM.LinkName[0]#0C THEN Assign(X.Text,IM.LinkName) ELSE Assign(X.Text,Bn.Text); Append(X.Text,'__'); Append(X.Text,N.Text) END; X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
        END;
        Ty:=TypeOf(N.A); IF Ty#0 THEN T:=Types.Get(Ty) END;
        IF (Ty#0) AND (T.Kind=TySlice) THEN A:=Expr(N.A); IF Equal(N.Text,'Data') THEN RETURN PartValue(A,0) ELSIF Equal(N.Text,'Length') THEN RETURN PartValue(A,1) END END;
        IF (Ty#0) AND (T.Kind=TyArray) AND Equal(N.Text,'Length') THEN
            V:=NewValue(Current); ElemT:=Types.Get(T.Base);
            IF ElemT.Size=0 THEN B:=0 ELSE B:=T.Size DIV ElemT.Size END;
            I:=Emit(Current,OpConstI,V,0,0,VAL(LONGINT,B)); RETURN V
        END;
        IF (Ty#0) AND ((T.Kind=TyString) OR (T.Kind=TyCString)) THEN
            A:=Expr(N.A); IF Equal(N.Text,'Data') THEN RETURN A END;
            IF Equal(N.Text,'Length') THEN I:=Emit(Current,OpArg,0,A,0,0); X:=GetInst(I); X.TypeId:=Types.Builtin('CSTRING'); PutInst(I,X); V:=NewValue(Current); I:=Emit(Current,OpCall,V,0,0,0); X:=GetInst(I); Assign(X.Text,'strlen'); X.TypeId:=Types.Builtin('SIZE'); PutInst(I,X); RETURN V END
        END;
        Ptr:=AddressOfExpr(Nid); IF Ptr=0 THEN RETURN 0 END; IF IsAggregate(TypeOf(Nid)) THEN RETURN LoadAggregate(Ptr,TypeOf(Nid)) END; V:=NewTypedValue(TypeOf(Nid)); I:=Emit(Current,OpLoadPtr,V,Ptr,0,0); X:=GetInst(I); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
    | NIndex:
        IF N.Text[0]#0C THEN V:=NewValue(Current); I:=Emit(Current,OpAddrGlobal,V,0,0,0); X:=GetInst(I); Assign(X.Text,N.Text); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V END;
        Ptr:=AddressOfExpr(Nid); IF Ptr=0 THEN RETURN 0 END; IF IsAggregate(TypeOf(Nid)) THEN RETURN LoadAggregate(Ptr,TypeOf(Nid)) END; V:=NewTypedValue(TypeOf(Nid)); I:=Emit(Current,OpLoadPtr,V,Ptr,0,0); X:=GetInst(I); X.TypeId:=TypeOf(Nid);
        Ty:=TypeOf(N.A); IF Ty#0 THEN T:=Types.Get(Ty); IF (T.Kind=TyString) OR (T.Kind=TyCString) THEN X.TypeId:=Types.Builtin('BYTE') END END;
        PutInst(I,X); RETURN V
    | NDeref:
        Ptr:=AddressOfExpr(Nid); IF Ptr=0 THEN RETURN 0 END; IF IsAggregate(TypeOf(Nid)) THEN RETURN LoadAggregate(Ptr,TypeOf(Nid)) END; V:=NewTypedValue(TypeOf(Nid)); I:=Emit(Current,OpLoadPtr,V,Ptr,0,0); X:=GetInst(I); X.TypeId:=TypeOf(Nid);
        PutInst(I,X); RETURN V
    | NSizeOf,NAlignOf:
        V:=NewValue(Current); I:=Emit(Current,OpConstI,V,0,0,N.IntValue); X:=GetInst(I); X.TypeId:=TypeOf(Nid); PutInst(I,X); RETURN V
    | NNew:
        (* NEW is the managed allocation primitive.  REF values come from the
           Hilbert collector; raw POINTER/ADDRESS memory stays in Memory.*. *)
        SizeV:=NewValue(Current); I:=Emit(Current,OpConstI,SizeV,0,0,N.IntValue); X:=GetInst(I); X.TypeId:=Types.Builtin('SIZE'); PutInst(I,X);
        I:=Emit(Current,OpArg,0,SizeV,0,0); X:=GetInst(I); X.TypeId:=Types.Builtin('SIZE'); X.Label:=0; PutInst(I,X);
        V:=NewValue(Current); I:=Emit(Current,OpCall,V,0,0,0); X:=GetInst(I); Assign(X.Text,'hilbert_gc_alloc'); X.TypeId:=TypeOf(Nid); X.Label:=0; PutInst(I,X); RETURN V
    | NStart:
        IF NOT TaskTarget(N.A,TaskName) THEN SimpleCode(Error,ETaskLowering,'START requires a zero-argument procedure or task call'); RETURN 0 END;
        V:=NewValue(Current); I:=Emit(Current,OpTaskStart,V,0,0,0); X:=GetInst(I); Assign(X.Text,TaskName); X.TypeId:=Types.Builtin('ADDRESS'); PutInst(I,X); RETURN V
    | NAwait:
        A:=Expr(N.A); EmitDiscard(OpTaskAwait,0,A,0,0); RETURN 0
    ELSE RETURN 0
    END
END Expr;

PROCEDURE EmitDefersFrom(Base:CARDINAL);
VAR I:CARDINAL;
BEGIN I:=DeferCount; WHILE I>Base DO DEC(I); Stmt(Defers[I]) END END EmitDefersFrom;

PROCEDURE List(Nid:NodeId);
VAR I:NodeId; N:Node; Base:CARDINAL;
BEGIN
    Base:=DeferCount; I:=Nid;
    WHILE I#0 DO N:=AST.Get(I); IF N.Kind=NDefer THEN IF DeferCount<=HIGH(Defers) THEN Defers[DeferCount]:=N.A; INC(DeferCount) ELSE SimpleCode(Fatal,EInternalInvariant,'too many active DEFER statements') END ELSE Stmt(I) END; I:=N.Next END;
    EmitDefersFrom(Base); DeferCount:=Base
END List;

PROCEDURE Stmt(Nid:NodeId);
VAR N,Lhs,Arm,VN,Branch,Only:Node; A,B,C,Slot,EndSlot,StepSlot,Cmp,BasePtr,Idx,LenV,Scale,Off,Elem:ValueId; I:InstId; X:Inst;
    L1,L2,L3,L4,ParallelCount,J,LocalBase:CARDINAL; Name,TaskName:Text; P,Q:NodeId; Ty,ElemTy,ControlTy:TypeId; TT,ET:Type; ControlGlobal:BOOLEAN; ParallelHandles:ARRAY [0..MaxParallelBranches-1] OF ValueId;
BEGIN
    IF Nid=0 THEN RETURN END; N:=AST.Get(Nid);
    CASE N.Kind OF
    | NBlock: LocalBase:=LocalCount; List(N.A); LocalCount:=LocalBase
    | NAssign:
        Lhs:=AST.Get(N.A); A:=0;
        IF (Lhs.Kind=NDeref) OR (Lhs.Kind=NSelect) OR (Lhs.Kind=NIndex) THEN A:=AddressOfExpr(N.A) END;
        B:=Expr(N.B); B:=CoerceValue(B,N.B,TypeOf(N.B),TypeOf(N.A));
        IF Lhs.Kind=NName THEN
            Slot:=FindLocal(Lhs.Text);
            IF Slot#0 THEN
                IF LocalByRef(Lhs.Text) THEN IF IsAggregate(TypeOf(N.A)) THEN StoreAggregate(Slot,B,TypeOf(N.A)) ELSE I:=Emit(Current,OpStorePtr,0,Slot,B,0); X:=GetInst(I); X.TypeId:=TypeOf(N.A); PutInst(I,X) END
                ELSIF IsAggregate(TypeOf(N.A)) THEN CopyAggregate(Slot,B,TypeOf(N.A)) ELSE EmitDiscard(OpMove,Slot,B,0,0) END
            ELSIF IsAggregate(TypeOf(N.A)) THEN A:=NewValue(Current); I:=Emit(Current,OpAddrGlobal,A,0,0,0); X:=GetInst(I); MangleLocal(Lhs.Text,Name); Assign(X.Text,Name); PutInst(I,X); StoreAggregate(A,B,TypeOf(N.A))
            ELSE I:=Emit(Current,OpStore,0,B,0,0); X:=GetInst(I); MangleLocal(Lhs.Text,Name); Assign(X.Text,Name); X.TypeId:=TypeOf(N.A); PutInst(I,X)
            END
        ELSIF (Lhs.Kind=NDeref) OR (Lhs.Kind=NSelect) OR (Lhs.Kind=NIndex) THEN
            IF IsAggregate(TypeOf(N.A)) THEN StoreAggregate(A,B,TypeOf(N.A)) ELSE I:=Emit(Current,OpStorePtr,0,A,B,0); X:=GetInst(I); X.TypeId:=TypeOf(N.A); PutInst(I,X) END
        ELSE SimpleCode(Error,EAddressableRequired,'left side is not an addressable value') END
    | NReturn:
        A:=Expr(N.A); IF (N.A#0) AND (CurrentReturn#0) THEN A:=CoerceValue(A,N.A,TypeOf(N.A),CurrentReturn) END;
        EmitDefersFrom(0); I:=Emit(Current,OpRet,0,A,0,0); X:=GetInst(I); X.TypeId:=CurrentReturn; PutInst(I,X)
    | NAssert:
        A:=Expr(N.A); EmitDiscard(OpAssert,0,A,0,0)
    | NIf:
        L1:=Label(); L2:=Label(); A:=Expr(N.A);
        I:=Emit(Current,OpBranch,0,A,0,0); X:=GetInst(I); X.Label:=L1; PutInst(I,X);
        Stmt(N.B); EmitJump(L2); EmitLabel(L1); Stmt(N.C); EmitLabel(L2)
    | NWhile:
        L1:=Label(); L2:=Label(); PushLoop(L2); EmitLabel(L1);
        A:=Expr(N.A); I:=Emit(Current,OpBranch,0,A,0,0); X:=GetInst(I); X.Label:=L2; PutInst(I,X);
        Stmt(N.B); EmitJump(L1); EmitLabel(L2); PopLoop
    | NRepeat:
        L1:=Label(); L2:=Label(); PushLoop(L2); EmitLabel(L1); Stmt(N.A); A:=Expr(N.B);
        I:=Emit(Current,OpBranch,0,A,0,0); X:=GetInst(I); X.Label:=L1; PutInst(I,X); EmitLabel(L2); PopLoop
    | NLoop:
        L1:=Label(); L2:=Label(); PushLoop(L2); EmitLabel(L1); Stmt(N.A); EmitJump(L1); EmitLabel(L2); PopLoop
    | NExit:
        IF LoopDepth=0 THEN SimpleCode(Error,EExitOutsideLoop,'EXIT used outside loop')
        ELSE EmitDefersFrom(LoopDeferBase[LoopDepth-1]); EmitJump(LoopEnds[LoopDepth-1])
        END
    | NFor:
        LocalBase:=LocalCount; ControlTy:=TypeOf(Nid); IF ControlTy=0 THEN ControlTy:=Types.Builtin('INTEGER') END;
        Slot:=FindLocal(N.Text); ControlGlobal:=Slot=0; IF ControlGlobal THEN Slot:=AddLocal(N.Text,ControlTy,FALSE) END;
        A:=Expr(N.A); A:=CoerceValue(A,N.A,TypeOf(N.A),ControlTy); EmitDiscard(OpMove,Slot,A,0,0);
        IF ControlGlobal THEN I:=Emit(Current,OpStore,0,Slot,0,0); X:=GetInst(I); MangleLocal(N.Text,Name); Assign(X.Text,Name); X.TypeId:=ControlTy; PutInst(I,X) END;
        EndSlot:=NewTypedValue(ControlTy); B:=Expr(N.B); B:=CoerceValue(B,N.B,TypeOf(N.B),ControlTy); EmitDiscard(OpMove,EndSlot,B,0,0);
        StepSlot:=NewTypedValue(ControlTy);
        IF N.C#0 THEN C:=Expr(N.C); C:=CoerceValue(C,N.C,TypeOf(N.C),ControlTy); EmitDiscard(OpMove,StepSlot,C,0,0)
        ELSE C:=NewTypedValue(ControlTy); EmitDiscard(OpConstI,C,0,0,1); EmitDiscard(OpMove,StepSlot,C,0,0)
        END;
        A:=NewTypedValue(ControlTy); I:=Emit(Current,OpConstI,A,0,0,0); X:=GetInst(I); X.TypeId:=ControlTy; PutInst(I,X);
        Cmp:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpCmpNe,Cmp,StepSlot,A,0); X:=GetInst(I); X.TypeId:=ControlTy; PutInst(I,X); EmitDiscard(OpAssert,0,Cmp,0,0);
        L1:=Label(); L2:=Label(); L3:=Label(); L4:=Label(); PushLoop(L2); EmitLabel(L1);
        (* Positive and negative BY values use the matching inclusive bound test. *)
        A:=NewTypedValue(ControlTy); EmitDiscard(OpConstI,A,0,0,0); Cmp:=NewValue(Current); I:=Emit(Current,OpCmpGe,Cmp,StepSlot,A,0); X:=GetInst(I); X.TypeId:=ControlTy; PutInst(I,X);
        I:=Emit(Current,OpBranch,0,Cmp,0,0); X:=GetInst(I); X.Label:=L3; PutInst(I,X);
        Cmp:=NewValue(Current); I:=Emit(Current,OpCmpLe,Cmp,Slot,EndSlot,0); X:=GetInst(I); X.TypeId:=ControlTy; PutInst(I,X); I:=Emit(Current,OpBranch,0,Cmp,0,0); X:=GetInst(I); X.Label:=L2; PutInst(I,X); EmitJump(L4);
        EmitLabel(L3); Cmp:=NewValue(Current); I:=Emit(Current,OpCmpGe,Cmp,Slot,EndSlot,0); X:=GetInst(I); X.TypeId:=ControlTy; PutInst(I,X); I:=Emit(Current,OpBranch,0,Cmp,0,0); X:=GetInst(I); X.Label:=L2; PutInst(I,X);
        EmitLabel(L4); Stmt(N.D); C:=NewTypedValue(ControlTy); I:=Emit(Current,OpAdd,C,Slot,StepSlot,0); X:=GetInst(I); X.TypeId:=ControlTy; PutInst(I,X); EmitDiscard(OpMove,Slot,C,0,0);
        IF ControlGlobal THEN I:=Emit(Current,OpStore,0,Slot,0,0); X:=GetInst(I); MangleLocal(N.Text,Name); Assign(X.Text,Name); X.TypeId:=ControlTy; PutInst(I,X) END;
        EmitJump(L1); EmitLabel(L2); PopLoop; LocalCount:=LocalBase
    | NForIn:
        LocalBase:=LocalCount; Ty:=TypeOf(N.A); IF Ty=0 THEN SimpleCode(Error,EForIterator,'FOR IN iterable has no type'); RETURN END; TT:=Types.Get(Ty); ElemTy:=TypeOf(Nid);
        IF ElemTy=0 THEN SimpleCode(Error,EForIterator,'FOR IN element type is unknown'); RETURN END; ET:=Types.Get(ElemTy); Slot:=AddLocal(N.Text,ElemTy,FALSE);
        IF TT.Kind=TyArray THEN
            BasePtr:=AddressOfExpr(N.A); LenV:=NewValue(Current); IF ET.Size=0 THEN C:=0 ELSE C:=TT.Size DIV ET.Size END; EmitDiscard(OpConstI,LenV,0,0,VAL(LONGINT,C))
        ELSIF TT.Kind=TySlice THEN
            A:=Expr(N.A); BasePtr:=PartValue(A,0); LenV:=PartValue(A,1)
        ELSE SimpleCode(Error,EForIterator,'FOR IN expects ARRAY or SLICE'); RETURN
        END;
        Idx:=NewValue(Current); EmitDiscard(OpConstI,Idx,0,0,0); L1:=Label(); L2:=Label(); PushLoop(L2); EmitLabel(L1);
        Cmp:=NewValue(Current); I:=Emit(Current,OpCmpLt,Cmp,Idx,LenV,0); X:=GetInst(I); X.TypeId:=Types.Builtin('SIZE'); PutInst(I,X); I:=Emit(Current,OpBranch,0,Cmp,0,0); X:=GetInst(I); X.Label:=L2; PutInst(I,X);
        Scale:=NewValue(Current); EmitDiscard(OpConstI,Scale,0,0,VAL(LONGINT,ET.Size)); Off:=NewValue(Current); EmitDiscard(OpMul,Off,Idx,Scale,0); Elem:=NewValue(Current); EmitDiscard(OpAdd,Elem,BasePtr,Off,0);
        IF IsAggregate(ElemTy) THEN B:=LoadAggregate(Elem,ElemTy); CopyAggregate(Slot,B,ElemTy)
        ELSE B:=NewTypedValue(ElemTy); I:=Emit(Current,OpLoadPtr,B,Elem,0,0); X:=GetInst(I); X.TypeId:=ElemTy; PutInst(I,X); EmitDiscard(OpMove,Slot,B,0,0) END;
        Stmt(N.D); A:=NewValue(Current); EmitDiscard(OpConstI,A,0,0,1); B:=NewValue(Current); I:=Emit(Current,OpAdd,B,Idx,A,0); X:=GetInst(I); X.TypeId:=Types.Builtin('SIZE'); PutInst(I,X); EmitDiscard(OpMove,Idx,B,0,0); EmitJump(L1); EmitLabel(L2); PopLoop; LocalCount:=LocalBase
    | NCase:
        A:=Expr(N.A); L3:=Label(); P:=N.B;
        WHILE P#0 DO
            Arm:=AST.Get(P); Q:=Arm.A;
            WHILE Q#0 DO
                VN:=AST.Get(Q); B:=Expr(Q); Cmp:=NewValue(Current); EmitDiscard(OpCmpEq,Cmp,A,B,0);
                L1:=Label(); I:=Emit(Current,OpBranch,0,Cmp,0,0); X:=GetInst(I); X.Label:=L1; PutInst(I,X);
                Stmt(Arm.B); EmitJump(L3); EmitLabel(L1); Q:=VN.Next
            END;
            P:=Arm.Next
        END;
        Stmt(N.C); EmitLabel(L3)
    | NUnsafe:
        Stmt(N.A)
    | NWith:
        Stmt(N.B)
    | NDefer:
        (* handled by List so cleanup order is lexical *)
    | NParallel:
        IF N.A=0 THEN SimpleCode(Error,EParallelLowering,'PARALLEL needs at least one branch'); RETURN END;
        Branch:=AST.Get(N.A);
        IF Branch.Kind=NForIn THEN
            SimpleCode(Error,EParallelLowering,'PARALLEL FOR lowering is not available in the 1.0 x86-64 backend')
        ELSE
            ParallelCount:=0; P:=N.A;
            WHILE P#0 DO
                IF ParallelCount>=MaxParallelBranches THEN SimpleCode(Error,EParallelLowering,'too many PARALLEL branches'); RETURN END;
                Branch:=AST.Get(P); IF Branch.Kind#NBlock THEN SimpleCode(Error,EParallelLowering,'PARALLEL branch is not a block'); RETURN END;
                IF Branch.A=0 THEN SimpleCode(Error,EParallelLowering,'PARALLEL branch is empty'); RETURN END;
                Only:=AST.Get(Branch.A); IF Only.Next#0 THEN SimpleCode(Error,EParallelLowering,'PARALLEL branches currently contain one zero-argument call each'); RETURN END;
                IF NOT TaskTarget(Branch.A,TaskName) THEN SimpleCode(Error,EParallelLowering,'PARALLEL branch must be a zero-argument procedure or task call'); RETURN END;
                ParallelHandles[ParallelCount]:=NewValue(Current); I:=Emit(Current,OpTaskStart,ParallelHandles[ParallelCount],0,0,0); X:=GetInst(I); Assign(X.Text,TaskName); X.TypeId:=Types.Builtin('ADDRESS'); PutInst(I,X);
                INC(ParallelCount); P:=Branch.Next
            END;
            J:=0; WHILE J<ParallelCount DO EmitDiscard(OpTaskAwait,0,ParallelHandles[J],0,0); INC(J) END
        END
    | NStart,NAwait:
        A:=Expr(Nid)
    | NRaise:
        EmitDiscard(OpTrap,0,0,0,0)
    | NExcept:
        SimpleCode(Error,EExceptionLowering,'exception handler lowering is unavailable for this target')
    ELSE A:=Expr(Nid)
    END
END Stmt;

PROCEDURE RegisterForeigns(Decl:NodeId);
VAR I:NodeId; N,E:Node;
BEGIN
    ForeignCount:=0; I:=Decl;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF N.Kind=NForeign THEN
            IF ForeignCount<MaxForeign THEN
                Assign(ForeignNames[ForeignCount],N.Text);
                IF N.C#0 THEN E:=AST.Get(N.C); Assign(ForeignTargets[ForeignCount],E.Text)
                ELSE Assign(ForeignTargets[ForeignCount],N.Text)
                END;
                INC(ForeignCount)
            END
        END;
        I:=N.Next
    END
END RegisterForeigns;

PROCEDURE AddParameters(N:Node);
VAR P:NodeId; PN:Node; Slot:ValueId; I:InstId; X:Inst; Index,GPR,SSE,StackNo,LocA,LocB:CARDINAL; F:Func; Ty:TypeId; C:ABI.Classification; Supported:BOOLEAN;
BEGIN
    Index:=0; GPR:=0; SSE:=0; StackNo:=0;
    P:=ReceiverNode(N.D);
    IF P#0 THEN
        PN:=AST.Get(P); Ty:=TypeOf(P); IF 0 IN PN.Flags THEN Slot:=AddLocal(PN.Text,Ty,TRUE); ABI.ClassifySysV(Types.Builtin('ADDRESS'),C) ELSE Slot:=AddLocal(PN.Text,Ty,FALSE); ABIInfo(Ty,C,Supported) END;
        IF 0 IN PN.Flags THEN Supported:=TRUE END; IF NOT Supported THEN SimpleCode(Error,EUnsupportedABIArg,'receiver uses an unsupported by-value ABI shape'); C.Count:=1; C.A:=ABI.IntegerClass END;
        AllocateABI(C,GPR,SSE,StackNo,LocA,LocB); I:=Emit(Current,OpParam,PartValue(Slot,0),0,0,VAL(LONGINT,LocA)); X:=GetInst(I); Assign(X.Text,PN.Text); IF 0 IN PN.Flags THEN X.TypeId:=Types.Builtin('ADDRESS') ELSE X.TypeId:=Ty END; X.Label:=0; PutInst(I,X);
        IF C.Count>=2 THEN I:=Emit(Current,OpParam,PartValue(Slot,1),0,0,VAL(LONGINT,LocB)); X:=GetInst(I); Assign(X.Text,PN.Text); X.TypeId:=Ty; X.Label:=1; PutInst(I,X) END; INC(Index)
    END;
    P:=N.A;
    WHILE P#0 DO
        PN:=AST.Get(P); Ty:=TypeOf(P); IF 0 IN PN.Flags THEN Slot:=AddLocal(PN.Text,Ty,TRUE); ABI.ClassifySysV(Types.Builtin('ADDRESS'),C); Supported:=TRUE ELSE Slot:=AddLocal(PN.Text,Ty,FALSE); ABIInfo(Ty,C,Supported) END;
        IF NOT Supported THEN SimpleCode(Error,EUnsupportedABIArg,'SysV ABI receives this value through memory; declare it as VAR/REF/POINTER'); C.Count:=1; C.A:=ABI.IntegerClass END;
        AllocateABI(C,GPR,SSE,StackNo,LocA,LocB);
        IF C.Count>=1 THEN I:=Emit(Current,OpParam,PartValue(Slot,0),0,0,VAL(LONGINT,LocA)); X:=GetInst(I); Assign(X.Text,PN.Text); IF 0 IN PN.Flags THEN X.TypeId:=Types.Builtin('ADDRESS') ELSE X.TypeId:=Ty END; X.Label:=0; PutInst(I,X) END;
        IF C.Count>=2 THEN I:=Emit(Current,OpParam,PartValue(Slot,1),0,0,VAL(LONGINT,LocB)); X:=GetInst(I); Assign(X.Text,PN.Text); X.TypeId:=Ty; X.Label:=1; PutInst(I,X) END;
        INC(Index); P:=PN.Next
    END;
    F:=GetFunc(Current); F.ParamCount:=Index; PutFunc(Current,F)
END AddParameters;

PROCEDURE AddMetadataLocals(Meta:NodeId);
VAR P:NodeId; N:Node; Slot,V:ValueId;
BEGIN
    P:=Meta;
    WHILE P#0 DO
        N:=AST.Get(P);
        IF N.Kind=NReceiver THEN (* receiver is materialized by AddParameters *)
        ELSIF N.Kind=NVar THEN Slot:=AddLocal(N.Text,TypeOf(P),FALSE); ZeroLocal(Slot,TypeOf(P)); IF N.B#0 THEN V:=Expr(N.B); V:=CoerceValue(V,N.B,TypeOf(N.B),TypeOf(P)); IF IsAggregate(TypeOf(P)) THEN CopyAggregate(Slot,V,TypeOf(P)) ELSE EmitDiscard(OpMove,Slot,V,0,0) END END
        ELSIF N.Kind=NConst THEN Slot:=AddLocal(N.Text,TypeOf(P),FALSE); V:=Expr(N.A); V:=CoerceValue(V,N.A,TypeOf(N.A),TypeOf(P)); IF IsAggregate(TypeOf(P)) THEN CopyAggregate(Slot,V,TypeOf(P)) ELSE EmitDiscard(OpMove,Slot,V,0,0) END
        ELSIF N.Kind=NPre THEN V:=Expr(N.A); EmitDiscard(OpAssert,0,V,0,0)
        END;
        P:=N.Next
    END
END AddMetadataLocals;

PROCEDURE AddModuleGlobals(Decl:NodeId);
VAR I:NodeId; N:Node; Name:Text; T:Type; G:CARDINAL;
BEGIN
    I:=Decl;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF (N.Kind=NVar) OR (N.Kind=NConst) THEN
            Assign(Name,ModuleName); Append(Name,'__'); Append(Name,N.Text);
            IF TypeOf(I)#0 THEN T:=Types.Get(TypeOf(I)); G:=HIR.NewGlobal(Name,T.Size,T.Align) ELSE G:=HIR.NewGlobal(Name,8,8) END
        END;
        I:=N.Next
    END
END AddModuleGlobals;


PROCEDURE EmitModuleInitGuard;
VAR StatePtr,State,Zero,One,Two,Done,Unclaimed,Won:ValueId; I:InstId; X:Inst; RetryLabel,NotDone:CARDINAL; Name:Text; StateTy:TypeId;
BEGIN
    StateTy:=Types.Builtin('CARDINAL32'); Assign(Name,ModuleName); Append(Name,'__init_state');
    StatePtr:=NewTypedValue(Types.Builtin('ADDRESS')); I:=Emit(Current,OpAddrGlobal,StatePtr,0,0,0); X:=GetInst(I); Assign(X.Text,Name); X.TypeId:=Types.Builtin('ADDRESS'); PutInst(I,X);
    Zero:=NewTypedValue(StateTy); EmitDiscard(OpConstI,Zero,0,0,0);
    One:=NewTypedValue(StateTy); EmitDiscard(OpConstI,One,0,0,1);
    Two:=NewTypedValue(StateTy); EmitDiscard(OpConstI,Two,0,0,2);
    RetryLabel:=Label(); NotDone:=Label(); EmitLabel(RetryLabel);
    State:=NewTypedValue(StateTy); I:=Emit(Current,OpAtomicLoad,State,StatePtr,0,0); X:=GetInst(I); X.TypeId:=StateTy; PutInst(I,X);
    Done:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpCmpEq,Done,State,Two,0); X:=GetInst(I); X.TypeId:=StateTy; PutInst(I,X);
    I:=Emit(Current,OpBranch,0,Done,0,0); X:=GetInst(I); X.Label:=NotDone; PutInst(I,X);
    EmitDiscard(OpRet,0,0,0,0);
    EmitLabel(NotDone);
    Unclaimed:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpCmpEq,Unclaimed,State,Zero,0); X:=GetInst(I); X.TypeId:=StateTy; PutInst(I,X);
    I:=Emit(Current,OpBranch,0,Unclaimed,0,0); X:=GetInst(I); X.Label:=RetryLabel; PutInst(I,X);
    Won:=NewTypedValue(Types.Builtin('BOOLEAN')); I:=Emit(Current,OpAtomicCAS,Won,StatePtr,One,0); X:=GetInst(I); X.Label:=Zero; X.TypeId:=StateTy; PutInst(I,X);
    I:=Emit(Current,OpBranch,0,Won,0,0); X:=GetInst(I); X.Label:=RetryLabel; PutInst(I,X)
END EmitModuleInitGuard;

PROCEDURE EmitModuleInitComplete;
VAR StatePtr,Done:ValueId; I:InstId; X:Inst; Name:Text; StateTy:TypeId;
BEGIN
    StateTy:=Types.Builtin('CARDINAL32'); Assign(Name,ModuleName); Append(Name,'__init_state');
    StatePtr:=NewTypedValue(Types.Builtin('ADDRESS')); I:=Emit(Current,OpAddrGlobal,StatePtr,0,0,0); X:=GetInst(I); Assign(X.Text,Name); X.TypeId:=Types.Builtin('ADDRESS'); PutInst(I,X);
    Done:=NewTypedValue(StateTy); EmitDiscard(OpConstI,Done,0,0,2);
    I:=Emit(Current,OpAtomicStore,0,StatePtr,Done,0); X:=GetInst(I); X.TypeId:=StateTy; PutInst(I,X)
END EmitModuleInitComplete;

PROCEDURE EmitImportInitializers(Decl:NodeId);
VAR I:NodeId; N:Node; InstNo:InstId; X:Inst; Name:Text; V:ValueId;
BEGIN
    I:=Decl;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF N.Kind=NImport THEN
            Assign(Name,N.Text); Append(Name,'__init'); V:=NewValue(Current);
            InstNo:=Emit(Current,OpCall,V,0,0,0); X:=GetInst(InstNo); Assign(X.Text,Name); PutInst(InstNo,X)
        END;
        I:=N.Next
    END
END EmitImportInitializers;

PROCEDURE InitModuleVariables(Decl:NodeId);
VAR I:NodeId; N:Node; V:ValueId; InstNo:InstId; X:Inst; Name:Text;
BEGIN
    I:=Decl;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF ((N.Kind=NVar) AND (N.B#0)) OR (N.Kind=NConst) THEN
            IF N.Kind=NConst THEN V:=Expr(N.A); V:=CoerceValue(V,N.A,TypeOf(N.A),TypeOf(I)) ELSE V:=Expr(N.B); V:=CoerceValue(V,N.B,TypeOf(N.B),TypeOf(I)) END;
            Assign(Name,ModuleName); Append(Name,'__'); Append(Name,N.Text);
            IF IsAggregate(TypeOf(I)) THEN
                InstNo:=Emit(Current,OpAddrGlobal,NewValue(Current),0,0,0); X:=GetInst(InstNo); Assign(X.Text,Name); PutInst(InstNo,X); StoreAggregate(X.Dst,V,TypeOf(I))
            ELSE
                InstNo:=Emit(Current,OpStore,0,V,0,0); X:=GetInst(InstNo); Assign(X.Text,Name); X.TypeId:=TypeOf(I); PutInst(InstNo,X)
            END
        END;
        I:=N.Next
    END
END InitModuleVariables;

PROCEDURE EmitMainArguments(Decl:NodeId);
VAR I:NodeId; N:Node; ArgCount,ArgVector:ValueId; InstNo:InstId; X:Inst; F:Func;
BEGIN
    I:=Decl;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF (N.Kind=NImport) AND Equal(N.Text,'Arguments') THEN
            (* A native C entry point receives argc/argv in the first two SysV
               integer argument registers.  Capture them before imported module
               initializers can clobber those registers, then publish them to the
               first-party Arguments module. *)
            ArgCount:=NewValue(Current);
            InstNo:=Emit(Current,OpParam,ArgCount,0,0,0); X:=GetInst(InstNo);
            X.TypeId:=Types.Builtin('INTEGER'); X.Label:=0; PutInst(InstNo,X);
            InstNo:=Emit(Current,OpStore,0,ArgCount,0,0); X:=GetInst(InstNo);
            Assign(X.Text,'Arguments__ArgCount'); X.TypeId:=Types.Builtin('INTEGER'); PutInst(InstNo,X);

            ArgVector:=NewValue(Current);
            InstNo:=Emit(Current,OpParam,ArgVector,0,0,1); X:=GetInst(InstNo);
            X.TypeId:=Types.Builtin('ADDRESS'); X.Label:=0; PutInst(InstNo,X);
            InstNo:=Emit(Current,OpStore,0,ArgVector,0,0); X:=GetInst(InstNo);
            Assign(X.Text,'Arguments__ArgVector'); X.TypeId:=Types.Builtin('ADDRESS'); PutInst(InstNo,X);
            F:=GetFunc(Current); F.ParamCount:=2; PutFunc(Current,F);
            RETURN
        END;
        I:=N.Next
    END
END EmitMainArguments;

PROCEDURE Run(Root:NodeId; IsMain:BOOLEAN):BOOLEAN;
VAR R,N:Node; I:NodeId; Name:Text; V:ValueId; IgnoredGlobal:CARDINAL; InstNo:InstId; X:Inst; ProcType:Types.Type;
BEGIN
    HIR.Init; NextLabel:=0; R:=AST.Get(Root); Assign(ModuleName,R.Text); Declarations:=R.A; RegisterForeigns(R.A); RegisterTypeNames(R.A); AddModuleGlobals(R.A);
    IF NOT IsMain THEN Assign(Name,ModuleName); Append(Name,'__init_state'); IgnoredGlobal:=HIR.NewGlobal(Name,4,4) END;
    I:=R.A;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF ((N.Kind=NProcedure) OR (N.Kind=NTask)) AND NOT HasGenericParams(N.D) THEN
            ProcedureLink(N,Name); Current:=NewFunc(Name); ResetLocals;
            IF N.Kind=NTask THEN CurrentReturn:=Types.Builtin('VOID') ELSE ProcType:=Types.Get(TypeOf(I)); CurrentReturn:=ProcType.Result END;
            AddParameters(N); AddMetadataLocals(N.D); Stmt(N.C);
            IF CurrentReturn=Types.Builtin('VOID') THEN EmitDiscard(OpRet,0,0,0,0)
            ELSE EmitDiscard(OpTrap,0,0,0,0); V:=NewValue(Current); EmitDiscard(OpConstI,V,0,0,0); InstNo:=Emit(Current,OpRet,0,V,0,0); X:=GetInst(InstNo); X.TypeId:=CurrentReturn; PutInst(InstNo,X)
            END
        END;
        I:=N.Next
    END;
    IF IsMain THEN Assign(Name,'main') ELSE Assign(Name,ModuleName); Append(Name,'__init') END;
    Current:=NewFunc(Name); ResetLocals; CurrentReturn:=Types.Builtin('INTEGER');
    IF IsMain THEN EmitMainArguments(R.A) ELSE EmitModuleInitGuard END;
    EmitImportInitializers(R.A); InitModuleVariables(R.A); Stmt(R.B); IF NOT IsMain THEN EmitModuleInitComplete END; V:=NewValue(Current); EmitDiscard(OpConstI,V,0,0,0); EmitDiscard(OpRet,0,V,0,0);
    RETURN NOT HasErrors()
END Run;

END Lower.
