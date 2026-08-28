IMPLEMENTATION MODULE Interfaces;
FROM HStrings IMPORT Text,Assign,Equal,Length,AppendChar;
FROM Types IMPORT TypeId;
FROM Diagnostics IMPORT SimpleCode,Severity;
FROM ErrorCodes IMPORT EArenaInterfaces;
VAR Modules:ARRAY[0..MaxInterfaceModules-1] OF Text; ModuleCount:CARDINAL;
    Definitions:ARRAY[0..MaxInterfaceModules-1] OF Text; DefinitionCount:CARDINAL;
    Members:ARRAY[0..MaxInterfaceMembers-1] OF Member; MemberCount:CARDINAL;
TYPE ImportBinding=RECORD Owner,LocalName,ModuleName,MemberName:Text; Selective:BOOLEAN END;
VAR Bindings:ARRAY[0..MaxInterfaceMembers-1] OF ImportBinding; BindingCount:CARDINAL;
PROCEDURE Init; BEGIN ModuleCount:=0; MemberCount:=0; BindingCount:=0; DefinitionCount:=0 END Init;
PROCEDURE ModuleKnown(Name:ARRAY OF CHAR):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<ModuleCount DO IF Equal(Modules[I],Name) THEN RETURN TRUE END; INC(I) END; RETURN FALSE END ModuleKnown;
PROCEDURE RegisterModule(Name:ARRAY OF CHAR);
BEGIN
    IF ModuleKnown(Name) THEN RETURN END;
    IF ModuleCount>=MaxInterfaceModules THEN SimpleCode(Fatal,EArenaInterfaces,'module interface table exhausted'); RETURN END;
    Assign(Modules[ModuleCount],Name); INC(ModuleCount)
END RegisterModule;
PROCEDURE HasDefinition(Name:ARRAY OF CHAR):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<DefinitionCount DO IF Equal(Definitions[I],Name) THEN RETURN TRUE END; INC(I) END; RETURN FALSE END HasDefinition;
PROCEDURE RegisterDefinition(Name:ARRAY OF CHAR);
BEGIN
    RegisterModule(Name); IF HasDefinition(Name) THEN RETURN END;
    IF DefinitionCount>=MaxInterfaceModules THEN SimpleCode(Fatal,EArenaInterfaces,'definition module table exhausted'); RETURN END;
    Assign(Definitions[DefinitionCount],Name); INC(DefinitionCount)
END RegisterDefinition;
PROCEDURE Add(Module,Name:ARRAY OF CHAR; Kind:MemberKind; Ty:TypeId; LinkName:ARRAY OF CHAR);
VAR I:CARDINAL;
BEGIN
    I:=0; WHILE I<MemberCount DO
        IF Equal(Members[I].Module,Module) AND Equal(Members[I].Name,Name) THEN
            Members[I].Kind:=Kind; Members[I].TypeId:=Ty; Members[I].HasConst:=FALSE; Members[I].ConstValue:=0; Members[I].ConstText[0]:=0C; Assign(Members[I].LinkName,LinkName); RETURN
        END; INC(I)
    END;
    IF MemberCount>=MaxInterfaceMembers THEN SimpleCode(Fatal,EArenaInterfaces,'module interface member table exhausted'); RETURN END;
    Assign(Members[MemberCount].Module,Module); Assign(Members[MemberCount].Name,Name); Assign(Members[MemberCount].LinkName,LinkName);
    Members[MemberCount].Kind:=Kind; Members[MemberCount].TypeId:=Ty; Members[MemberCount].HasConst:=FALSE; Members[MemberCount].ConstValue:=0; Members[MemberCount].ConstText[0]:=0C; INC(MemberCount)
END Add;
PROCEDURE AddConst(Module,Name:ARRAY OF CHAR; Ty:TypeId; Value:LONGINT);
VAR I:CARDINAL;
BEGIN
    Add(Module,Name,MemberConst,Ty,''); I:=0;
    WHILE I<MemberCount DO IF Equal(Members[I].Module,Module) AND Equal(Members[I].Name,Name) THEN Members[I].HasConst:=TRUE; Members[I].ConstValue:=Value; RETURN END; INC(I) END
END AddConst;
PROCEDURE AddConstText(Module,Name:ARRAY OF CHAR; Ty:TypeId; Value:ARRAY OF CHAR);
VAR I:CARDINAL;
BEGIN
    Add(Module,Name,MemberConst,Ty,''); I:=0;
    WHILE I<MemberCount DO IF Equal(Members[I].Module,Module) AND Equal(Members[I].Name,Name) THEN Members[I].HasConst:=TRUE; Members[I].ConstValue:=0; Assign(Members[I].ConstText,Value); RETURN END; INC(I) END
END AddConstText;
PROCEDURE Find(Module,Name:ARRAY OF CHAR; VAR Out:Member):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<MemberCount DO IF Equal(Members[I].Module,Module) AND Equal(Members[I].Name,Name) THEN Out:=Members[I]; RETURN TRUE END; INC(I) END; RETURN FALSE END Find;
PROCEDURE FindQualified(Name:ARRAY OF CHAR; VAR Out:Member):BOOLEAN;
VAR I,N,Dot:CARDINAL; M,S:Text;
BEGIN
    N:=Length(Name); Dot:=N; I:=0; WHILE I<N DO IF Name[I]='.' THEN Dot:=I END; INC(I) END;
    IF Dot=N THEN RETURN FALSE END; M[0]:=0C; S[0]:=0C; I:=0;
    WHILE I<Dot DO AppendChar(M,Name[I]); INC(I) END; I:=Dot+1;
    WHILE I<N DO AppendChar(S,Name[I]); INC(I) END;
    RETURN Find(M,S,Out)
END FindQualified;

PROCEDURE AddBinding(Owner,LocalName,ModuleName,MemberName:ARRAY OF CHAR; Selective:BOOLEAN);
VAR I:CARDINAL;
BEGIN
    I:=0;
    WHILE I<BindingCount DO
        IF Equal(Bindings[I].Owner,Owner) AND Equal(Bindings[I].LocalName,LocalName) AND
           (Bindings[I].Selective=Selective) THEN
            Assign(Bindings[I].ModuleName,ModuleName); Assign(Bindings[I].MemberName,MemberName); RETURN
        END;
        INC(I)
    END;
    IF BindingCount>=MaxInterfaceMembers THEN SimpleCode(Fatal,EArenaInterfaces,'import binding table exhausted'); RETURN END;
    Assign(Bindings[BindingCount].Owner,Owner); Assign(Bindings[BindingCount].LocalName,LocalName);
    Assign(Bindings[BindingCount].ModuleName,ModuleName); Assign(Bindings[BindingCount].MemberName,MemberName);
    Bindings[BindingCount].Selective:=Selective; INC(BindingCount)
END AddBinding;

PROCEDURE RegisterAlias(Owner,LocalName,ModuleName:ARRAY OF CHAR);
BEGIN AddBinding(Owner,LocalName,ModuleName,'',FALSE) END RegisterAlias;

PROCEDURE RegisterSelective(Owner,LocalName,ModuleName,MemberName:ARRAY OF CHAR);
BEGIN AddBinding(Owner,LocalName,ModuleName,MemberName,TRUE) END RegisterSelective;

PROCEDURE ResolveModule(Owner,LocalName:ARRAY OF CHAR; VAR ModuleName:Text):BOOLEAN;
VAR I:CARDINAL;
BEGIN
    I:=0; WHILE I<BindingCount DO
        IF NOT Bindings[I].Selective AND Equal(Bindings[I].Owner,Owner) AND Equal(Bindings[I].LocalName,LocalName) THEN
            Assign(ModuleName,Bindings[I].ModuleName); RETURN TRUE
        END;
        INC(I)
    END;
    RETURN FALSE
END ResolveModule;

PROCEDURE FindVisible(Owner,LocalModule,Name:ARRAY OF CHAR; VAR Out:Member):BOOLEAN;
VAR Actual:Text;
BEGIN
    IF ResolveModule(Owner,LocalModule,Actual) THEN RETURN Find(Actual,Name,Out) END;
    RETURN FALSE
END FindVisible;

PROCEDURE FindSelective(Owner,LocalName:ARRAY OF CHAR; VAR Out:Member):BOOLEAN;
VAR I:CARDINAL;
BEGIN
    I:=0; WHILE I<BindingCount DO
        IF Bindings[I].Selective AND Equal(Bindings[I].Owner,Owner) AND Equal(Bindings[I].LocalName,LocalName) THEN
            RETURN Find(Bindings[I].ModuleName,Bindings[I].MemberName,Out)
        END;
        INC(I)
    END;
    RETURN FALSE
END FindSelective;

PROCEDURE FindQualifiedVisible(Owner,Name:ARRAY OF CHAR; VAR Out:Member):BOOLEAN;
VAR I,N,Dot:CARDINAL; M,S:Text;
BEGIN
    N:=Length(Name); Dot:=N; I:=0; WHILE (I<N) AND (Dot=N) DO IF Name[I]='.' THEN Dot:=I END; INC(I) END;
    IF Dot=N THEN RETURN FindSelective(Owner,Name,Out) END;
    M[0]:=0C; S[0]:=0C; I:=0; WHILE I<Dot DO AppendChar(M,Name[I]); INC(I) END; I:=Dot+1;
    WHILE I<N DO AppendChar(S,Name[I]); INC(I) END;
    RETURN FindVisible(Owner,M,S,Out)
END FindQualifiedVisible;
PROCEDURE Count():CARDINAL; BEGIN RETURN MemberCount END Count;
PROCEDURE Get(Index:CARDINAL):Member;
VAR Empty:Member;
BEGIN IF Index<MemberCount THEN RETURN Members[Index] END; Empty.Kind:=MemberNone; Empty.Module[0]:=0C; Empty.Name[0]:=0C; Empty.LinkName[0]:=0C; Empty.ConstText[0]:=0C; Empty.TypeId:=0; Empty.ConstValue:=0; Empty.HasConst:=FALSE; RETURN Empty END Get;
END Interfaces.
