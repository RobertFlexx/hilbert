IMPLEMENTATION MODULE Verify;

FROM HIR IMPORT FuncId,InstId,Inst,Func,Op,FuncCount,GetFunc,GetInst;
FROM Diagnostics IMPORT SimpleCode,Severity,HasErrors;
FROM ErrorCodes IMPORT EHirMalformed,EInternalInvariant;

CONST MaxLabels=131071;
VAR LabelStamp:ARRAY[0..MaxLabels] OF CARDINAL; Generation:CARDINAL;

PROCEDURE Bad(M:ARRAY OF CHAR);
BEGIN SimpleCode(Error,EHirMalformed,M) END Bad;

PROCEDURE ValueOK(V,Limit:CARDINAL):BOOLEAN;
BEGIN RETURN (V=0) OR (V<=Limit) END ValueOK;

PROCEDURE NeedsDst(O:Op):BOOLEAN;
BEGIN
    RETURN (O=OpConstI) OR (O=OpConstF) OR (O=OpConstS) OR (O=OpParam) OR
           (O=OpLoad) OR (O=OpMove) OR (O=OpConvert) OR (O=OpAddrGlobal) OR (O=OpAddrLocal) OR
           (O=OpLoadPtr) OR (O=OpLeaOffset) OR (O=OpAdd) OR (O=OpSub) OR
           (O=OpMul) OR (O=OpDiv) OR (O=OpMod) OR (O=OpNeg) OR (O=OpNot) OR
           (O=OpAnd) OR (O=OpOr) OR (O=OpXor) OR (O=OpShl) OR (O=OpShr) OR
           (O=OpFAdd) OR (O=OpFSub) OR (O=OpFMul) OR (O=OpFDiv) OR (O=OpFNeg) OR
           (O=OpCmpEq) OR (O=OpCmpNe) OR (O=OpCmpLt) OR (O=OpCmpLe) OR
           (O=OpCmpGt) OR (O=OpCmpGe) OR (O=OpFCmpEq) OR (O=OpFCmpNe) OR
           (O=OpFCmpLt) OR (O=OpFCmpLe) OR (O=OpFCmpGt) OR (O=OpFCmpGe) OR
           (O=OpCall) OR (O=OpCallIndirect) OR (O=OpAtomicLoad) OR (O=OpAtomicAdd) OR
           (O=OpAtomicCAS) OR (O=OpTaskStart)
END NeedsDst;

PROCEDURE CheckFunction(Fid:FuncId);
VAR F:Func; I,Prev:InstId; X:Inst; J,Seen:CARDINAL;
BEGIN
    F:=GetFunc(Fid);
    IF F.Name[0]=0C THEN Bad('HIR function has no symbol name') END;
    IF (F.First=0) # (F.Last=0) THEN Bad('HIR function has an inconsistent first/last instruction pair') END;
    INC(Generation);
    IF Generation=0 THEN J:=0; WHILE J<=MaxLabels DO LabelStamp[J]:=0; INC(J) END; Generation:=1 END;
    I:=F.First; Seen:=0; Prev:=0;
    WHILE I#0 DO
        INC(Seen); IF Seen>1000000 THEN SimpleCode(Fatal,EInternalInvariant,'HIR instruction list appears cyclic'); RETURN END;
        X:=GetInst(I); Prev:=I;
        IF X.Opcode=OpLabel THEN
            IF X.Label=0 THEN Bad('HIR label zero is reserved')
            ELSIF X.Label>MaxLabels THEN Bad('HIR label exceeds verifier limit')
            ELSIF LabelStamp[X.Label]=Generation THEN Bad('duplicate HIR label')
            ELSE LabelStamp[X.Label]:=Generation
            END
        END;
        I:=X.Next
    END;
    IF (F.Last#0) AND (Prev#F.Last) THEN Bad('HIR function last-instruction pointer is stale') END;

    I:=F.First;
    WHILE I#0 DO
        X:=GetInst(I);
        IF NOT ValueOK(X.Dst,F.ValueCount) THEN Bad('HIR destination references an invalid value') END;
        IF NOT ValueOK(X.A,F.ValueCount) THEN Bad('HIR operand A references an invalid value') END;
        IF NOT ValueOK(X.B,F.ValueCount) THEN Bad('HIR operand B references an invalid value') END;
        IF NeedsDst(X.Opcode) AND (X.Dst=0) THEN Bad('HIR value-producing instruction has no destination') END;
        IF (X.Opcode=OpJump) OR (X.Opcode=OpBranch) THEN
            IF (X.Label=0) OR (X.Label>MaxLabels) OR (LabelStamp[X.Label]#Generation) THEN Bad('HIR branch references a missing label') END
        END;
        IF (X.Opcode=OpBranch) AND (X.A=0) THEN Bad('HIR conditional branch has no condition') END;
        IF (X.Opcode=OpCall) AND (X.Text[0]=0C) THEN Bad('HIR call has an empty target symbol') END;
        IF (X.Opcode=OpCallIndirect) AND (X.A=0) THEN Bad('HIR indirect call has no procedure value') END;
        IF (X.Opcode=OpTaskStart) AND (X.Text[0]=0C) THEN Bad('HIR task start has an empty target symbol') END;
        IF (X.Opcode=OpArg) AND (X.A=0) THEN Bad('HIR call argument has no value') END;
        IF (X.Opcode=OpParam) AND (X.Dst=0) THEN Bad('HIR parameter has no destination') END;
        IF ((X.Opcode=OpLoadPtr) OR (X.Opcode=OpStorePtr) OR (X.Opcode=OpLeaOffset)) AND (X.A=0) THEN Bad('HIR pointer instruction has no base address') END;
        IF ((X.Opcode=OpDiv) OR (X.Opcode=OpMod) OR (X.Opcode=OpFDiv)) AND (X.B=0) THEN Bad('HIR division instruction has no divisor value') END;
        IF (X.Opcode=OpAtomicCAS) AND ((X.A=0) OR (X.B=0) OR (X.Label=0)) THEN Bad('HIR compare-exchange is missing pointer, expected, or desired value') END;
        I:=X.Next
    END
END CheckFunction;

PROCEDURE Run():BOOLEAN;
VAR F:FuncId;
BEGIN
    F:=1; WHILE F<=FuncCount() DO CheckFunction(F); INC(F) END;
    RETURN NOT HasErrors()
END Run;

END Verify.
