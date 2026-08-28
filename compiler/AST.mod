IMPLEMENTATION MODULE AST;
FROM StrIO IMPORT WriteString;
FROM NumberIO IMPORT WriteCard;
FROM HStrings IMPORT Clear,NewLine;
FROM Diagnostics IMPORT SimpleCode, Severity;
FROM ErrorCodes IMPORT EArenaAST;
VAR Arena: ARRAY [0..MaxNodes] OF Node; Used: CARDINAL;
PROCEDURE Init; BEGIN Used:=0 END Init;
PROCEDURE New(K: NodeKind; Line, Column: CARDINAL): NodeId;
VAR I: NodeId;
BEGIN
    IF Used>=MaxNodes THEN SimpleCode(Fatal,EArenaAST,'AST arena exhausted'); RETURN 0 END;
    INC(Used); I:=Used; Arena[I].Kind:=K; Arena[I].A:=0; Arena[I].B:=0; Arena[I].C:=0; Arena[I].D:=0; Arena[I].Next:=0;
    Arena[I].Line:=Line; Arena[I].Column:=Column; Arena[I].IntValue:=0; Arena[I].Flags:={}; Clear(Arena[I].Text); RETURN I
END New;
PROCEDURE Get(Id: NodeId): Node; BEGIN RETURN Arena[Id] END Get;
PROCEDURE Put(Id: NodeId; N: Node); BEGIN Arena[Id]:=N END Put;
PROCEDURE Count(): CARDINAL; BEGIN RETURN Used END Count;
PROCEDURE Append(VAR Head, Tail: NodeId; Item: NodeId);
VAR N: Node;
BEGIN IF Head=0 THEN Head:=Item; Tail:=Item ELSE N:=Arena[Tail]; N.Next:=Item; Arena[Tail]:=N; Tail:=Item END END Append;
PROCEDURE DumpNode(Id: NodeId; Depth: CARDINAL);
VAR N: Node; I: CARDINAL;
BEGIN
    IF Id=0 THEN RETURN END; N:=Arena[Id]; I:=0; WHILE I<Depth DO WriteString('  '); INC(I) END;
    WriteString('#'); WriteCard(Id,0); WriteString(' kind='); WriteCard(ORD(N.Kind),0);
    IF N.Text[0]#0C THEN WriteString(' '); WriteString(N.Text) END; NewLine;
    IF N.A#0 THEN DumpNode(N.A,Depth+1) END; IF N.B#0 THEN DumpNode(N.B,Depth+1) END; IF N.C#0 THEN DumpNode(N.C,Depth+1) END; IF N.D#0 THEN DumpNode(N.D,Depth+1) END;
    IF N.Next#0 THEN DumpNode(N.Next,Depth) END
END DumpNode;
PROCEDURE Dump(Root: NodeId); BEGIN DumpNode(Root,0) END Dump;
END AST.
