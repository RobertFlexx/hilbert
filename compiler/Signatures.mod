IMPLEMENTATION MODULE Signatures;
FROM Types IMPORT TypeId;
FROM Diagnostics IMPORT SimpleCode,Severity;
FROM ErrorCodes IMPORT EArenaSignatures;
TYPE Sig=RECORD Proc:TypeId; First,Count:CARDINAL; Variadic:BOOLEAN END;
TYPE Param=RECORD Ty:TypeId; ByRef:BOOLEAN END;
VAR Sigs:ARRAY[0..MaxSignatures] OF Sig; Params:ARRAY[0..MaxSignatureParams] OF Param; NSig,NParam:CARDINAL;

PROCEDURE Init; BEGIN NSig:=0; NParam:=0 END Init;
PROCEDURE Find(P:TypeId):CARDINAL;
VAR I:CARDINAL;
BEGIN I:=1; WHILE I<=NSig DO IF Sigs[I].Proc=P THEN RETURN I END; INC(I) END; RETURN 0 END Find;
PROCEDURE BeginProcedure(ProcType:TypeId);
BEGIN
    IF Find(ProcType)#0 THEN RETURN END;
    IF NSig>=MaxSignatures THEN SimpleCode(Fatal,EArenaSignatures,'procedure signature table exhausted'); RETURN END;
    INC(NSig); Sigs[NSig].Proc:=ProcType; Sigs[NSig].First:=NParam+1; Sigs[NSig].Count:=0; Sigs[NSig].Variadic:=FALSE
END BeginProcedure;
PROCEDURE AddParameter(ProcType,ParamType:TypeId; ByRef:BOOLEAN);
VAR I:CARDINAL;
BEGIN
    I:=Find(ProcType); IF I=0 THEN BeginProcedure(ProcType); I:=Find(ProcType) END;
    IF NParam>=MaxSignatureParams THEN SimpleCode(Fatal,EArenaSignatures,'procedure parameter table exhausted'); RETURN END;
    INC(NParam); Params[NParam].Ty:=ParamType; Params[NParam].ByRef:=ByRef; INC(Sigs[I].Count)
END AddParameter;
PROCEDURE SetVariadic(ProcType:TypeId; Value:BOOLEAN);
VAR I:CARDINAL;
BEGIN I:=Find(ProcType); IF I=0 THEN BeginProcedure(ProcType); I:=Find(ProcType) END; Sigs[I].Variadic:=Value END SetVariadic;
PROCEDURE IsVariadic(ProcType:TypeId):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=Find(ProcType); IF I=0 THEN RETURN FALSE END; RETURN Sigs[I].Variadic END IsVariadic;
PROCEDURE ParameterCount(ProcType:TypeId):CARDINAL;
VAR I:CARDINAL;
BEGIN I:=Find(ProcType); IF I=0 THEN RETURN 0 END; RETURN Sigs[I].Count END ParameterCount;
PROCEDURE ParameterType(ProcType:TypeId; Index:CARDINAL):TypeId;
VAR I:CARDINAL;
BEGIN I:=Find(ProcType); IF (I=0) OR (Index>=Sigs[I].Count) THEN RETURN 0 END; RETURN Params[Sigs[I].First+Index].Ty END ParameterType;
PROCEDURE ParameterByRef(ProcType:TypeId; Index:CARDINAL):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=Find(ProcType); IF (I=0) OR (Index>=Sigs[I].Count) THEN RETURN FALSE END; RETURN Params[Sigs[I].First+Index].ByRef END ParameterByRef;
END Signatures.
