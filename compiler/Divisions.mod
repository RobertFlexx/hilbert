IMPLEMENTATION MODULE Divisions;

IMPORT AST, Diagnostics;
FROM AST IMPORT NodeId,Node,NodeKind;
FROM Target IMPORT Info,Architecture,OperatingSystem;
FROM Tokens IMPORT TokenKind,FromOrdinal,KwNOT,KwAND,KwOR;
FROM HStrings IMPORT Text,Assign,Equal;
FROM Source IMPORT FileName,LineText;
FROM ErrorCodes IMPORT EDivisionCondition;
FROM Diagnostics IMPORT Severity;

VAR CurrentTarget:Info; CurrentProfile,CurrentRuntime:Text; Configured:BOOLEAN;

PROCEDURE Configure(T:Info; Profile,Runtime:ARRAY OF CHAR);
BEGIN
    CurrentTarget:=T; Assign(CurrentProfile,Profile); Assign(CurrentRuntime,Runtime); Configured:=TRUE
END Configure;

PROCEDURE ErrorAt(N:Node; Message:ARRAY OF CHAR);
VAR F,L:Text;
BEGIN
    FileName(F); LineText(N.Line,L);
    Diagnostics.CodedContext(Error,EDivisionCondition,F,N.Line,N.Column,Message,L)
END ErrorAt;

PROCEDURE TargetMatches(Name:ARRAY OF CHAR):BOOLEAN;
BEGIN
    IF Equal(Name,CurrentTarget.Triple) THEN RETURN TRUE END;
    CASE CurrentTarget.OS OF
    | OSLinux:RETURN Equal(Name,'linux')
    | OSFreeBSD:RETURN Equal(Name,'freebsd')
    | OSWindows:RETURN Equal(Name,'windows')
    | OSMacOS:RETURN Equal(Name,'macos')
    ELSE RETURN FALSE
    END
END TargetMatches;

PROCEDURE ArchMatches(Name:ARRAY OF CHAR):BOOLEAN;
BEGIN
    CASE CurrentTarget.Arch OF
    | ArchX8664:RETURN Equal(Name,'x86_64')
    | ArchAArch64:RETURN Equal(Name,'aarch64')
    ELSE RETURN FALSE
    END
END ArchMatches;

PROCEDURE Eval(Id:NodeId; Diagnose:BOOLEAN; VAR Valid:BOOLEAN):BOOLEAN;
VAR N,C,A:Node; K:TokenKind; Left,Right:BOOLEAN;
BEGIN
    IF Id=0 THEN Valid:=TRUE; RETURN TRUE END;
    N:=AST.Get(Id);
    IF N.Kind=NBoolean THEN Valid:=TRUE; RETURN N.IntValue#0 END;
    IF N.Kind=NName THEN
        Valid:=TRUE;
        IF Equal(N.Text,'HOSTED') THEN RETURN Equal(CurrentRuntime,'hosted') END;
        IF Equal(N.Text,'FREESTANDING') THEN RETURN Equal(CurrentRuntime,'freestanding') END;
        IF Equal(N.Text,'DEBUG') THEN RETURN Equal(CurrentProfile,'debug') END;
        IF Equal(N.Text,'RELEASE') THEN RETURN Equal(CurrentProfile,'release') END;
        IF Equal(N.Text,'SIZE') THEN RETURN Equal(CurrentProfile,'size') END;
        Valid:=FALSE; IF Diagnose THEN ErrorAt(N,'unknown compiler condition in DIVISION WHEN') END; RETURN FALSE
    END;
    IF N.Kind=NUnary THEN
        K:=FromOrdinal(N.IntValue);
        IF K#KwNOT THEN Valid:=FALSE; IF Diagnose THEN ErrorAt(N,'DIVISION conditions only allow NOT as a unary operator') END; RETURN FALSE END;
        Left:=Eval(N.A,Diagnose,Valid); RETURN NOT Left
    END;
    IF N.Kind=NBinary THEN
        K:=FromOrdinal(N.IntValue);
        IF (K#KwAND) AND (K#KwOR) THEN Valid:=FALSE; IF Diagnose THEN ErrorAt(N,'DIVISION conditions only allow AND and OR') END; RETURN FALSE END;
        Left:=Eval(N.A,Diagnose,Valid); IF NOT Valid THEN RETURN FALSE END;
        Right:=Eval(N.B,Diagnose,Valid); IF NOT Valid THEN RETURN FALSE END;
        IF K=KwAND THEN RETURN Left AND Right ELSE RETURN Left OR Right END
    END;
    IF N.Kind=NCall THEN
        C:=AST.Get(N.A);
        IF (C.Kind#NName) OR (N.B=0) THEN Valid:=FALSE; IF Diagnose THEN ErrorAt(N,'DIVISION conditions only allow TARGET and ARCH queries') END; RETURN FALSE END;
        A:=AST.Get(N.B);
        IF (A.Kind#NString) OR (A.Next#0) THEN Valid:=FALSE; IF Diagnose THEN ErrorAt(N,'TARGET and ARCH require one string literal') END; RETURN FALSE END;
        Valid:=TRUE;
        IF Equal(C.Text,'TARGET') THEN RETURN TargetMatches(A.Text) END;
        IF Equal(C.Text,'ARCH') THEN RETURN ArchMatches(A.Text) END;
        Valid:=FALSE; IF Diagnose THEN ErrorAt(C,'DIVISION conditions only allow TARGET and ARCH queries') END; RETURN FALSE
    END;
    Valid:=FALSE; IF Diagnose THEN ErrorAt(N,'DIVISION WHEN is restricted to compiler-known conditions') END; RETURN FALSE
END Eval;

PROCEDURE Active(Id:NodeId; Diagnose:BOOLEAN):BOOLEAN;
VAR N:Node; Valid,Chosen:BOOLEAN;
BEGIN
    N:=AST.Get(Id); IF N.Kind#NDivision THEN RETURN TRUE END;
    IF NOT Configured THEN Valid:=TRUE; RETURN N.A=0 END;
    Chosen:=Eval(N.A,Diagnose,Valid); RETURN Valid AND Chosen
END Active;

PROCEDURE Mark(Declarations:NodeId; Diagnose:BOOLEAN);
VAR I:NodeId; N:Node;
BEGIN
    I:=Declarations;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF N.Kind=NDivision THEN
            N.Flags:=N.Flags-{6}; IF Active(I,Diagnose) THEN N.Flags:=N.Flags+{6} END; AST.Put(I,N)
        END;
        I:=N.Next
    END
END Mark;

BEGIN Configured:=FALSE
END Divisions.
