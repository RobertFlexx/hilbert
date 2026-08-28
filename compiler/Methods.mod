IMPLEMENTATION MODULE Methods;

FROM HStrings IMPORT Assign,Equal;
FROM Types IMPORT TypeId,Type,Get;
FROM Diagnostics IMPORT SimpleCode,Severity;
FROM ErrorCodes IMPORT EArenaInterfaces;

VAR Items:ARRAY [0..MaxMethods] OF Method; Used:CARDINAL;

PROCEDURE Init;
BEGIN Used:=0 END Init;

PROCEDURE Add(Owner:TypeId; Name:ARRAY OF CHAR; ProcType:TypeId; LinkName:ARRAY OF CHAR; ByRef:BOOLEAN);
BEGIN
    IF Used>=MaxMethods THEN SimpleCode(Fatal,EArenaInterfaces,'receiver method table exhausted'); RETURN END;
    INC(Used); Items[Used].Owner:=Owner; Items[Used].ProcType:=ProcType; Assign(Items[Used].Name,Name); Assign(Items[Used].LinkName,LinkName); Items[Used].ByRef:=ByRef
END Add;

PROCEDURE FindDirect(Owner:TypeId; Name:ARRAY OF CHAR; VAR Out:Method):BOOLEAN;
VAR I:CARDINAL;
BEGIN
    I:=Used; WHILE I>0 DO IF (Items[I].Owner=Owner) AND Equal(Items[I].Name,Name) THEN Out:=Items[I]; RETURN TRUE END; DEC(I) END; RETURN FALSE
END FindDirect;

PROCEDURE Find(Owner:TypeId; Name:ARRAY OF CHAR; VAR Out:Method):BOOLEAN;
VAR T:Type;
BEGIN
    WHILE Owner#0 DO IF FindDirect(Owner,Name,Out) THEN RETURN TRUE END; T:=Get(Owner); Owner:=T.Base END; RETURN FALSE
END Find;

PROCEDURE Count():CARDINAL;
BEGIN RETURN Used END Count;

END Methods.
