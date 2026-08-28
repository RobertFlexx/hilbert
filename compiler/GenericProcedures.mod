IMPLEMENTATION MODULE GenericProcedures;

IMPORT AST;
FROM AST IMPORT NodeId,Node,NodeKind;
FROM Generics IMPORT ActualArray,MaxGenericParams;
FROM HStrings IMPORT Text,Assign,Append,AppendChar,Equal;
FROM Types IMPORT TypeId;
FROM Diagnostics IMPORT SimpleCode,Severity;
FROM ErrorCodes IMPORT EGenericArity,EArenaAST;

CONST MaxRequests=4096; MaxRequestArgs=32768;
TYPE RequestRec=RECORD Owner,Name,LinkName,SpecializedName,SpecializedLink:Text; First,Count:CARDINAL; Emitted,Materialized:BOOLEAN END;

VAR Requests:ARRAY[0..MaxRequests-1] OF RequestRec; RequestArgs:ARRAY[0..MaxRequestArgs-1] OF TypeId;
    RequestCount,RequestArgCount:CARDINAL;
    ParamNames:ARRAY[0..MaxGenericParams-1] OF Text; ParamTypes:ActualArray; ParamCount:CARDINAL;

PROCEDURE Init;
BEGIN RequestCount:=0; RequestArgCount:=0; ParamCount:=0 END Init;

PROCEDURE CardText(Value:CARDINAL; VAR Out:Text);
VAR Digits:ARRAY[0..31] OF CHAR; N,I:CARDINAL;
BEGIN
    Out[0]:=0C; IF Value=0 THEN AppendChar(Out,'0'); RETURN END; N:=0;
    WHILE Value>0 DO Digits[N]:=VAL(CHAR,ORD('0')+Value MOD 10); INC(N); Value:=Value DIV 10 END;
    I:=N; WHILE I>0 DO DEC(I); AppendChar(Out,Digits[I]) END
END CardText;

PROCEDURE SameRequest(I:CARDINAL; Owner,Name:ARRAY OF CHAR; VAR Actuals:ActualArray; Count:CARDINAL):BOOLEAN;
VAR J:CARDINAL;
BEGIN
    IF NOT Equal(Requests[I].Owner,Owner) OR NOT Equal(Requests[I].Name,Name) OR (Requests[I].Count#Count) THEN RETURN FALSE END;
    J:=0; WHILE J<Count DO IF RequestArgs[Requests[I].First+J]#Actuals[J] THEN RETURN FALSE END; INC(J) END; RETURN TRUE
END SameRequest;

PROCEDURE Request(Owner,Name,LinkName:ARRAY OF CHAR; VAR Actuals:ActualArray; Count:CARDINAL; VAR SpecializedLink:Text);
VAR I,J:CARDINAL; Number:Text;
BEGIN
    I:=0; WHILE I<RequestCount DO IF SameRequest(I,Owner,Name,Actuals,Count) THEN Assign(SpecializedLink,Requests[I].SpecializedLink); RETURN END; INC(I) END;
    IF RequestCount>=MaxRequests THEN SimpleCode(Fatal,EGenericArity,'generic procedure request table exhausted'); SpecializedLink[0]:=0C; RETURN END;
    IF RequestArgCount+Count>MaxRequestArgs THEN SimpleCode(Fatal,EGenericArity,'generic procedure argument table exhausted'); SpecializedLink[0]:=0C; RETURN END;
    Assign(Requests[RequestCount].Owner,Owner); Assign(Requests[RequestCount].Name,Name); Assign(Requests[RequestCount].LinkName,LinkName);
    Assign(Requests[RequestCount].SpecializedName,Name); Append(Requests[RequestCount].SpecializedName,'__g'); J:=0;
    WHILE J<Count DO Append(Requests[RequestCount].SpecializedName,'_t'); CardText(Actuals[J],Number); Append(Requests[RequestCount].SpecializedName,Number); INC(J) END;
    Assign(Requests[RequestCount].SpecializedLink,Owner); Append(Requests[RequestCount].SpecializedLink,'__'); Append(Requests[RequestCount].SpecializedLink,Requests[RequestCount].SpecializedName);
    Requests[RequestCount].First:=RequestArgCount; Requests[RequestCount].Count:=Count; Requests[RequestCount].Emitted:=FALSE; Requests[RequestCount].Materialized:=FALSE;
    J:=0; WHILE J<Count DO RequestArgs[RequestArgCount]:=Actuals[J]; INC(RequestArgCount); INC(J) END;
    Assign(SpecializedLink,Requests[RequestCount].SpecializedLink); INC(RequestCount)
END Request;

PROCEDURE NeedsEmission(Owner:ARRAY OF CHAR):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<RequestCount DO IF Equal(Requests[I].Owner,Owner) AND NOT Requests[I].Emitted THEN RETURN TRUE END; INC(I) END; RETURN FALSE END NeedsEmission;

PROCEDURE MarkEmitted(Owner:ARRAY OF CHAR);
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<RequestCount DO IF Equal(Requests[I].Owner,Owner) AND Requests[I].Materialized THEN Requests[I].Emitted:=TRUE; Requests[I].Materialized:=FALSE END; INC(I) END END MarkEmitted;

PROCEDURE ParamReplacement(Name:ARRAY OF CHAR; VAR Ty:TypeId):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<ParamCount DO IF Equal(ParamNames[I],Name) THEN Ty:=ParamTypes[I]; RETURN TRUE END; INC(I) END; RETURN FALSE END ParamReplacement;

PROCEDURE CloneNode(Id:NodeId; WithNext:BOOLEAN):NodeId;
VAR N,C:Node; R:NodeId; Ty:TypeId;
BEGIN
    IF Id=0 THEN RETURN 0 END; N:=AST.Get(Id);
    IF ((N.Kind=NNamedType) OR (N.Kind=NName)) AND ParamReplacement(N.Text,Ty) THEN
        R:=AST.New(NResolvedType,N.Line,N.Column); C:=AST.Get(R); C.IntValue:=VAL(LONGINT,Ty);
        IF WithNext THEN C.Next:=CloneNode(N.Next,TRUE) END;
        AST.Put(R,C); RETURN R
    END;
    R:=AST.New(N.Kind,N.Line,N.Column); C:=N; C.A:=CloneNode(N.A,TRUE); C.B:=CloneNode(N.B,TRUE); C.C:=CloneNode(N.C,TRUE); C.D:=CloneNode(N.D,TRUE);
    IF WithNext THEN C.Next:=CloneNode(N.Next,TRUE) ELSE C.Next:=0 END; AST.Put(R,C); RETURN R
END CloneNode;

PROCEDURE RemoveGenericParams(Head:NodeId):NodeId;
VAR H,T,P,Next:NodeId; N,TN:Node;
BEGIN
    H:=0; T:=0; P:=Head;
    WHILE P#0 DO
        N:=AST.Get(P); Next:=N.Next; N.Next:=0; AST.Put(P,N);
        IF N.Kind#NGenericParam THEN
            IF H=0 THEN H:=P ELSE TN:=AST.Get(T); TN.Next:=P; AST.Put(T,TN) END; T:=P
        END;
        P:=Next
    END;
    RETURN H
END RemoveGenericParams;

PROCEDURE FindTemplate(Declarations:NodeId; Name:ARRAY OF CHAR):NodeId;
VAR P:NodeId; N:Node;
BEGIN
    P:=Declarations;
    WHILE P#0 DO
        N:=AST.Get(P);
        IF (N.Kind=NProcedure) AND Equal(N.Text,Name) THEN RETURN P END;
        IF (N.Kind=NDivision) AND (6 IN N.Flags) THEN
            P:=FindTemplate(N.B,Name); IF P#0 THEN RETURN P END; P:=N.Next
        ELSE P:=N.Next
        END
    END;
    RETURN 0
END FindTemplate;

PROCEDURE AppendDeclaration(VAR Declarations:NodeId; Item:NodeId);
VAR P:NodeId; N:Node;
BEGIN IF Declarations=0 THEN Declarations:=Item; RETURN END; P:=Declarations; LOOP N:=AST.Get(P); IF N.Next=0 THEN N.Next:=Item; AST.Put(P,N); RETURN END; P:=N.Next END END AppendDeclaration;

PROCEDURE Materialize(Owner:ARRAY OF CHAR; VAR Declarations:NodeId);
VAR I,J:CARDINAL; Template,Clone,Param:NodeId; N,C:Node;
BEGIN
    I:=0;
    WHILE I<RequestCount DO
        IF Equal(Requests[I].Owner,Owner) THEN
            Template:=FindTemplate(Declarations,Requests[I].Name);
            IF Template=0 THEN SimpleCode(Error,EGenericArity,'generic procedure implementation is missing')
            ELSE
                N:=AST.Get(Template); ParamCount:=0; Param:=N.D;
                WHILE (Param#0) AND (ParamCount<MaxGenericParams) DO
                    C:=AST.Get(Param);
                    IF C.Kind=NGenericParam THEN Assign(ParamNames[ParamCount],C.Text); ParamTypes[ParamCount]:=RequestArgs[Requests[I].First+ParamCount]; INC(ParamCount) END;
                    Param:=C.Next
                END;
                IF ParamCount#Requests[I].Count THEN SimpleCode(Error,EGenericArity,'generic procedure implementation has the wrong parameter count')
                ELSE
                    Clone:=CloneNode(Template,FALSE); C:=AST.Get(Clone); Assign(C.Text,Requests[I].SpecializedName); C.D:=RemoveGenericParams(C.D); C.Flags:=C.Flags+{5}; AST.Put(Clone,C); AppendDeclaration(Declarations,Clone); Requests[I].Materialized:=TRUE
                END
            END
        END;
        INC(I)
    END
END Materialize;

END GenericProcedures.
