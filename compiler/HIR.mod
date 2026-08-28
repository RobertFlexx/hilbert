IMPLEMENTATION MODULE HIR;
FROM HStrings IMPORT Assign,Clear,NewLine;
FROM StrIO IMPORT WriteString;
FROM NumberIO IMPORT WriteCard;
FROM Diagnostics IMPORT SimpleCode,Severity;
FROM ErrorCodes IMPORT EArenaHIR;
VAR Ins:ARRAY[0..MaxInst] OF Inst; Fs:ARRAY[0..MaxFuncs] OF Func; Gs:ARRAY[0..MaxGlobals] OF Global; NI,NF,NG:CARDINAL;
PROCEDURE Init; BEGIN NI:=0; NF:=0; NG:=0 END Init;
PROCEDURE NewFunc(Name:ARRAY OF CHAR):FuncId;
VAR F:FuncId;
BEGIN
    IF NF>=MaxFuncs THEN SimpleCode(Fatal,EArenaHIR,'HIR function arena exhausted'); RETURN 0 END;
    INC(NF); F:=NF; Assign(Fs[F].Name,Name); Fs[F].First:=0; Fs[F].Last:=0;
    Fs[F].ParamCount:=0; Fs[F].LocalCount:=0; Fs[F].ValueCount:=0; Fs[F].StackSize:=0;
    Fs[F].Exported:=FALSE; Fs[F].Foreign:=FALSE; RETURN F
END NewFunc;
PROCEDURE Emit(F:FuncId; O:Op; D,A,B:ValueId; Imm:LONGINT):InstId;
VAR I:InstId; X:Inst;
BEGIN
    IF NI>=MaxInst THEN SimpleCode(Fatal,EArenaHIR,'HIR instruction arena exhausted'); RETURN 0 END;
    INC(NI); I:=NI; X.Opcode:=O; X.Dst:=D; X.A:=A; X.B:=B; X.Imm:=Imm; X.Label:=0; X.TypeId:=0; X.Next:=0; Clear(X.Text); Ins[I]:=X;
    IF Fs[F].First=0 THEN Fs[F].First:=I ELSE Ins[Fs[F].Last].Next:=I END; Fs[F].Last:=I; RETURN I
END Emit;
PROCEDURE GetInst(I:InstId):Inst; BEGIN RETURN Ins[I] END GetInst;
PROCEDURE PutInst(I:InstId; X:Inst); BEGIN Ins[I]:=X END PutInst;
PROCEDURE GetFunc(F:FuncId):Func; BEGIN RETURN Fs[F] END GetFunc;
PROCEDURE PutFunc(F:FuncId; X:Func); BEGIN Fs[F]:=X END PutFunc;
PROCEDURE FuncCount():CARDINAL; BEGIN RETURN NF END FuncCount;
PROCEDURE InstCount():CARDINAL; BEGIN RETURN NI END InstCount;
PROCEDURE NewValue(F:FuncId):ValueId; BEGIN INC(Fs[F].ValueCount); RETURN Fs[F].ValueCount END NewValue;
PROCEDURE NewGlobal(Name:ARRAY OF CHAR; Size,Align:CARDINAL):CARDINAL;
BEGIN
    IF NG>=MaxGlobals THEN SimpleCode(Fatal,EArenaHIR,'HIR global arena exhausted'); RETURN 0 END;
    INC(NG); Assign(Gs[NG].Name,Name); Gs[NG].Size:=Size; Gs[NG].Align:=Align; Gs[NG].Exported:=FALSE; RETURN NG
END NewGlobal;
PROCEDURE GetGlobal(G:CARDINAL):Global; BEGIN RETURN Gs[G] END GetGlobal;
PROCEDURE GlobalCount():CARDINAL; BEGIN RETURN NG END GlobalCount;
PROCEDURE Dump;
VAR F:FuncId; I:InstId; X:Inst;
BEGIN
    F:=1;
    WHILE F<=NF DO
        WriteString('func '); WriteString(Fs[F].Name); WriteString(' values='); WriteCard(Fs[F].ValueCount,0); NewLine;
        I:=Fs[F].First;
        WHILE I#0 DO
            X:=Ins[I]; WriteString('  '); WriteCard(I,0); WriteString(': op '); WriteCard(ORD(X.Opcode),0);
            IF X.Dst#0 THEN WriteString(' v'); WriteCard(X.Dst,0) END;
            IF X.A#0 THEN WriteString(' <- v'); WriteCard(X.A,0) END;
            IF X.B#0 THEN WriteString(', v'); WriteCard(X.B,0) END;
            IF X.Text[0]#0C THEN WriteString(' '); WriteString(X.Text) END; NewLine; I:=X.Next
        END;
        INC(F)
    END
END Dump;
END HIR.
