IMPLEMENTATION MODULE X64;

FROM HIR IMPORT FuncId,ValueId,InstId,Inst,Func,Global,Op,FuncCount,GetFunc,GetInst,GlobalCount,GetGlobal;
FROM Asm IMPORT Open,Close,Line;
FROM HStrings IMPORT Text,Assign,Append,AppendChar;
FROM Diagnostics IMPORT SimpleCode,Severity;
FROM ErrorCodes IMPORT EOutputCreate;
IMPORT Types, ABI;
FROM Types IMPORT Type,TypeKind,TypeId;

CONST LocSSE=16; LocStack=32;

PROCEDURE CardText(N:CARDINAL; VAR S:Text);
VAR D:ARRAY[0..31] OF CHAR; I,J:CARDINAL;
BEGIN
    S[0]:=0C; IF N=0 THEN AppendChar(S,'0'); RETURN END;
    I:=0; WHILE N>0 DO D[I]:=CHR(ORD('0')+(N MOD 10)); N:=N DIV 10; INC(I) END;
    J:=I; WHILE J>0 DO DEC(J); AppendChar(S,D[J]) END
END CardText;

PROCEDURE LongText(N:LONGINT; VAR S:Text);
VAR V:LONGCARD; D:ARRAY[0..31] OF CHAR; I,J:CARDINAL;
BEGIN
    S[0]:=0C;
    IF N=(-9223372036854775807-1) THEN Assign(S,'-9223372036854775808'); RETURN END;
    IF N<0 THEN AppendChar(S,'-'); V:=VAL(LONGCARD,-N) ELSE V:=VAL(LONGCARD,N) END;
    IF V=0 THEN AppendChar(S,'0') ELSE I:=0; WHILE V>0 DO D[I]:=CHR(ORD('0')+VAL(CARDINAL,V MOD 10)); V:=V DIV 10; INC(I) END; J:=I; WHILE J>0 DO DEC(J); AppendChar(S,D[J]) END END
END LongText;

PROCEDURE ImmediateLiteral(Source:ARRAY OF CHAR; VAR Out:Text);
VAR I:CARDINAL;
BEGIN
    (* GAS accepts 0x and 0b directly.  Its octal spelling is the traditional
       leading zero, while Hilbert uses the clearer 0o prefix. *)
    Out[0]:=0C;
    IF (Source[0]='0') AND ((Source[1]='o') OR (Source[1]='O')) THEN
        AppendChar(Out,'0'); I:=2; WHILE (I<=HIGH(Source)) AND (Source[I]#0C) DO AppendChar(Out,Source[I]); INC(I) END
    ELSE Assign(Out,Source)
    END
END ImmediateLiteral;

PROCEDURE Slot(V:CARDINAL; VAR S:Text);
VAR T:Text;
BEGIN Assign(S,'-'); CardText(V*8,T); Append(S,T); Append(S,'(%rbp)') END Slot;
PROCEDURE LabelText(N:CARDINAL; VAR S:Text);
VAR T:Text;
BEGIN Assign(S,'.L'); CardText(N,T); Append(S,T) END LabelText;
PROCEDURE ConstLabel(I:InstId; VAR S:Text);
VAR T:Text;
BEGIN Assign(S,'.Lconst'); CardText(I,T); Append(S,T) END ConstLabel;

PROCEDURE IsReal(Ty:CARDINAL):BOOLEAN;
VAR T:Type;
BEGIN
    IF Ty=0 THEN RETURN FALSE END; T:=Types.Get(Ty);
    WHILE (T.Kind=TyRange) OR (T.Kind=TyDistinct) OR (T.Kind=TyAtomic) DO Ty:=T.Base; IF Ty=0 THEN RETURN FALSE END; T:=Types.Get(Ty) END;
    RETURN (T.Kind=TyR32) OR (T.Kind=TyR64)
END IsReal;
PROCEDURE IsReal32(Ty:CARDINAL):BOOLEAN;
VAR T:Type;
BEGIN
    IF Ty=0 THEN RETURN FALSE END; T:=Types.Get(Ty);
    WHILE (T.Kind=TyRange) OR (T.Kind=TyDistinct) OR (T.Kind=TyAtomic) DO Ty:=T.Base; IF Ty=0 THEN RETURN FALSE END; T:=Types.Get(Ty) END;
    RETURN T.Kind=TyR32
END IsReal32;
PROCEDURE IsSigned32(Ty:CARDINAL):BOOLEAN;
VAR T:Type;
BEGIN IF Ty=0 THEN RETURN FALSE END; T:=Types.Get(Ty); RETURN T.Kind=TyI32 END IsSigned32;
PROCEDURE ScalarBase(Ty:TypeId):TypeKind;
VAR T:Type;
BEGIN
    IF Ty=0 THEN RETURN TyInvalid END; T:=Types.Get(Ty);
    WHILE (T.Kind=TyRange) OR (T.Kind=TyDistinct) OR (T.Kind=TyAtomic) DO Ty:=T.Base; IF Ty=0 THEN RETURN TyInvalid END; T:=Types.Get(Ty) END;
    RETURN T.Kind
END ScalarBase;

PROCEDURE IsSigned(Ty:TypeId):BOOLEAN;
VAR K:TypeKind;
BEGIN K:=ScalarBase(Ty); RETURN ((K>=TyI8) AND (K<=TyI64)) OR (K=TyInteger) END IsSigned;

PROCEDURE TypeSize(Ty:CARDINAL):CARDINAL;
VAR T:Type;
BEGIN IF Ty=0 THEN RETURN 8 END; T:=Types.Get(Ty); IF T.Size=0 THEN RETURN 8 END; RETURN T.Size END TypeSize;

PROCEDURE NormalizeRAX(Ty:TypeId);
VAR N:CARDINAL;
BEGIN
    N:=TypeSize(Ty);
    IF N=1 THEN IF IsSigned(Ty) THEN Line('    movsbq %al, %rax') ELSE Line('    movzbq %al, %rax') END
    ELSIF N=2 THEN IF IsSigned(Ty) THEN Line('    movswq %ax, %rax') ELSE Line('    movzwq %ax, %rax') END
    ELSIF N=4 THEN IF IsSigned(Ty) THEN Line('    movslq %eax, %rax') ELSE Line('    movl %eax, %eax') END
    END
END NormalizeRAX;

PROCEDURE IsAggregateType(Ty:TypeId):BOOLEAN;
VAR T:Type;
BEGIN IF Ty=0 THEN RETURN FALSE END; T:=Types.Get(Ty); RETURN (T.Kind=TyRecord) OR (T.Kind=TyProtected) OR (T.Kind=TyArray) OR (T.Kind=TySlice) OR (T.Kind=TyVariant) END IsAggregateType;

PROCEDURE PartSlot(Base,Part:CARDINAL; VAR S:Text);
BEGIN IF Part=0 THEN Slot(Base,S) ELSE Slot(Base-Part,S) END END PartSlot;

PROCEDURE PartClass(C:ABI.Classification; Part:CARDINAL):ABI.Class;
BEGIN IF Part=0 THEN RETURN C.A ELSE RETURN C.B END END PartClass;

PROCEDURE ReturnInSSE(Ty:TypeId):BOOLEAN;
VAR C:ABI.Classification;
BEGIN
    ABI.ClassifySysV(Ty,C);
    RETURN (C.Count=1) AND (C.A=ABI.SSEClass)
END ReturnInSSE;

PROCEDURE Xmm(Index:CARDINAL; VAR S:Text);
BEGIN
    CASE Index OF
    | 0:Assign(S,'%xmm0') | 1:Assign(S,'%xmm1') | 2:Assign(S,'%xmm2') | 3:Assign(S,'%xmm3')
    | 4:Assign(S,'%xmm4') | 5:Assign(S,'%xmm5') | 6:Assign(S,'%xmm6') | 7:Assign(S,'%xmm7')
    ELSE Assign(S,'%xmm0')
    END
END Xmm;

PROCEDURE EmitStore(V:CARDINAL; Reg:ARRAY OF CHAR);
VAR S,T:Text;
BEGIN Assign(S,'    movq '); Append(S,Reg); Append(S,', '); Slot(V,T); Append(S,T); Line(S) END EmitStore;
PROCEDURE EmitLoad(V:CARDINAL; Reg:ARRAY OF CHAR);
VAR S,T:Text;
BEGIN Assign(S,'    movq '); Slot(V,T); Append(S,T); Append(S,', '); Append(S,Reg); Line(S) END EmitLoad;
PROCEDURE EmitStoreFloat(V,Ty:CARDINAL; Reg:ARRAY OF CHAR);
VAR S,T:Text;
BEGIN
    IF TypeSize(Ty)=4 THEN Assign(S,'    movss ') ELSE Assign(S,'    movsd ') END; Append(S,Reg); Append(S,', '); Slot(V,T); Append(S,T); Line(S)
END EmitStoreFloat;
PROCEDURE EmitLoadFloat(V,Ty:CARDINAL; Reg:ARRAY OF CHAR);
VAR S,T:Text;
BEGIN
    IF TypeSize(Ty)=4 THEN Assign(S,'    movss ') ELSE Assign(S,'    movsd ') END; Slot(V,T); Append(S,T); Append(S,', '); Append(S,Reg); Line(S)
END EmitLoadFloat;

PROCEDURE RealKind(K:TypeKind):BOOLEAN;
BEGIN RETURN (K=TyR32) OR (K=TyR64) END RealKind;

PROCEDURE EmitCheckedRealToInteger(SourceTy,DestTy:TypeId);
VAR LowerBits,UpperBits,S:Text; Bytes:CARDINAL; Float32,Signed:BOOLEAN;
BEGIN
    Bytes:=TypeSize(DestTy); Float32:=ScalarBase(SourceTy)=TyR32; Signed:=IsSigned(DestTy);
    IF Signed THEN
        IF Float32 THEN
            CASE Bytes OF
            | 1:Assign(LowerBits,'0xc3000000'); Assign(UpperBits,'0x43000000')
            | 2:Assign(LowerBits,'0xc7000000'); Assign(UpperBits,'0x47000000')
            | 4:Assign(LowerBits,'0xcf000000'); Assign(UpperBits,'0x4f000000')
            ELSE Assign(LowerBits,'0xdf000000'); Assign(UpperBits,'0x5f000000')
            END
        ELSE
            CASE Bytes OF
            | 1:Assign(LowerBits,'0xc060000000000000'); Assign(UpperBits,'0x4060000000000000')
            | 2:Assign(LowerBits,'0xc0e0000000000000'); Assign(UpperBits,'0x40e0000000000000')
            | 4:Assign(LowerBits,'0xc1e0000000000000'); Assign(UpperBits,'0x41e0000000000000')
            ELSE Assign(LowerBits,'0xc3e0000000000000'); Assign(UpperBits,'0x43e0000000000000')
            END
        END
    ELSE
        LowerBits[0]:=0C;
        IF Float32 THEN
            CASE Bytes OF
            | 1:Assign(UpperBits,'0x43800000')
            | 2:Assign(UpperBits,'0x47800000')
            | 4:Assign(UpperBits,'0x4f800000')
            ELSE Assign(UpperBits,'0x5f800000')
            END
        ELSE
            CASE Bytes OF
            | 1:Assign(UpperBits,'0x4070000000000000')
            | 2:Assign(UpperBits,'0x40f0000000000000')
            | 4:Assign(UpperBits,'0x41f0000000000000')
            ELSE Assign(UpperBits,'0x43f0000000000000')
            END
        END
    END;
    IF Signed THEN
        IF Float32 THEN Assign(S,'    movl $'); Append(S,LowerBits); Append(S,', %eax'); Line(S); Line('    movd %eax, %xmm1'); Line('    ucomiss %xmm1, %xmm0')
        ELSE Assign(S,'    movabsq $'); Append(S,LowerBits); Append(S,', %rax'); Line(S); Line('    movq %rax, %xmm1'); Line('    ucomisd %xmm1, %xmm0')
        END
    ELSE
        IF Float32 THEN Line('    xorps %xmm1, %xmm1'); Line('    ucomiss %xmm1, %xmm0')
        ELSE Line('    xorpd %xmm1, %xmm1'); Line('    ucomisd %xmm1, %xmm0')
        END
    END;
    Line('    jp 91f'); Line('    jb 91f');
    IF Float32 THEN Assign(S,'    movl $'); Append(S,UpperBits); Append(S,', %eax'); Line(S); Line('    movd %eax, %xmm1'); Line('    ucomiss %xmm1, %xmm0')
    ELSE Assign(S,'    movabsq $'); Append(S,UpperBits); Append(S,', %rax'); Line(S); Line('    movq %rax, %xmm1'); Line('    ucomisd %xmm1, %xmm0')
    END;
    Line('    jp 91f'); Line('    jae 91f'); Line('    jmp 92f'); Line('91:'); Line('    ud2'); Line('92:')
END EmitCheckedRealToInteger;

PROCEDURE EmitConvert(X:Inst);
VAR SK,DK:TypeKind;
BEGIN
    SK:=ScalarBase(X.Label); DK:=ScalarBase(X.TypeId);
    IF RealKind(SK) THEN
        IF RealKind(DK) THEN
            EmitLoadFloat(X.A,X.Label,'%xmm0');
            IF (SK=TyR32) AND (DK=TyR64) THEN Line('    cvtss2sd %xmm0, %xmm0')
            ELSIF (SK=TyR64) AND (DK=TyR32) THEN Line('    cvtsd2ss %xmm0, %xmm0')
            END;
            EmitStoreFloat(X.Dst,X.TypeId,'%xmm0'); RETURN
        END;
        EmitLoadFloat(X.A,X.Label,'%xmm0');
        EmitCheckedRealToInteger(X.Label,X.TypeId);
        IF (NOT IsSigned(X.TypeId)) AND (TypeSize(X.TypeId)=8) THEN
            (* cvttsd2siq only covers the signed half. split at 2^63 for CARDINAL64/SIZE/ADDRESS. *)
            IF SK=TyR32 THEN
                Line('    movl $0x5f000000, %eax'); Line('    movd %eax, %xmm1'); Line('    ucomiss %xmm1, %xmm0'); Line('    jae 7f');
                Line('    cvttss2siq %xmm0, %rax'); Line('    jmp 8f'); Line('7:'); Line('    subss %xmm1, %xmm0'); Line('    cvttss2siq %xmm0, %rax')
            ELSE
                Line('    movabsq $0x43e0000000000000, %rax'); Line('    movq %rax, %xmm1'); Line('    ucomisd %xmm1, %xmm0'); Line('    jae 7f');
                Line('    cvttsd2siq %xmm0, %rax'); Line('    jmp 8f'); Line('7:'); Line('    subsd %xmm1, %xmm0'); Line('    cvttsd2siq %xmm0, %rax')
            END;
            Line('    btsq $63, %rax'); Line('8:')
        ELSE
            IF SK=TyR32 THEN Line('    cvttss2siq %xmm0, %rax') ELSE Line('    cvttsd2siq %xmm0, %rax') END;
            NormalizeRAX(X.TypeId)
        END;
        IF DK=TyBoolean THEN Line('    testq %rax, %rax'); Line('    setne %al'); Line('    movzbq %al, %rax') END;
        EmitStore(X.Dst,'%rax'); RETURN
    END;

    EmitLoad(X.A,'%rax'); NormalizeRAX(X.Label);
    IF RealKind(DK) THEN
        IF (NOT IsSigned(X.Label)) AND (TypeSize(X.Label)=8) THEN
            (* unsigned 64 bit to float without losing the top half to a signed conversion. *)
            Line('    testq %rax, %rax'); Line('    js 7f');
            IF DK=TyR32 THEN Line('    cvtsi2ssq %rax, %xmm0') ELSE Line('    cvtsi2sdq %rax, %xmm0') END;
            Line('    jmp 8f'); Line('7:'); Line('    movq %rax, %rcx'); Line('    andq $1, %rax'); Line('    shrq $1, %rcx'); Line('    orq %rax, %rcx');
            IF DK=TyR32 THEN Line('    cvtsi2ssq %rcx, %xmm0'); Line('    addss %xmm0, %xmm0') ELSE Line('    cvtsi2sdq %rcx, %xmm0'); Line('    addsd %xmm0, %xmm0') END;
            Line('8:')
        ELSE
            IF DK=TyR32 THEN Line('    cvtsi2ssq %rax, %xmm0') ELSE Line('    cvtsi2sdq %rax, %xmm0') END
        END;
        EmitStoreFloat(X.Dst,X.TypeId,'%xmm0'); RETURN
    END;

    IF DK=TyBoolean THEN Line('    testq %rax, %rax'); Line('    setne %al'); Line('    movzbq %al, %rax') ELSE NormalizeRAX(X.TypeId) END;
    EmitStore(X.Dst,'%rax')
END EmitConvert;

PROCEDURE EmitConstant(I:InstId; X:Inst);
VAR L,S:Text; P:CARDINAL;
BEGIN
    ConstLabel(I,L); Append(L,':'); Line(L);
    IF X.Opcode=OpConstS THEN
        P:=0; WHILE (P<=HIGH(X.Text)) AND (X.Text[P]#0C) DO Assign(L,'    .byte '); CardText(ORD(X.Text[P]),S); Append(L,S); Line(L); INC(P) END; Line('    .byte 0')
    ELSE
        IF IsReal32(X.TypeId) THEN Assign(L,'    .float ') ELSE Assign(L,'    .double ') END; Append(L,X.Text); Line(L)
    END
END EmitConstant;

PROCEDURE EmitGlobals;
VAR Gid:CARDINAL; G:Global; S,T:Text;
BEGIN
    IF GlobalCount()=0 THEN RETURN END; Gid:=1;
    WHILE Gid<=GlobalCount() DO
        G:=GetGlobal(Gid); Assign(S,'.section .bss.'); Append(S,G.Name); Append(S,',"aw",@nobits'); Line(S);
        Assign(S,'.globl '); Append(S,G.Name); Line(S); Assign(S,'.align '); CardText(G.Align,T); Append(S,T); Line(S);
        Assign(S,G.Name); Append(S,':'); Line(S); Assign(S,'    .zero '); CardText(G.Size,T); Append(S,T); Line(S); INC(Gid)
    END; Line('.text')
END EmitGlobals;

PROCEDURE EmitRodata;
VAR F:FuncId; I:InstId; X:Inst; Fn:Func;
BEGIN
    Line('.section .rodata'); F:=1;
    WHILE F<=FuncCount() DO
        Fn:=GetFunc(F); I:=Fn.First;
        WHILE I#0 DO
            X:=GetInst(I);
            IF (X.Opcode=OpConstS) OR (X.Opcode=OpConstF) THEN EmitConstant(I,X) END;
            I:=X.Next
        END;
        INC(F)
    END;
    Line('.text')
END EmitRodata;

PROCEDURE EmitParam(Loc,SlotNo,Ty,Part:CARDINAL);
VAR S,N,R:Text; Off:CARDINAL; C:ABI.Classification; Aggregate:BOOLEAN;
BEGIN
    ABI.ClassifySysV(Ty,C); Aggregate:=IsAggregateType(Ty);
    IF Loc<6 THEN
        CASE Loc OF
        | 0:IF Aggregate THEN EmitStore(SlotNo,'%rdi') ELSE Assign(S,'    movq %rdi, %rax'); Line(S); NormalizeRAX(Ty); EmitStore(SlotNo,'%rax') END
        | 1:IF Aggregate THEN EmitStore(SlotNo,'%rsi') ELSE Assign(S,'    movq %rsi, %rax'); Line(S); NormalizeRAX(Ty); EmitStore(SlotNo,'%rax') END
        | 2:IF Aggregate THEN EmitStore(SlotNo,'%rdx') ELSE Assign(S,'    movq %rdx, %rax'); Line(S); NormalizeRAX(Ty); EmitStore(SlotNo,'%rax') END
        | 3:IF Aggregate THEN EmitStore(SlotNo,'%rcx') ELSE Assign(S,'    movq %rcx, %rax'); Line(S); NormalizeRAX(Ty); EmitStore(SlotNo,'%rax') END
        | 4:IF Aggregate THEN EmitStore(SlotNo,'%r8') ELSE Assign(S,'    movq %r8, %rax'); Line(S); NormalizeRAX(Ty); EmitStore(SlotNo,'%rax') END
        | 5:IF Aggregate THEN EmitStore(SlotNo,'%r9') ELSE Assign(S,'    movq %r9, %rax'); Line(S); NormalizeRAX(Ty); EmitStore(SlotNo,'%rax') END
        ELSE END
    ELSIF (Loc>=LocSSE) AND (Loc<LocSSE+8) THEN
        Xmm(Loc-LocSSE,R);
        IF Aggregate THEN Assign(S,'    movq '); Append(S,R); Append(S,', '); Slot(SlotNo,N); Append(S,N); Line(S) ELSE EmitStoreFloat(SlotNo,Ty,R) END
    ELSIF Loc>=LocStack THEN
        Off:=16+(Loc-LocStack)*8; Assign(S,'    movq '); CardText(Off,N); Append(S,N); Append(S,'(%rbp), %rax'); Line(S);
        IF NOT Aggregate THEN NormalizeRAX(Ty) END; EmitStore(SlotNo,'%rax')
    END
END EmitParam;

PROCEDURE EmitArg(Loc,V,StackCount,Ty,Part:CARDINAL);
VAR R,S,T:Text; C:ABI.Classification; Aggregate:BOOLEAN;
BEGIN
    ABI.ClassifySysV(Ty,C); Aggregate:=IsAggregateType(Ty);
    IF Loc>=LocStack THEN
        IF (Loc=LocStack+StackCount-1) AND (StackCount MOD 2=1) THEN Line('    subq $8, %rsp') END;
        PartSlot(V,Part,T); Assign(S,'    pushq '); Append(S,T); Line(S); RETURN
    END;
    IF Loc<6 THEN
        CASE Loc OF
        | 0:PartSlot(V,Part,T); Assign(S,'    movq '); Append(S,T); Append(S,', %rdi'); Line(S)
        | 1:PartSlot(V,Part,T); Assign(S,'    movq '); Append(S,T); Append(S,', %rsi'); Line(S)
        | 2:PartSlot(V,Part,T); Assign(S,'    movq '); Append(S,T); Append(S,', %rdx'); Line(S)
        | 3:PartSlot(V,Part,T); Assign(S,'    movq '); Append(S,T); Append(S,', %rcx'); Line(S)
        | 4:PartSlot(V,Part,T); Assign(S,'    movq '); Append(S,T); Append(S,', %r8'); Line(S)
        | 5:PartSlot(V,Part,T); Assign(S,'    movq '); Append(S,T); Append(S,', %r9'); Line(S)
        ELSE END
    ELSE
        Xmm(Loc-LocSSE,R);
        IF Aggregate THEN PartSlot(V,Part,T); Assign(S,'    movq '); Append(S,T); Append(S,', '); Append(S,R); Line(S)
        ELSE EmitLoadFloat(V,Ty,R) END
    END
END EmitArg;

PROCEDURE EmitLoadGlobal(X:Inst);
VAR S:Text; Sz:CARDINAL;
BEGIN
    IF IsReal(X.TypeId) THEN
        IF IsReal32(X.TypeId) THEN Assign(S,'    movss ') ELSE Assign(S,'    movsd ') END; Append(S,X.Text); Append(S,'(%rip), %xmm0'); Line(S); EmitStoreFloat(X.Dst,X.TypeId,'%xmm0'); RETURN
    END;
    Sz:=TypeSize(X.TypeId);
    IF Sz=1 THEN IF IsSigned(X.TypeId) THEN Assign(S,'    movsbq ') ELSE Assign(S,'    movzbq ') END
    ELSIF Sz=2 THEN IF IsSigned(X.TypeId) THEN Assign(S,'    movswq ') ELSE Assign(S,'    movzwq ') END
    ELSIF Sz=4 THEN IF IsSigned(X.TypeId) THEN Assign(S,'    movslq ') ELSE Assign(S,'    movl ') END ELSE Assign(S,'    movq ') END;
    IF (Sz=4) AND (NOT IsSigned(X.TypeId)) THEN Append(S,X.Text); Append(S,'(%rip), %eax') ELSE Append(S,X.Text); Append(S,'(%rip), %rax') END; Line(S); EmitStore(X.Dst,'%rax')
END EmitLoadGlobal;

PROCEDURE EmitStoreGlobal(X:Inst);
VAR S:Text; Sz:CARDINAL;
BEGIN
    IF IsReal(X.TypeId) THEN EmitLoadFloat(X.A,X.TypeId,'%xmm0'); IF IsReal32(X.TypeId) THEN Assign(S,'    movss %xmm0, ') ELSE Assign(S,'    movsd %xmm0, ') END; Append(S,X.Text); Append(S,'(%rip)'); Line(S); RETURN END;
    EmitLoad(X.A,'%rax'); Sz:=TypeSize(X.TypeId);
    IF Sz=1 THEN Assign(S,'    movb %al, ') ELSIF Sz=2 THEN Assign(S,'    movw %ax, ') ELSIF Sz=4 THEN Assign(S,'    movl %eax, ') ELSE Assign(S,'    movq %rax, ') END;
    Append(S,X.Text); Append(S,'(%rip)'); Line(S)
END EmitStoreGlobal;

PROCEDURE EmitLoadPtr(X:Inst);
VAR S:Text; Sz:CARDINAL;
BEGIN
    EmitLoad(X.A,'%rax');
    IF (X.Imm>0) AND (X.Imm<8) THEN
        CASE X.Imm OF
        | 1:Line('    movzbq (%rax), %rax')
        | 2:Line('    movzwq (%rax), %rax')
        | 3:Line('    movzwq (%rax), %rcx'); Line('    movzbq 2(%rax), %rdx'); Line('    shlq $16, %rdx'); Line('    orq %rdx, %rcx'); Line('    movq %rcx, %rax')
        | 4:Line('    movl (%rax), %eax')
        | 5:Line('    movl (%rax), %ecx'); Line('    movzbq 4(%rax), %rdx'); Line('    shlq $32, %rdx'); Line('    orq %rdx, %rcx'); Line('    movq %rcx, %rax')
        | 6:Line('    movl (%rax), %ecx'); Line('    movzwq 4(%rax), %rdx'); Line('    shlq $32, %rdx'); Line('    orq %rdx, %rcx'); Line('    movq %rcx, %rax')
        | 7:Line('    movl (%rax), %ecx'); Line('    movzwq 4(%rax), %rdx'); Line('    shlq $32, %rdx'); Line('    orq %rdx, %rcx'); Line('    movzbq 6(%rax), %rdx'); Line('    shlq $48, %rdx'); Line('    orq %rdx, %rcx'); Line('    movq %rcx, %rax')
        END;
        EmitStore(X.Dst,'%rax'); RETURN
    END;
    IF IsReal(X.TypeId) THEN IF IsReal32(X.TypeId) THEN Line('    movss (%rax), %xmm0') ELSE Line('    movsd (%rax), %xmm0') END; EmitStoreFloat(X.Dst,X.TypeId,'%xmm0'); RETURN END;
    Sz:=TypeSize(X.TypeId); IF Sz=1 THEN IF IsSigned(X.TypeId) THEN Line('    movsbq (%rax), %rax') ELSE Line('    movzbq (%rax), %rax') END
    ELSIF Sz=2 THEN IF IsSigned(X.TypeId) THEN Line('    movswq (%rax), %rax') ELSE Line('    movzwq (%rax), %rax') END
    ELSIF Sz=4 THEN IF IsSigned(X.TypeId) THEN Line('    movslq (%rax), %rax') ELSE Line('    movl (%rax), %eax') END ELSE Line('    movq (%rax), %rax') END; EmitStore(X.Dst,'%rax')
END EmitLoadPtr;
PROCEDURE EmitStorePtr(X:Inst);
VAR Sz:CARDINAL;
BEGIN
    EmitLoad(X.A,'%rax');
    IF (X.Imm>0) AND (X.Imm<8) THEN
        EmitLoad(X.B,'%rcx');
        CASE X.Imm OF
        | 1:Line('    movb %cl, (%rax)')
        | 2:Line('    movw %cx, (%rax)')
        | 3:Line('    movw %cx, (%rax)'); Line('    shrq $16, %rcx'); Line('    movb %cl, 2(%rax)')
        | 4:Line('    movl %ecx, (%rax)')
        | 5:Line('    movl %ecx, (%rax)'); Line('    shrq $32, %rcx'); Line('    movb %cl, 4(%rax)')
        | 6:Line('    movl %ecx, (%rax)'); Line('    shrq $32, %rcx'); Line('    movw %cx, 4(%rax)')
        | 7:Line('    movl %ecx, (%rax)'); Line('    shrq $32, %rcx'); Line('    movw %cx, 4(%rax)'); Line('    shrq $16, %rcx'); Line('    movb %cl, 6(%rax)')
        END;
        RETURN
    END;
    IF IsReal(X.TypeId) THEN EmitLoadFloat(X.B,X.TypeId,'%xmm0'); IF IsReal32(X.TypeId) THEN Line('    movss %xmm0, (%rax)') ELSE Line('    movsd %xmm0, (%rax)') END; RETURN END;
    EmitLoad(X.B,'%rcx'); Sz:=TypeSize(X.TypeId); IF Sz=1 THEN Line('    movb %cl, (%rax)') ELSIF Sz=2 THEN Line('    movw %cx, (%rax)') ELSIF Sz=4 THEN Line('    movl %ecx, (%rax)') ELSE Line('    movq %rcx, (%rax)') END
END EmitStorePtr;

PROCEDURE CaptureReturn(Base:ValueId; Ty:TypeId);
VAR C:ABI.Classification; Part,GI,SI:CARDINAL; K:ABI.Class; S,T,R:Text;
BEGIN
    ABI.ClassifySysV(Ty,C);
    IF (C.Count=1) AND (C.A=ABI.IntegerClass) AND (NOT IsAggregateType(Ty)) THEN
        NormalizeRAX(Ty); EmitStore(Base,'%rax'); RETURN
    END;
    GI:=0; SI:=0; Part:=0;
    WHILE Part<C.Count DO
        K:=PartClass(C,Part);
        IF K=ABI.SSEClass THEN
            Xmm(SI,R); INC(SI);
            IF IsAggregateType(Ty) THEN PartSlot(Base,Part,T); Assign(S,'    movq '); Append(S,R); Append(S,', '); Append(S,T); Line(S)
            ELSE EmitStoreFloat(Base,Ty,R) END
        ELSE
            IF GI=0 THEN Assign(R,'%rax') ELSE Assign(R,'%rdx') END; INC(GI); PartSlot(Base,Part,T); Assign(S,'    movq '); Append(S,R); Append(S,', '); Append(S,T); Line(S)
        END; INC(Part)
    END
END CaptureReturn;

PROCEDURE LoadReturn(Base:ValueId; Ty:TypeId);
VAR C:ABI.Classification; Part,GI,SI:CARDINAL; K:ABI.Class; S,T,R:Text;
BEGIN
    ABI.ClassifySysV(Ty,C); GI:=0; SI:=0; Part:=0;
    WHILE Part<C.Count DO
        K:=PartClass(C,Part);
        IF K=ABI.SSEClass THEN
            Xmm(SI,R); INC(SI);
            IF IsAggregateType(Ty) THEN PartSlot(Base,Part,T); Assign(S,'    movq '); Append(S,T); Append(S,', '); Append(S,R); Line(S)
            ELSE EmitLoadFloat(Base,Ty,R) END
        ELSE
            IF GI=0 THEN Assign(R,'%rax') ELSE Assign(R,'%rdx') END; INC(GI); PartSlot(Base,Part,T); Assign(S,'    movq '); Append(S,T); Append(S,', '); Append(S,R); Line(S)
        END; INC(Part)
    END
END LoadReturn;

PROCEDURE EmitFunc(Fid:FuncId);
VAR F:Func; I:InstId; X:Inst; S,T,R:Text; Stack,Cleanup:CARDINAL;
BEGIN
    F:=GetFunc(Fid); Assign(S,'.section .text.'); Append(S,F.Name); Append(S,',"ax",@progbits'); Line(S);
    Assign(S,'.globl '); Append(S,F.Name); Line(S); Assign(S,'.type '); Append(S,F.Name); Append(S,', @function'); Line(S); Assign(S,F.Name); Append(S,':'); Line(S);
    Line('    pushq %rbp'); Line('    movq %rsp, %rbp'); Stack:=((F.ValueCount*8+15) DIV 16)*16; IF Stack<16 THEN Stack:=16 END;
    Assign(S,'    subq $'); CardText(Stack,T); Append(S,T); Append(S,', %rsp'); Line(S);
    I:=F.First;
    WHILE I#0 DO
        X:=GetInst(I);
        CASE X.Opcode OF
        | OpNop:
        | OpConstI:
            Assign(S,'    movq $'); IF X.Text[0]#0C THEN ImmediateLiteral(X.Text,T); Append(S,T) ELSE LongText(X.Imm,T); Append(S,T) END; Append(S,', %rax'); Line(S); EmitStore(X.Dst,'%rax')
        | OpConstF:
            Assign(S,'    '); IF IsReal32(X.TypeId) THEN Append(S,'movss ') ELSE Append(S,'movsd ') END; ConstLabel(I,T); Append(S,T); Append(S,'(%rip), %xmm0'); Line(S); EmitStoreFloat(X.Dst,X.TypeId,'%xmm0')
        | OpConstS:
            Assign(S,'    leaq '); ConstLabel(I,T); Append(S,T); Append(S,'(%rip), %rax'); Line(S); EmitStore(X.Dst,'%rax')
        | OpParam:EmitParam(VAL(CARDINAL,X.Imm),X.Dst,X.TypeId,X.Label)
        | OpArg:EmitArg(VAL(CARDINAL,X.Imm),X.A,X.Label DIV 2,X.TypeId,X.Label MOD 2)
        | OpMove:EmitLoad(X.A,'%rax'); NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpConvert:EmitConvert(X)
        | OpLoad:EmitLoadGlobal(X)
        | OpStore:EmitStoreGlobal(X)
        | OpAddrGlobal:Assign(S,'    leaq '); Append(S,X.Text); Append(S,'(%rip), %rax'); Line(S); EmitStore(X.Dst,'%rax')
        | OpAddrLocal:Assign(S,'    leaq '); Slot(X.A,T); Append(S,T); Append(S,', %rax'); Line(S); EmitStore(X.Dst,'%rax')
        | OpLoadPtr:EmitLoadPtr(X)
        | OpStorePtr:EmitStorePtr(X)
        | OpLeaOffset:EmitLoad(X.A,'%rax'); IF X.Imm#0 THEN Assign(S,'    addq $'); LongText(X.Imm,T); Append(S,T); Append(S,', %rax'); Line(S) END; EmitStore(X.Dst,'%rax')
        | OpAdd:EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx'); Line('    addq %rcx, %rax'); NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpSub:EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx'); Line('    subq %rcx, %rax'); NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpMul:EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx'); Line('    imulq %rcx, %rax'); NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpDiv,OpMod:EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx'); IF IsSigned(X.TypeId) THEN Line('    cqto'); Line('    idivq %rcx') ELSE Line('    xorq %rdx, %rdx'); Line('    divq %rcx') END; IF X.Opcode=OpMod THEN Line('    movq %rdx, %rax') END; NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpAnd:EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx'); Line('    andq %rcx, %rax'); NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpOr:EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx'); Line('    orq %rcx, %rax'); NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpXor:EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx'); Line('    xorq %rcx, %rax'); NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpShl:EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx'); Line('    salq %cl, %rax'); NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpShr:EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx'); IF IsSigned(X.TypeId) THEN Line('    sarq %cl, %rax') ELSE Line('    shrq %cl, %rax') END; NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpNeg:EmitLoad(X.A,'%rax'); Line('    negq %rax'); NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpNot:EmitLoad(X.A,'%rax'); Line('    testq %rax, %rax'); Line('    sete %al'); Line('    movzbq %al, %rax'); EmitStore(X.Dst,'%rax')
        | OpFAdd,OpFSub,OpFMul,OpFDiv:
            EmitLoadFloat(X.A,X.TypeId,'%xmm0'); EmitLoadFloat(X.B,X.TypeId,'%xmm1');
            IF IsReal32(X.TypeId) THEN
                CASE X.Opcode OF | OpFAdd:Line('    addss %xmm1, %xmm0') | OpFSub:Line('    subss %xmm1, %xmm0') | OpFMul:Line('    mulss %xmm1, %xmm0') | OpFDiv:Line('    divss %xmm1, %xmm0') ELSE END
            ELSE
                CASE X.Opcode OF | OpFAdd:Line('    addsd %xmm1, %xmm0') | OpFSub:Line('    subsd %xmm1, %xmm0') | OpFMul:Line('    mulsd %xmm1, %xmm0') | OpFDiv:Line('    divsd %xmm1, %xmm0') ELSE END
            END; EmitStoreFloat(X.Dst,X.TypeId,'%xmm0')
        | OpFNeg:EmitLoad(X.A,'%rax'); IF IsReal32(X.TypeId) THEN Line('    btcq $31, %rax') ELSE Line('    btcq $63, %rax') END; EmitStore(X.Dst,'%rax')
        | OpCmpEq,OpCmpNe,OpCmpLt,OpCmpLe,OpCmpGt,OpCmpGe:
            EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx'); Line('    cmpq %rcx, %rax');
            CASE X.Opcode OF
            | OpCmpEq:Line('    sete %al')
            | OpCmpNe:Line('    setne %al')
            | OpCmpLt:IF IsSigned(X.TypeId) THEN Line('    setl %al') ELSE Line('    setb %al') END
            | OpCmpLe:IF IsSigned(X.TypeId) THEN Line('    setle %al') ELSE Line('    setbe %al') END
            | OpCmpGt:IF IsSigned(X.TypeId) THEN Line('    setg %al') ELSE Line('    seta %al') END
            | OpCmpGe:IF IsSigned(X.TypeId) THEN Line('    setge %al') ELSE Line('    setae %al') END
            ELSE END;
            Line('    movzbq %al, %rax'); EmitStore(X.Dst,'%rax')
        | OpFCmpEq,OpFCmpNe,OpFCmpLt,OpFCmpLe,OpFCmpGt,OpFCmpGe:
            EmitLoadFloat(X.A,X.TypeId,'%xmm0'); EmitLoadFloat(X.B,X.TypeId,'%xmm1'); IF IsReal32(X.TypeId) THEN Line('    ucomiss %xmm1, %xmm0') ELSE Line('    ucomisd %xmm1, %xmm0') END;
            CASE X.Opcode OF
            | OpFCmpEq:Line('    sete %al'); Line('    setnp %cl'); Line('    andb %cl, %al')
            | OpFCmpNe:Line('    setne %al'); Line('    setp %cl'); Line('    orb %cl, %al')
            | OpFCmpLt:Line('    setb %al'); Line('    setnp %cl'); Line('    andb %cl, %al')
            | OpFCmpLe:Line('    setbe %al'); Line('    setnp %cl'); Line('    andb %cl, %al')
            | OpFCmpGt:Line('    seta %al')
            | OpFCmpGe:Line('    setae %al')
            ELSE END;
            Line('    movzbq %al, %rax'); EmitStore(X.Dst,'%rax')
        | OpCall:
            IF X.Label=0 THEN Line('    xorl %eax, %eax') ELSE Assign(S,'    movb $'); CardText(X.Label,T); Append(S,T); Append(S,', %al'); Line(S) END;
            Assign(S,'    call '); Append(S,X.Text); Line(S); Cleanup:=VAL(CARDINAL,X.Imm); IF Cleanup MOD 2=1 THEN INC(Cleanup) END;
            IF Cleanup>0 THEN Assign(S,'    addq $'); CardText(Cleanup*8,T); Append(S,T); Append(S,', %rsp'); Line(S) END;
            IF X.Dst#0 THEN CaptureReturn(X.Dst,X.TypeId) END
        | OpCallIndirect:
            IF X.Label=0 THEN Line('    xorl %eax, %eax') ELSE Assign(S,'    movb $'); CardText(X.Label,T); Append(S,T); Append(S,', %al'); Line(S) END;
            EmitLoad(X.A,'%r11'); Line('    call *%r11'); Cleanup:=VAL(CARDINAL,X.Imm); IF Cleanup MOD 2=1 THEN INC(Cleanup) END;
            IF Cleanup>0 THEN Assign(S,'    addq $'); CardText(Cleanup*8,T); Append(S,T); Append(S,', %rsp'); Line(S) END;
            IF X.Dst#0 THEN CaptureReturn(X.Dst,X.TypeId) END
        | OpRet:
            IF X.A#0 THEN LoadReturn(X.A,X.TypeId) ELSE Line('    xorl %eax, %eax') END; Line('    leave'); Line('    ret')
        | OpLabel:LabelText(X.Label,S); Append(S,':'); Line(S)
        | OpJump:Assign(S,'    jmp '); LabelText(X.Label,T); Append(S,T); Line(S)
        | OpBranch:EmitLoad(X.A,'%rax'); Line('    testq %rax, %rax'); Assign(S,'    je '); LabelText(X.Label,T); Append(S,T); Line(S)
        | OpAssert:EmitLoad(X.A,'%rax'); Line('    testq %rax, %rax'); Line('    jne 1f'); Line('    ud2'); Line('1:')
        | OpTrap:Line('    ud2')
        | OpAtomicLoad:
            EmitLoad(X.A,'%rax');
            CASE TypeSize(X.TypeId) OF
            | 1:IF IsSigned(X.TypeId) THEN Line('    movsbq (%rax), %rcx') ELSE Line('    movzbq (%rax), %rcx') END
            | 2:IF IsSigned(X.TypeId) THEN Line('    movswq (%rax), %rcx') ELSE Line('    movzwq (%rax), %rcx') END
            | 4:IF IsSigned(X.TypeId) THEN Line('    movslq (%rax), %rcx') ELSE Line('    movl (%rax), %ecx') END
            ELSE Line('    movq (%rax), %rcx') END; EmitStore(X.Dst,'%rcx')
        | OpAtomicStore:
            EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx');
            CASE TypeSize(X.TypeId) OF | 1:Line('    xchgb %cl, (%rax)') | 2:Line('    xchgw %cx, (%rax)') | 4:Line('    xchgl %ecx, (%rax)') ELSE Line('    xchgq %rcx, (%rax)') END
        | OpAtomicAdd:
            EmitLoad(X.A,'%rax'); EmitLoad(X.B,'%rcx');
            CASE TypeSize(X.TypeId) OF | 1:Line('    lock xaddb %cl, (%rax)') | 2:Line('    lock xaddw %cx, (%rax)') | 4:Line('    lock xaddl %ecx, (%rax)') ELSE Line('    lock xaddq %rcx, (%rax)') END;
            Line('    movq %rcx, %rax'); NormalizeRAX(X.TypeId); EmitStore(X.Dst,'%rax')
        | OpAtomicCAS:
            EmitLoad(X.A,'%rdi'); EmitLoad(X.Label,'%rax'); EmitLoad(X.B,'%rcx');
            CASE TypeSize(X.TypeId) OF | 1:Line('    lock cmpxchgb %cl, (%rdi)') | 2:Line('    lock cmpxchgw %cx, (%rdi)') | 4:Line('    lock cmpxchgl %ecx, (%rdi)') ELSE Line('    lock cmpxchgq %rcx, (%rdi)') END;
            Line('    sete %al'); Line('    movzbq %al, %rax'); EmitStore(X.Dst,'%rax')
        | OpTaskStart:
            (* The runtime registers task threads with the collector before user code runs. *)
            Assign(S,'    leaq '); Append(S,X.Text); Append(S,'(%rip), %rdi'); Line(S);
            Line('    call hilbert_rt_task_start'); EmitStore(X.Dst,'%rax')
        | OpTaskAwait:
            EmitLoad(X.A,'%rdi'); Line('    call hilbert_rt_task_await')
        END;
        I:=X.Next
    END;
    Line('    xorl %eax, %eax'); Line('    leave'); Line('    ret'); Assign(S,'.size '); Append(S,F.Name); Append(S,', .-'); Append(S,F.Name); Line(S)
END EmitFunc;

PROCEDURE EmitAssembly(Path:ARRAY OF CHAR; Debug:BOOLEAN):BOOLEAN;
VAR F:FuncId;
BEGIN
    IF NOT Open(Path) THEN SimpleCode(Error,EOutputCreate,'cannot create assembly output'); RETURN FALSE END;
    IF Debug THEN Line('.file "hilbert"') END; EmitGlobals; EmitRodata; F:=1; WHILE F<=FuncCount() DO EmitFunc(F); INC(F) END; Line('.section .note.GNU-stack,"",@progbits'); Close; RETURN TRUE
END EmitAssembly;

END X64.
