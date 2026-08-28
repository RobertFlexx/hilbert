IMPLEMENTATION MODULE Optimize;

FROM HIR IMPORT FuncId,InstId,Inst,Func,Op,FuncCount,GetFunc,GetInst,PutInst;
IMPORT Types;
FROM Types IMPORT Type;
FROM Options IMPORT OptLevel;

CONST MaxValues=400000; MaxLong=9223372036854775807; MinLong=-9223372036854775807-1;
VAR Stamp:ARRAY[0..MaxValues] OF CARDINAL; Value:ARRAY[0..MaxValues] OF LONGINT;
    Uses,Defs:ARRAY[0..MaxValues] OF CARDINAL; Generation:CARDINAL;

PROCEDURE DigitValue(C:CHAR):INTEGER;
BEGIN
    IF (C>='0') AND (C<='9') THEN RETURN ORD(C)-ORD('0') END;
    IF (C>='a') AND (C<='f') THEN RETURN 10+ORD(C)-ORD('a') END;
    IF (C>='A') AND (C<='F') THEN RETURN 10+ORD(C)-ORD('A') END;
    RETURN -1
END DigitValue;

PROCEDURE ParseLong(S:ARRAY OF CHAR; VAR Ok:BOOLEAN):LONGINT;
VAR I:CARDINAL; V:LONGINT; Neg:BOOLEAN; Base,D:INTEGER;
BEGIN
    I:=0; V:=0; Neg:=FALSE; Ok:=TRUE; Base:=10;
    IF S[0]='-' THEN Neg:=TRUE; INC(I) END;
    IF (I<HIGH(S)) AND (S[I]='0') AND ((S[I+1]='x') OR (S[I+1]='X')) THEN Base:=16; INC(I,2)
    ELSIF (I<HIGH(S)) AND (S[I]='0') AND ((S[I+1]='b') OR (S[I+1]='B')) THEN Base:=2; INC(I,2)
    ELSIF (I<HIGH(S)) AND (S[I]='0') AND ((S[I+1]='o') OR (S[I+1]='O')) THEN Base:=8; INC(I,2)
    END;
    IF (I>HIGH(S)) OR (S[I]=0C) THEN Ok:=FALSE; RETURN 0 END;
    WHILE (I<=HIGH(S)) AND (S[I]#0C) DO
        D:=DigitValue(S[I]); IF (D<0) OR (D>=Base) THEN Ok:=FALSE; RETURN 0 END;
        (* Do not let the bootstrap compiler's host arithmetic overflow while
           merely trying to fold a Hilbert literal.  Values outside signed
           LONGINT stay textual and are left for the native assembler path. *)
        IF V>(9223372036854775807-VAL(LONGINT,D)) DIV VAL(LONGINT,Base) THEN Ok:=FALSE; RETURN 0 END;
        V:=V*VAL(LONGINT,Base)+VAL(LONGINT,D); INC(I)
    END;
    IF Neg THEN RETURN -V ELSE RETURN V END
END ParseLong;

PROCEDURE Remember(D:CARDINAL; V:LONGINT);
BEGIN
    IF (D>0) AND (D<=MaxValues) AND (Defs[D]=1) THEN
        Stamp[D]:=Generation; Value[D]:=V
    ELSIF (D>0) AND (D<=MaxValues) THEN
        Stamp[D]:=0
    END
END Remember;
PROCEDURE Forget(D:CARDINAL);
BEGIN IF (D>0) AND (D<=MaxValues) THEN Stamp[D]:=0 END END Forget;
PROCEDURE IsKnown(V:CARDINAL):BOOLEAN;
BEGIN RETURN (V>0) AND (V<=MaxValues) AND (Defs[V]=1) AND (Stamp[V]=Generation) END IsKnown;

PROCEDURE CountDefinitions(Fn:Func);
VAR I:InstId; X:Inst; J:CARDINAL;
BEGIN
    J:=0;
    WHILE (J<=MaxValues) AND (J<=Fn.ValueCount) DO Defs[J]:=0; INC(J) END;
    I:=Fn.First;
    WHILE I#0 DO
        X:=GetInst(I);
        IF (X.Opcode#OpNop) AND (X.Dst>0) AND (X.Dst<=MaxValues) THEN INC(Defs[X.Dst]) END;
        I:=X.Next
    END
END CountDefinitions;

PROCEDURE NextGeneration;
VAR J:CARDINAL;
BEGIN
    INC(Generation);
    IF Generation=0 THEN
        (* CARDINAL wrap is fantastically unlikely, but keep the invariant
           exact instead of relying on it never happening. *)
        J:=0; WHILE J<=MaxValues DO Stamp[J]:=0; INC(J) END; Generation:=1
    END
END NextGeneration;

PROCEDURE MakeConst(VAR X:Inst; V:LONGINT);
BEGIN X.Opcode:=OpConstI; X.A:=0; X.B:=0; X.Imm:=V; X.Text[0]:=0C; Remember(X.Dst,V) END MakeConst;
PROCEDURE MakeMove(VAR X:Inst; V:CARDINAL);
BEGIN
    X.Opcode:=OpMove; X.A:=V; X.B:=0; X.Imm:=0; X.Text[0]:=0C;
    IF IsKnown(V) THEN Remember(X.Dst,Value[V]) ELSE Forget(X.Dst) END
END MakeMove;

PROCEDURE SafeNeg(A:LONGINT; VAR R:LONGINT):BOOLEAN;
BEGIN IF A=MinLong THEN RETURN FALSE END; R:=-A; RETURN TRUE END SafeNeg;

PROCEDURE SafeAdd(A,B:LONGINT; VAR R:LONGINT):BOOLEAN;
BEGIN
    IF (B>0) AND (A>MaxLong-B) THEN RETURN FALSE END;
    IF (B<0) AND (A<MinLong-B) THEN RETURN FALSE END;
    R:=A+B; RETURN TRUE
END SafeAdd;

PROCEDURE SafeSub(A,B:LONGINT; VAR R:LONGINT):BOOLEAN;
BEGIN
    IF (B>0) AND (A<MinLong+B) THEN RETURN FALSE END;
    IF (B<0) AND (A>MaxLong+B) THEN RETURN FALSE END;
    R:=A-B; RETURN TRUE
END SafeSub;

PROCEDURE SafeMul(A,B:LONGINT; VAR R:LONGINT):BOOLEAN;
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

PROCEDURE SafeDivMod(A,B:LONGINT; VAR Q,R:LONGINT):BOOLEAN;
VAR HostR:LONGINT;
BEGIN
    IF (B=0) OR ((A=MinLong) AND (B=-1)) THEN RETURN FALSE END;
    Q:=A DIV B; HostR:=A MOD B;
    (* GNU Modula-2 uses its own DIV/MOD convention.  Hilbert specifies
       truncation toward zero, so adjust a floor-style host result when its
       remainder has the divisor's sign instead of the dividend's sign. *)
    IF (HostR#0) AND ((A<0)#(B<0)) AND ((HostR<0)#(A<0)) THEN
        IF NOT SafeAdd(Q,1,Q) OR NOT SafeSub(HostR,B,HostR) THEN RETURN FALSE END
    END;
    R:=HostR; RETURN TRUE
END SafeDivMod;

PROCEDURE SafeDiv(A,B:LONGINT; VAR R:LONGINT):BOOLEAN;
VAR Remainder:LONGINT;
BEGIN RETURN SafeDivMod(A,B,R,Remainder) END SafeDiv;

PROCEDURE SafeMod(A,B:LONGINT; VAR R:LONGINT):BOOLEAN;
VAR Quot:LONGINT;
BEGIN
    RETURN SafeDivMod(A,B,Quot,R)
END SafeMod;

PROCEDURE FoldFunction(F:FuncId; Aggressive:BOOLEAN);
VAR I:InstId; X:Inst; Fn:Func; A,B,R:LONGINT; Ok:BOOLEAN;
BEGIN
    Fn:=GetFunc(F); CountDefinitions(Fn); NextGeneration; I:=Fn.First;
    WHILE I#0 DO
        X:=GetInst(I);
        CASE X.Opcode OF
        | OpConstI:
            IF X.Text[0]#0C THEN R:=ParseLong(X.Text,Ok); IF Ok THEN X.Imm:=R; X.Text[0]:=0C; PutInst(I,X); Remember(X.Dst,R) ELSE Forget(X.Dst) END
            ELSE Remember(X.Dst,X.Imm)
            END
        | OpMove:
            IF X.Dst=X.A THEN X.Opcode:=OpNop; PutInst(I,X)
            ELSIF IsKnown(X.A) THEN MakeConst(X,Value[X.A]); PutInst(I,X)
            ELSE Forget(X.Dst)
            END
        | OpNeg:
            IF IsKnown(X.A) THEN
                Ok:=SafeNeg(Value[X.A],R); IF Ok THEN MakeConst(X,R); PutInst(I,X) ELSE Forget(X.Dst) END
            ELSE Forget(X.Dst) END
        | OpNot:
            IF IsKnown(X.A) THEN IF Value[X.A]=0 THEN R:=1 ELSE R:=0 END; MakeConst(X,R); PutInst(I,X) ELSE Forget(X.Dst) END
        | OpAdd,OpSub,OpMul,OpDiv,OpMod,
          OpCmpEq,OpCmpNe,OpCmpLt,OpCmpLe,OpCmpGt,OpCmpGe:
            IF IsKnown(X.A) AND IsKnown(X.B) THEN
                A:=Value[X.A]; B:=Value[X.B]; Ok:=TRUE;
                CASE X.Opcode OF
                | OpAdd:Ok:=SafeAdd(A,B,R)
                | OpSub:Ok:=SafeSub(A,B,R)
                | OpMul:Ok:=SafeMul(A,B,R)
                | OpDiv:Ok:=SafeDiv(A,B,R)
                | OpMod:Ok:=SafeMod(A,B,R)
                | OpCmpEq:IF A=B THEN R:=1 ELSE R:=0 END
                | OpCmpNe:IF A#B THEN R:=1 ELSE R:=0 END
                | OpCmpLt:IF A<B THEN R:=1 ELSE R:=0 END
                | OpCmpLe:IF A<=B THEN R:=1 ELSE R:=0 END
                | OpCmpGt:IF A>B THEN R:=1 ELSE R:=0 END
                | OpCmpGe:IF A>=B THEN R:=1 ELSE R:=0 END
                ELSE Ok:=FALSE
                END;
                IF Ok THEN MakeConst(X,R); PutInst(I,X) ELSE Forget(X.Dst) END
            ELSIF Aggressive THEN
                (* Cheap identities keep O2 useful without expensive data-flow machinery. *)
                IF (X.Opcode=OpAdd) AND IsKnown(X.B) AND (Value[X.B]=0) THEN MakeMove(X,X.A); PutInst(I,X)
                ELSIF (X.Opcode=OpAdd) AND IsKnown(X.A) AND (Value[X.A]=0) THEN MakeMove(X,X.B); PutInst(I,X)
                ELSIF (X.Opcode=OpSub) AND IsKnown(X.B) AND (Value[X.B]=0) THEN MakeMove(X,X.A); PutInst(I,X)
                ELSIF (X.Opcode=OpSub) AND (X.A=X.B) THEN MakeConst(X,0); PutInst(I,X)
                ELSIF (X.Opcode=OpMul) AND IsKnown(X.B) AND (Value[X.B]=1) THEN MakeMove(X,X.A); PutInst(I,X)
                ELSIF (X.Opcode=OpMul) AND IsKnown(X.A) AND (Value[X.A]=1) THEN MakeMove(X,X.B); PutInst(I,X)
                ELSIF (X.Opcode=OpMul) AND ((IsKnown(X.A) AND (Value[X.A]=0)) OR (IsKnown(X.B) AND (Value[X.B]=0))) THEN MakeConst(X,0); PutInst(I,X)
                ELSIF (X.Opcode=OpDiv) AND IsKnown(X.B) AND (Value[X.B]=1) THEN MakeMove(X,X.A); PutInst(I,X)
                ELSIF (X.Opcode=OpMod) AND IsKnown(X.B) AND ((Value[X.B]=1) OR (Value[X.B]=-1)) THEN MakeConst(X,0); PutInst(I,X)
                ELSE Forget(X.Dst)
                END
            ELSE Forget(X.Dst)
            END
        | OpAnd,OpOr,OpXor,OpShl,OpShr:
            (* Keep bit operations in HIR unless an identity makes them disappear.  This avoids
               imposing the host compiler's word/shift semantics on Hilbert constants. *)
            IF Aggressive AND (X.Opcode=OpAnd) AND ((IsKnown(X.A) AND (Value[X.A]=0)) OR (IsKnown(X.B) AND (Value[X.B]=0))) THEN MakeConst(X,0); PutInst(I,X)
            ELSIF Aggressive AND (X.Opcode=OpOr) AND IsKnown(X.B) AND (Value[X.B]=0) THEN MakeMove(X,X.A); PutInst(I,X)
            ELSIF Aggressive AND (X.Opcode=OpOr) AND IsKnown(X.A) AND (Value[X.A]=0) THEN MakeMove(X,X.B); PutInst(I,X)
            ELSIF Aggressive AND (X.Opcode=OpXor) AND IsKnown(X.B) AND (Value[X.B]=0) THEN MakeMove(X,X.A); PutInst(I,X)
            ELSIF Aggressive AND (X.Opcode=OpXor) AND IsKnown(X.A) AND (Value[X.A]=0) THEN MakeMove(X,X.B); PutInst(I,X)
            ELSIF Aggressive AND ((X.Opcode=OpShl) OR (X.Opcode=OpShr)) AND IsKnown(X.B) AND (Value[X.B]=0) THEN MakeMove(X,X.A); PutInst(I,X)
            ELSE Forget(X.Dst)
            END
        | OpBranch:
            IF Aggressive AND IsKnown(X.A) THEN
                IF Value[X.A]=0 THEN X.Opcode:=OpJump; X.A:=0 ELSE X.Opcode:=OpNop; X.A:=0 END;
                PutInst(I,X)
            END;
            (* locals get reused. pretending they are SSA here is how a FOR loop
               ends up immortal, so block edges drop the cheap constant facts. *)
            NextGeneration
        | OpJump,OpLabel:
            NextGeneration
        | OpLoad,OpLoadPtr,OpCall,OpCallIndirect,OpParam,OpConstF,OpAtomicLoad,OpAtomicAdd,OpAtomicCAS,OpTaskStart:
            Forget(X.Dst)
        ELSE
            IF X.Dst#0 THEN Forget(X.Dst) END
        END;
        I:=X.Next
    END
END FoldFunction;

PROCEDURE AddUse(V:CARDINAL);
BEGIN
    IF (V>0) AND (V<=MaxValues) THEN INC(Uses[V]) END
END AddUse;

PROCEDURE AddInstructionUses(X:Inst);
VAR T:Type;
BEGIN
    AddUse(X.A); AddUse(X.B);
    (* Aggregate values occupy descending value slots.  OpArg retains the
       aggregate base in A and selects its eightbyte with Label; OpRet retains
       only the base plus the result type.  Counting just A lets DCE erase the
       second half of slices and small records before calls or returns. *)
    IF (X.Opcode=OpArg) AND ((X.Label MOD 2)=1) AND (X.A>1) THEN AddUse(X.A-1) END;
    IF (X.Opcode=OpRet) AND (X.A>1) AND (X.TypeId#0) THEN
        T:=Types.Get(X.TypeId); IF T.Size>8 THEN AddUse(X.A-1) END
    END;
    IF X.Opcode=OpAtomicCAS THEN AddUse(X.Label) END
END AddInstructionUses;

PROCEDURE PureValue(X:Inst):BOOLEAN;
BEGIN
    CASE X.Opcode OF
    | OpConstI,OpConstF,OpConstS,OpMove,OpConvert,OpAddrGlobal,OpAddrLocal,OpLeaOffset,
      OpAdd,OpSub,OpMul,OpNeg,OpNot,OpAnd,OpOr,OpXor,OpShl,OpShr,
      OpFAdd,OpFSub,OpFMul,OpFDiv,OpFNeg,
      OpCmpEq,OpCmpNe,OpCmpLt,OpCmpLe,OpCmpGt,OpCmpGe,
      OpFCmpEq,OpFCmpNe,OpFCmpLt,OpFCmpLe,OpFCmpGt,OpFCmpGe:
        RETURN TRUE
    ELSE
        RETURN FALSE
    END
END PureValue;

PROCEDURE EliminateDeadValues(F:FuncId):BOOLEAN;
VAR I:InstId; X:Inst; Fn:Func; J:CARDINAL; Changed:BOOLEAN;
BEGIN
    Fn:=GetFunc(F);
    J:=0; WHILE (J<=MaxValues) AND (J<=Fn.ValueCount) DO Uses[J]:=0; INC(J) END;
    I:=Fn.First;
    WHILE I#0 DO
        X:=GetInst(I);
        IF X.Opcode#OpNop THEN
            (* A and B are value ids for the value-producing HIR operations.
               Some control/storage opcodes reuse those slots too; counting an
               extra id there is conservative and merely keeps a dead value. *)
            AddInstructionUses(X)
        END;
        I:=X.Next
    END;

    Changed:=FALSE; I:=Fn.First;
    WHILE I#0 DO
        X:=GetInst(I);
        IF (X.Dst>0) AND (X.Dst<=MaxValues) AND (Uses[X.Dst]=0) AND PureValue(X) THEN
            (* Dead pure values have no observable work.  Don't get clever
               with loads, calls, division or atomics: traps and side effects
               are part of the program, even when nobody reads the result. *)
            X.Opcode:=OpNop; PutInst(I,X); Changed:=TRUE
        END;
        I:=X.Next
    END;
    RETURN Changed
END EliminateDeadValues;

PROCEDURE Run(Level:OptLevel);
VAR F:FuncId; Aggressive:BOOLEAN;
BEGIN
    IF Level=O0 THEN RETURN END;
    Aggressive:=(Level=O2) OR (Level=O3) OR (Level=Os);
    F:=1; WHILE F<=FuncCount() DO
        FoldFunction(F,Aggressive);
        IF Aggressive THEN
            IF EliminateDeadValues(F) AND (Level=O3) THEN FoldFunction(F,TRUE) END;
            IF Level=O3 THEN
                (* One more cheap sweep catches chains exposed by the first DCE pass. *)
                IF EliminateDeadValues(F) THEN FoldFunction(F,TRUE) END
            END
        END;
        INC(F)
    END
END Run;

END Optimize.
