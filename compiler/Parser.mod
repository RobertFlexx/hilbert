IMPLEMENTATION MODULE Parser;

FROM Lexer IMPORT Init, Next;
FROM Tokens IMPORT Token, TokenKind, KindName;
FROM AST IMPORT NodeId, Node, NodeKind, New, Get, Put, Append;
IMPORT HStrings;
FROM HStrings IMPORT Text, Assign;
FROM Source IMPORT FileName,LineText;
IMPORT Diagnostics;
FROM Diagnostics IMPORT Report, Severity, HasErrors;
FROM ErrorCodes IMPORT EUnexpectedToken,EExpectedIdentifier,ETypeExpected,EExpressionExpected,EStatementExpected,EReservedFeature,EProcedureEndMismatch,EModuleEndMismatch,EDivisionEndMismatch;

VAR Cur: Token; ParsingDefinition:BOOLEAN;

PROCEDURE Advance;
BEGIN Next(Cur) END Advance;

PROCEDURE ErrorHereCode(Code:CARDINAL; M:ARRAY OF CHAR);
VAR F,L:Text;
BEGIN FileName(F); LineText(Cur.Line,L); Diagnostics.CodedContext(Error,Code,F,Cur.Line,Cur.Column,M,L) END ErrorHereCode;

PROCEDURE ErrorHere(M: ARRAY OF CHAR);
BEGIN ErrorHereCode(EUnexpectedToken,M) END ErrorHere;

PROCEDURE Expected(K:TokenKind);
VAR Want,M:Text;
BEGIN
    KindName(K,Want); Assign(M,'expected '); HStrings.Append(M,Want);
    IF Cur.Text[0]#0C THEN HStrings.Append(M,', found '); HStrings.Append(M,Cur.Text) END;
    ErrorHereCode(EUnexpectedToken,M)
END Expected;

PROCEDURE Accept(K: TokenKind): BOOLEAN;
BEGIN
    IF Cur.Kind=K THEN Advance; RETURN TRUE END;
    RETURN FALSE
END Accept;

PROCEDURE Expect(K: TokenKind);
BEGIN
    IF Cur.Kind#K THEN Expected(K) ELSE Advance END
END Expect;


PROCEDURE AppendList(VAR Head,Tail:NodeId; List:NodeId);
VAR I:NodeId; N:Node;
BEGIN
    I:=List;
    WHILE I#0 DO
        N:=Get(I);
        IF Head=0 THEN Head:=I ELSE N:=Get(Tail); N.Next:=I; Put(Tail,N) END;
        Tail:=I; N:=Get(I); I:=N.Next
    END
END AppendList;

PROCEDURE AtStop(A,B,C:TokenKind):BOOLEAN;
BEGIN RETURN (Cur.Kind=A) OR (Cur.Kind=B) OR (Cur.Kind=C) OR (Cur.Kind=TkEOF) END AtStop;

PROCEDURE ParseBlock(A,B,C:TokenKind):NodeId;
VAR Id,H,T,S:NodeId; N:Node;
BEGIN
    Id:=New(NBlock,Cur.Line,Cur.Column); H:=0; T:=0;
    WHILE NOT AtStop(A,B,C) DO
        S:=ParseStatement(); Append(H,T,S);
        IF Cur.Kind=TkSemicolon THEN Advance END
    END;
    N:=Get(Id); N.A:=H; Put(Id,N); RETURN Id
END ParseBlock;

PROCEDURE QualifiedText(VAR S:Text);
BEGIN
    S[0]:=0C;
    IF Cur.Kind#TkIdentifier THEN ErrorHereCode(EExpectedIdentifier,'expected identifier'); RETURN END;
    Assign(S,Cur.Text); Advance;
    WHILE Accept(TkDot) DO
        IF Cur.Kind#TkIdentifier THEN ErrorHereCode(EExpectedIdentifier,'expected identifier after dot'); RETURN END;
        HStrings.Append(S,'.'); HStrings.Append(S,Cur.Text); Advance
    END
END QualifiedText;

PROCEDURE NameNode():NodeId;
VAR Id:NodeId; N:Node; M:Text;
BEGIN
    Id:=New(NName,Cur.Line,Cur.Column); N:=Get(Id);
    IF Cur.Kind=TkIdentifier THEN Assign(N.Text,Cur.Text); Advance
    ELSIF ORD(Cur.Kind)>=ORD(KwMODULE) THEN
        Assign(M,'reserved word '); HStrings.Append(M,Cur.Text); HStrings.Append(M,' cannot be used as an identifier');
        ErrorHereCode(EExpectedIdentifier,M); Advance
    ELSE
        ErrorHereCode(EExpectedIdentifier,'expected identifier')
    END;
    Put(Id,N); RETURN Id
END NameNode;

PROCEDURE ParsePrimary(): NodeId;
VAR Id,ArgsH,ArgsT,A,T: NodeId; N: Node;
BEGIN
    CASE Cur.Kind OF
    | TkIdentifier:
        Id:=NameNode()
    | TkInteger:
        Id:=New(NInteger,Cur.Line,Cur.Column); N:=Get(Id); Assign(N.Text,Cur.Text); Put(Id,N); Advance
    | TkReal:
        Id:=New(NReal,Cur.Line,Cur.Column); N:=Get(Id); Assign(N.Text,Cur.Text); Put(Id,N); Advance
    | TkString:
        Id:=New(NString,Cur.Line,Cur.Column); N:=Get(Id); Assign(N.Text,Cur.Text); Put(Id,N); Advance
    | TkChar:
        Id:=New(NChar,Cur.Line,Cur.Column); N:=Get(Id); Assign(N.Text,Cur.Text); N.IntValue:=Cur.IntValue; Put(Id,N); Advance
    | KwTRUE, KwFALSE:
        Id:=New(NBoolean,Cur.Line,Cur.Column); N:=Get(Id);
        IF Cur.Kind=KwTRUE THEN N.IntValue:=1 ELSE N.IntValue:=0 END;
        Put(Id,N); Advance
    | KwNIL:
        Id:=New(NNil,Cur.Line,Cur.Column); Advance
    | TkLBrace:
        Id:=New(NSetLiteral,Cur.Line,Cur.Column); ArgsH:=0; ArgsT:=0; Advance;
        IF Cur.Kind#TkRBrace THEN
            LOOP
                A:=ParseExpr(); Append(ArgsH,ArgsT,A);
                IF NOT Accept(TkComma) THEN EXIT END
            END
        END;
        Expect(TkRBrace); N:=Get(Id); N.A:=ArgsH; Put(Id,N)
    | KwSIZEOF:
        Id:=New(NSizeOf,Cur.Line,Cur.Column); Advance; Expect(TkLParen); N:=Get(Id); N.A:=ParseTypeExpr(); Put(Id,N); Expect(TkRParen)
    | KwALIGNOF:
        Id:=New(NAlignOf,Cur.Line,Cur.Column); Advance; Expect(TkLParen); N:=Get(Id); N.A:=ParseTypeExpr(); Put(Id,N); Expect(TkRParen)
    | KwADR:
        Id:=New(NAddressOf,Cur.Line,Cur.Column); Advance; Expect(TkLParen); N:=Get(Id); N.A:=ParseExpr(); Put(Id,N); Expect(TkRParen)
    | KwNEW:
        Id:=New(NNew,Cur.Line,Cur.Column); Advance; Expect(TkLParen); N:=Get(Id); N.A:=ParseTypeExpr(); Put(Id,N); Expect(TkRParen)
    | TkLParen:
        Advance; Id:=ParseExpr(); Expect(TkRParen)
    | KwSTART:
        Id:=New(NStart,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParsePrimary(); Put(Id,N)
    | KwAWAIT:
        Id:=New(NAwait,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParsePrimary(); Put(Id,N)
    ELSE
        ErrorHere('expected expression'); Id:=New(NNone,Cur.Line,Cur.Column); Advance
    END;

    LOOP
        IF Cur.Kind=TkLParen THEN
            T:=New(NCall,Cur.Line,Cur.Column); N:=Get(T); N.A:=Id; ArgsH:=0; ArgsT:=0; Advance;
            IF Cur.Kind#TkRParen THEN
                LOOP
                    A:=ParseExpr(); Append(ArgsH,ArgsT,A);
                    IF NOT Accept(TkComma) THEN EXIT END
                END
            END;
            Expect(TkRParen); N.B:=ArgsH; Put(T,N); Id:=T
        ELSIF Cur.Kind=TkDot THEN
            Advance;
            IF Cur.Kind#TkIdentifier THEN ErrorHere('expected field or module member name'); RETURN Id END;
            T:=New(NSelect,Cur.Line,Cur.Column); N:=Get(T); N.A:=Id; Assign(N.Text,Cur.Text); Put(T,N); Advance; Id:=T
        ELSIF Cur.Kind=TkLBracket THEN
            Advance; T:=New(NIndex,Cur.Line,Cur.Column); N:=Get(T); N.A:=Id; ArgsH:=0; ArgsT:=0;
            LOOP A:=ParseExpr(); Append(ArgsH,ArgsT,A); IF NOT Accept(TkComma) THEN EXIT END END;
            N.B:=ArgsH; Put(T,N); Expect(TkRBracket); Id:=T
        ELSIF Cur.Kind=TkCaret THEN
            T:=New(NDeref,Cur.Line,Cur.Column); Advance; N:=Get(T); N.A:=Id; Put(T,N); Id:=T
        ELSE EXIT
        END
    END;
    RETURN Id
END ParsePrimary;

PROCEDURE ParseUnary(): NodeId;
VAR Id:NodeId; N:Node; K:TokenKind;
BEGIN
    IF (Cur.Kind=TkMinus) OR (Cur.Kind=TkPlus) OR (Cur.Kind=KwNOT) THEN
        K:=Cur.Kind; Id:=New(NUnary,Cur.Line,Cur.Column); Advance;
        N:=Get(Id); N.IntValue:=VAL(LONGINT,ORD(K)); N.A:=ParseUnary(); Put(Id,N); RETURN Id
    END;
    RETURN ParsePrimary()
END ParseUnary;

PROCEDURE Precedence(K: TokenKind): INTEGER;
BEGIN
    CASE K OF
    | KwOR,KwXOR: RETURN 1
    | KwAND: RETURN 2
    | TkEqual,TkNotEqual,TkLess,TkLessEqual,TkGreater,TkGreaterEqual,KwIN,KwIS: RETURN 3
    | TkPlus,TkMinus: RETURN 4
    | TkStar,TkSlash,KwDIV,KwMOD,KwSHL,KwSHR: RETURN 5
    ELSE RETURN 0
    END
END Precedence;

PROCEDURE ParseBinary(Min: INTEGER): NodeId;
VAR Left,Right,Id:NodeId; N:Node; P:INTEGER; Op:TokenKind;
BEGIN
    Left:=ParseUnary();
    LOOP
        P:=Precedence(Cur.Kind); IF P<Min THEN EXIT END;
        Op:=Cur.Kind;
        IF Op=KwIS THEN ErrorHereCode(EReservedFeature,'IS type tests are reserved for a later language revision') END;
        Advance; Right:=ParseBinary(P+1);
        Id:=New(NBinary,Cur.Line,Cur.Column); N:=Get(Id); N.A:=Left; N.B:=Right; N.IntValue:=VAL(LONGINT,ORD(Op)); Put(Id,N); Left:=Id
    END;
    RETURN Left
END ParseBinary;

PROCEDURE ParseExpr(): NodeId;
BEGIN RETURN ParseBinary(1) END ParseExpr;

PROCEDURE ParseGenericParams():NodeId;
VAR H,T,I,C:NodeId; N:Node;
BEGIN
    H:=0; T:=0; IF NOT Accept(TkLBracket) THEN RETURN 0 END;
    LOOP
        I:=New(NGenericParam,Cur.Line,Cur.Column); N:=Get(I);
        IF Cur.Kind=TkIdentifier THEN Assign(N.Text,Cur.Text); Advance ELSE ErrorHere('expected generic parameter name') END;
        IF Accept(TkColon) THEN
            ErrorHereCode(EReservedFeature,'generic constraints are reserved for a later language revision');
            C:=New(NNamedType,Cur.Line,Cur.Column); N.A:=C;
            N:=Get(C); QualifiedText(N.Text); Put(C,N); N:=Get(I)
        END;
        Put(I,N); Append(H,T,I);
        IF NOT Accept(TkComma) THEN EXIT END
    END;
    Expect(TkRBracket); RETURN H
END ParseGenericParams;

PROCEDURE ParseFormalParams():NodeId;
VAR H,T,P,NamesH,NamesT,I,Ty:NodeId; PN,N:Node; ByRef:BOOLEAN;
BEGIN
    H:=0; T:=0; IF NOT Accept(TkLParen) THEN RETURN 0 END;
    WHILE (Cur.Kind#TkRParen) AND (Cur.Kind#TkEOF) DO
        ByRef:=Accept(KwVAR); NamesH:=0; NamesT:=0;
        LOOP
            I:=NameNode(); Append(NamesH,NamesT,I); IF NOT Accept(TkComma) THEN EXIT END
        END;
        Expect(TkColon); Ty:=ParseTypeExpr();
        I:=NamesH;
        WHILE I#0 DO
            N:=Get(I); P:=New(NParam,N.Line,N.Column); PN:=Get(P); Assign(PN.Text,N.Text); PN.A:=Ty;
            IF ByRef THEN PN.Flags:={0} END; Put(P,PN); Append(H,T,P); I:=N.Next
        END;
        IF Cur.Kind=TkSemicolon THEN Advance
        ELSIF Cur.Kind#TkRParen THEN ErrorHere('expected semicolon between parameter groups'); Advance
        END
    END;
    Expect(TkRParen); RETURN H
END ParseFormalParams;

PROCEDURE ParseFields(UntilA,UntilB,UntilC:TokenKind):NodeId;
VAR H,T,NH,NT,NameId,F,Ty,I:NodeId; NN,FN:Node;
BEGIN
    H:=0; T:=0;
    WHILE (Cur.Kind#UntilA) AND (Cur.Kind#UntilB) AND (Cur.Kind#UntilC) AND (Cur.Kind#TkEOF) DO
        IF Cur.Kind#TkIdentifier THEN ErrorHere('expected field name'); Advance
        ELSE
            NH:=0; NT:=0;
            LOOP NameId:=NameNode(); Append(NH,NT,NameId); IF NOT Accept(TkComma) THEN EXIT END END;
            Expect(TkColon); Ty:=ParseTypeExpr(); Expect(TkSemicolon);
            I:=NH;
            WHILE I#0 DO NN:=Get(I); F:=New(NField,NN.Line,NN.Column); FN:=Get(F); Assign(FN.Text,NN.Text); FN.A:=Ty; Put(F,FN); Append(H,T,F); I:=NN.Next END
        END
    END;
    RETURN H
END ParseFields;

PROCEDURE ParseRecordVariant():NodeId;
VAR Id,H,T,A,LH,LT,L:NodeId; N,AN:Node;
BEGIN
    Id:=New(NVariantType,Cur.Line,Cur.Column); Expect(KwCASE); N:=Get(Id);
    IF Cur.Kind=TkIdentifier THEN Assign(N.Text,Cur.Text); Advance ELSE ErrorHere('expected variant tag field name') END;
    Expect(TkColon); N.A:=ParseTypeExpr(); Expect(KwOF); H:=0; T:=0;
    WHILE (Cur.Kind#KwEND) AND (Cur.Kind#TkEOF) DO
        A:=New(NVariantArm,Cur.Line,Cur.Column); AN:=Get(A); LH:=0; LT:=0;
        LOOP L:=ParseExpr(); Append(LH,LT,L); IF NOT Accept(TkComma) THEN EXIT END END;
        Expect(TkColon); AN.A:=LH; AN.B:=ParseFields(TkBar,KwEND,TkEOF); Put(A,AN); Append(H,T,A);
        IF Cur.Kind=TkBar THEN Advance END
    END;
    Expect(KwEND); N.B:=H; Put(Id,N); RETURN Id
END ParseRecordVariant;

PROCEDURE ParseTypeExpr(): NodeId;
VAR Id,Base,Lo,Hi,H,T,I,Arg,Params:NodeId; N,NN:Node; Name:Text;
BEGIN
    IF Cur.Kind=KwDISTINCT THEN
        Id:=New(NNamedType,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParseTypeExpr(); N.Flags:={0}; Put(Id,N); RETURN Id
    END;
    IF Cur.Kind=KwPOINTER THEN
        Id:=New(NPointerType,Cur.Line,Cur.Column); Advance; Expect(KwTO); N:=Get(Id); N.A:=ParseTypeExpr(); Put(Id,N); RETURN Id
    END;
    IF Cur.Kind=KwREF THEN
        Id:=New(NRefType,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParseTypeExpr(); Put(Id,N); RETURN Id
    END;
    IF Cur.Kind=KwSLICE THEN
        Id:=New(NSliceType,Cur.Line,Cur.Column); Advance; Expect(KwOF); N:=Get(Id); N.A:=ParseTypeExpr(); Put(Id,N); RETURN Id
    END;
    IF Cur.Kind=KwSET THEN
        Id:=New(NSetType,Cur.Line,Cur.Column); Advance; Expect(KwOF); N:=Get(Id); N.A:=ParseTypeExpr(); Put(Id,N); RETURN Id
    END;
    IF Cur.Kind=KwARRAY THEN
        Id:=New(NArrayType,Cur.Line,Cur.Column); Advance; N:=Get(Id);
        IF Cur.Kind=KwOF THEN ErrorHere('ARRAY needs an element count; use SLICE OF for a view')
        ELSE N.A:=ParseExpr()
        END;
        Expect(KwOF); N.B:=ParseTypeExpr(); Put(Id,N); RETURN Id
    END;
    IF Cur.Kind=KwATOMIC THEN
        Id:=New(NGenericType,Cur.Line,Cur.Column); Advance; Expect(TkLBracket); N:=Get(Id); Assign(N.Text,'ATOMIC'); N.A:=ParseTypeExpr(); Put(Id,N); Expect(TkRBracket); RETURN Id
    END;
    IF Cur.Kind=KwPROTECTED THEN
        ErrorHereCode(EReservedFeature,'PROTECTED records are reserved until their locking semantics are defined');
        Id:=New(NProtectedType,Cur.Line,Cur.Column); Advance; Expect(KwRECORD); N:=Get(Id); N.B:=ParseFields(KwPRIVATE,KwEND,TkEOF);
        IF Accept(KwPRIVATE) THEN N.C:=ParseFields(KwEND,TkEOF,TkEOF) END;
        Expect(KwEND); Put(Id,N); RETURN Id
    END;
    IF Cur.Kind=KwRECORD THEN
        Id:=New(NRecordType,Cur.Line,Cur.Column); Advance; N:=Get(Id);
        IF Accept(TkLParen) THEN N.A:=ParseTypeExpr(); Expect(TkRParen) END;
        N.B:=ParseFields(KwEND,KwPRIVATE,KwCASE);
        IF Cur.Kind=KwCASE THEN N.D:=ParseRecordVariant() END;
        IF Cur.Kind=KwPRIVATE THEN ErrorHereCode(EReservedFeature,'private record fields are reserved until access control is enforced'); Advance; N.C:=ParseFields(KwEND,TkEOF,TkEOF) END;
        Expect(KwEND); Put(Id,N); RETURN Id
    END;
    IF Cur.Kind=KwCASE THEN ErrorHereCode(EReservedFeature,'variant clauses belong inside RECORD declarations'); Id:=New(NNone,Cur.Line,Cur.Column); Advance; RETURN Id END;
    IF Cur.Kind=KwPROCEDURE THEN
        Id:=New(NProcedureType,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParseFormalParams(); IF Accept(TkColon) THEN N.B:=ParseTypeExpr() END; Put(Id,N); RETURN Id
    END;
    IF Cur.Kind=TkLParen THEN
        Id:=New(NEnumType,Cur.Line,Cur.Column); Advance; H:=0; T:=0;
        IF Cur.Kind#TkRParen THEN
            LOOP I:=NameNode(); Append(H,T,I); IF NOT Accept(TkComma) THEN EXIT END END
        END;
        Expect(TkRParen); N:=Get(Id); N.A:=H; Put(Id,N); RETURN Id
    END;
    IF Cur.Kind=TkIdentifier THEN
        Id:=New(NNamedType,Cur.Line,Cur.Column); N:=Get(Id); QualifiedText(N.Text); Put(Id,N);
        IF Cur.Kind=TkLBracket THEN
            Assign(Name,N.Text); Base:=New(NGenericType,N.Line,N.Column); N:=Get(Base); Assign(N.Text,Name); H:=0; T:=0; Advance;
            LOOP Arg:=ParseTypeExpr(); Append(H,T,Arg); IF NOT Accept(TkComma) THEN EXIT END END;
            Expect(TkRBracket); N.A:=H; Put(Base,N); Id:=Base
        END;
        IF Cur.Kind=KwRANGE THEN
            Advance; Lo:=ParseExpr(); Expect(TkRange); Hi:=ParseExpr(); Base:=Id;
            Id:=New(NRangeType,Cur.Line,Cur.Column); N:=Get(Id); N.A:=Base; N.B:=Lo; N.C:=Hi; Put(Id,N)
        END;
        RETURN Id
    END;
    ErrorHere('expected type'); Id:=New(NNone,Cur.Line,Cur.Column); Advance; RETURN Id
END ParseTypeExpr;

PROCEDURE ParseIfFrom(K:TokenKind): NodeId;
VAR Id,Nested:NodeId; N:Node;
BEGIN
    Id:=New(NIf,Cur.Line,Cur.Column); Expect(K); N:=Get(Id); N.A:=ParseExpr(); Expect(KwTHEN);
    N.B:=ParseBlock(KwELSIF,KwELSE,KwEND);
    IF Cur.Kind=KwELSIF THEN Nested:=ParseIfFrom(KwELSIF); N.C:=Nested; Put(Id,N); RETURN Id
    ELSIF Cur.Kind=KwELSE THEN Advance; N.C:=ParseBlock(KwEND,TkEOF,TkEOF)
    END;
    Expect(KwEND); Put(Id,N); RETURN Id
END ParseIfFrom;

PROCEDURE ParseCase():NodeId;
VAR Id,H,T,A,VH,VT,V:NodeId; N,AN:Node;
BEGIN
    Id:=New(NCase,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParseExpr(); Put(Id,N); Expect(KwOF); H:=0; T:=0;
    WHILE (Cur.Kind#KwELSE) AND (Cur.Kind#KwEND) AND (Cur.Kind#TkEOF) DO
        A:=New(NVariantArm,Cur.Line,Cur.Column); AN:=Get(A); VH:=0; VT:=0;
        LOOP V:=ParseExpr(); Append(VH,VT,V); IF NOT Accept(TkComma) THEN EXIT END END;
        Expect(TkColon); AN.A:=VH; AN.B:=ParseBlock(TkBar,KwELSE,KwEND); Put(A,AN); Append(H,T,A);
        IF Cur.Kind=TkBar THEN Advance END
    END;
    N:=Get(Id); N.B:=H;
    IF Accept(KwELSE) THEN N.C:=ParseBlock(KwEND,TkEOF,TkEOF) END;
    Expect(KwEND); Put(Id,N); RETURN Id
END ParseCase;

PROCEDURE ParseExceptionPart():NodeId;
VAR Id,H,T,A,Body:NodeId; N,AN:Node;
BEGIN
    Id:=New(NExcept,Cur.Line,Cur.Column); Expect(KwEXCEPT); H:=0; T:=0;
    LOOP
        A:=New(NVariantArm,Cur.Line,Cur.Column); AN:=Get(A);
        QualifiedText(AN.Text);
        IF Accept(TkLParen) THEN AN.A:=NameNode(); Expect(TkRParen) END;
        Expect(TkFatArrow); Body:=ParseBlock(TkBar,KwEND,TkEOF); AN.B:=Body; Put(A,AN); Append(H,T,A);
        IF NOT Accept(TkBar) THEN EXIT END
    END;
    N:=Get(Id); N.A:=H; Put(Id,N); RETURN Id
END ParseExceptionPart;

PROCEDURE ParseStatement(): NodeId;
VAR Id,Left,Head,Tail,Item,Body:NodeId; N:Node;
BEGIN
    CASE Cur.Kind OF
    | KwIF: RETURN ParseIfFrom(KwIF)
    | KwCASE: RETURN ParseCase()
    | KwWHILE:
        Id:=New(NWhile,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParseExpr(); Expect(KwDO); N.B:=ParseBlock(KwEND,TkEOF,TkEOF); Expect(KwEND); Put(Id,N); RETURN Id
    | KwREPEAT:
        Id:=New(NRepeat,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParseBlock(KwUNTIL,TkEOF,TkEOF); Expect(KwUNTIL); N.B:=ParseExpr(); Put(Id,N); RETURN Id
    | KwLOOP:
        Id:=New(NLoop,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParseBlock(KwEND,TkEOF,TkEOF); Expect(KwEND); Put(Id,N); RETURN Id
    | KwRETURN:
        Id:=New(NReturn,Cur.Line,Cur.Column); Advance; N:=Get(Id);
        IF (Cur.Kind#TkSemicolon) AND (Cur.Kind#KwEND) AND (Cur.Kind#TkBar) THEN N.A:=ParseExpr() END;
        Put(Id,N); RETURN Id
    | KwEXIT: Id:=New(NExit,Cur.Line,Cur.Column); Advance; RETURN Id
    | KwASSERT: Id:=New(NAssert,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParseExpr(); Put(Id,N); RETURN Id
    | KwRAISE: ErrorHereCode(EReservedFeature,'RAISE is reserved for a later language revision'); Id:=New(NRaise,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParseExpr(); Put(Id,N); RETURN Id
    | KwUNSAFE:
        Id:=New(NUnsafe,Cur.Line,Cur.Column); Advance; Expect(KwBEGIN); N:=Get(Id); N.A:=ParseBlock(KwEND,TkEOF,TkEOF); Expect(KwEND); Put(Id,N); RETURN Id
    | KwWITH:
        ErrorHereCode(EReservedFeature,'WITH is reserved for a later language revision'); Id:=New(NWith,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParseExpr(); Expect(KwDO); N.B:=ParseBlock(KwEND,TkEOF,TkEOF); Expect(KwEND); Put(Id,N); RETURN Id
    | KwBEGIN:
        Advance; Id:=ParseBlock(KwEXCEPT,KwEND,TkEOF); N:=Get(Id);
        IF Cur.Kind=KwEXCEPT THEN ErrorHereCode(EReservedFeature,'EXCEPT is reserved for a later language revision'); N.B:=ParseExceptionPart(); Put(Id,N) END;
        Expect(KwEND); RETURN Id
    | KwDEFER:
        Id:=New(NDefer,Cur.Line,Cur.Column); Advance; N:=Get(Id); N.A:=ParseStatement(); Put(Id,N); RETURN Id
    | KwPARALLEL:
        Id:=New(NParallel,Cur.Line,Cur.Column); Advance; N:=Get(Id);
        IF Cur.Kind=KwFOR THEN
            ErrorHereCode(EReservedFeature,'PARALLEL FOR is reserved for a later language revision'); Advance; Item:=New(NForIn,Cur.Line,Cur.Column); N:=Get(Item);
            IF Cur.Kind=TkIdentifier THEN Assign(N.Text,Cur.Text); Advance ELSE ErrorHere('expected parallel loop variable') END;
            Expect(KwIN); N.A:=ParseExpr(); Expect(KwDO); N.D:=ParseBlock(KwEND,TkEOF,TkEOF); Expect(KwEND); Put(Item,N);
            N:=Get(Id); N.A:=Item; Put(Id,N)
        ELSE
            Expect(KwBEGIN); Head:=0; Tail:=0;
            (* In 1.0 every branch is one zero-argument call.  Parsing a full
               expression here makes the branch delimiter AND indistinguishable
               from boolean AND and turns `First() AND Second()` into one bad
               expression.  Parse the documented branch shape directly. *)
            LOOP
                Body:=New(NBlock,Cur.Line,Cur.Column); Item:=ParsePrimary(); N:=Get(Item);
                IF (N.Kind=NName) OR (N.Kind=NSelect) THEN Left:=Item; Item:=New(NCall,N.Line,N.Column); N:=Get(Item); N.A:=Left; Put(Item,N) END;
                N:=Get(Body); N.A:=Item; Put(Body,N); Append(Head,Tail,Body);
                IF Cur.Kind=TkSemicolon THEN Advance END;
                IF Cur.Kind=KwAND THEN Advance ELSE EXIT END
            END;
            Expect(KwEND); N:=Get(Id); N.A:=Head; Put(Id,N)
        END; RETURN Id
    | KwFOR:
        Id:=New(NFor,Cur.Line,Cur.Column); Advance; N:=Get(Id);
        IF Cur.Kind=TkIdentifier THEN Assign(N.Text,Cur.Text); Advance ELSE ErrorHere('expected loop variable') END;
        IF Accept(KwIN) THEN
            N.Kind:=NForIn; N.A:=ParseExpr(); Expect(KwDO); N.D:=ParseBlock(KwEND,TkEOF,TkEOF); Expect(KwEND)
        ELSE
            Expect(TkAssign); N.A:=ParseExpr(); Expect(KwTO); N.B:=ParseExpr(); IF Accept(KwBY) THEN N.C:=ParseExpr() END;
            Expect(KwDO); N.D:=ParseBlock(KwEND,TkEOF,TkEOF); Expect(KwEND)
        END;
        Put(Id,N); RETURN Id
    ELSE
        Left:=ParseExpr();
        IF Accept(TkAssign) THEN Id:=New(NAssign,Cur.Line,Cur.Column); N:=Get(Id); N.A:=Left; N.B:=ParseExpr(); Put(Id,N); RETURN Id END;
        N:=Get(Left);
        IF (N.Kind=NName) OR (N.Kind=NSelect) THEN Id:=New(NCall,N.Line,N.Column); N:=Get(Id); N.A:=Left; Put(Id,N); RETURN Id END;
        RETURN Left
    END
END ParseStatement;

PROCEDURE ParseVarSection(VAR H,T:NodeId; Kind:NodeKind);
VAR NH,NT,I,V,Ty,Init:NodeId; N,VN:Node;
BEGIN
    Advance;
    WHILE Cur.Kind=TkIdentifier DO
        NH:=0; NT:=0;
        LOOP I:=NameNode(); Append(NH,NT,I); IF NOT Accept(TkComma) THEN EXIT END END;
        Expect(TkColon); Ty:=ParseTypeExpr(); Init:=0; IF Accept(TkAssign) THEN Init:=ParseExpr() END; Expect(TkSemicolon);
        I:=NH;
        WHILE I#0 DO N:=Get(I); V:=New(Kind,N.Line,N.Column); VN:=Get(V); Assign(VN.Text,N.Text); VN.A:=Ty; VN.B:=Init; Put(V,VN); Append(H,T,V); I:=N.Next END
    END
END ParseVarSection;

PROCEDURE ParseTypeSection(VAR H,T:NodeId; IsSubtype:BOOLEAN);
VAR Id,G:NodeId; N:Node;
BEGIN
    Advance;
    WHILE Cur.Kind=TkIdentifier DO
        IF IsSubtype THEN Id:=New(NSubtype,Cur.Line,Cur.Column) ELSE Id:=New(NType,Cur.Line,Cur.Column) END;
        N:=Get(Id); Assign(N.Text,Cur.Text); Advance; G:=ParseGenericParams(); N.D:=G;
        IF ParsingDefinition AND (Cur.Kind=TkSemicolon) THEN N.Flags:=N.Flags+{0}; N.A:=0
        ELSE Expect(TkEqual); N.A:=ParseTypeExpr()
        END;
        Put(Id,N); Append(H,T,Id); Expect(TkSemicolon)
    END
END ParseTypeSection;

PROCEDURE ParseForeign(VAR H,T:NodeId);
VAR Id,E:NodeId; N,EN:Node; Abi:Text; Line,Column:CARDINAL;
BEGIN
    Line:=Cur.Line; Column:=Cur.Column; Advance; Abi[0]:=0C;
    IF Cur.Kind=TkString THEN Assign(Abi,Cur.Text); Advance ELSE ErrorHere('FOREIGN requires ABI string') END;
    IF Cur.Kind=KwLIBRARY THEN
        Id:=New(NForeignLibrary,Line,Column); Advance; N:=Get(Id);
        IF Cur.Kind=TkString THEN Assign(N.Text,Cur.Text); Advance ELSE ErrorHere('LIBRARY requires linker library name') END;
        E:=New(NString,Line,Column); EN:=Get(E); Assign(EN.Text,Abi); Put(E,EN); N.D:=E; Put(Id,N); Append(H,T,Id); Expect(TkSemicolon); RETURN
    END;
    Id:=New(NForeign,Line,Column); N:=Get(Id);
    E:=New(NString,Line,Column); EN:=Get(E); Assign(EN.Text,Abi); Put(E,EN); N.D:=E;
    Expect(KwPROCEDURE);
    IF Cur.Kind=TkIdentifier THEN Assign(N.Text,Cur.Text); Advance ELSE ErrorHere('expected foreign procedure name') END;
    N.A:=ParseFormalParams(); IF Accept(TkColon) THEN N.B:=ParseTypeExpr() END;
    IF Accept(KwVARARGS) THEN N.Flags:={1} END;
    IF Accept(KwEXTERNAL) THEN
        IF Accept(KwNAME) THEN
            IF Cur.Kind=TkString THEN E:=New(NString,Cur.Line,Cur.Column); EN:=Get(E); Assign(EN.Text,Cur.Text); Put(E,EN); N.C:=E; Advance ELSE ErrorHere('expected external symbol string') END
        ELSE ErrorHere('expected NAME after EXTERNAL')
        END
    END;
    Put(Id,N); Append(H,T,Id); Expect(TkSemicolon)
END ParseForeign;

PROCEDURE ParseProcedure(VAR H,T:NodeId; IsTask:BOOLEAN);
VAR Id,Receiver,Params,MetaH,MetaT,M,Body,LH,LT:NodeId; N,MN,RN:Node;
BEGIN
    IF IsTask THEN Id:=New(NTask,Cur.Line,Cur.Column) ELSE Id:=New(NProcedure,Cur.Line,Cur.Column) END;
    Advance; N:=Get(Id); Receiver:=0;
    IF Cur.Kind=TkLParen THEN
        (* A receiver is distinguishable from formal parameters because it appears before the procedure name. *)
        Receiver:=New(NReceiver,Cur.Line,Cur.Column); RN:=Get(Receiver); Advance;
        IF Accept(KwVAR) THEN RN.Flags:={0} END;
        IF Cur.Kind=TkIdentifier THEN Assign(RN.Text,Cur.Text); Advance ELSE ErrorHere('expected receiver name') END;
        Expect(TkColon); RN.A:=ParseTypeExpr(); Expect(TkRParen); Put(Receiver,RN)
    END;
    IF Cur.Kind=TkIdentifier THEN Assign(N.Text,Cur.Text); Advance ELSE ErrorHere('expected procedure name') END;
    N.D:=ParseGenericParams(); Params:=ParseFormalParams(); N.A:=Params;
    IF IsTask AND (Params#0) THEN ErrorHereCode(EReservedFeature,'task parameters are reserved; START launches zero-argument tasks in 1.0') END;
    IF Accept(TkColon) THEN N.B:=ParseTypeExpr() END; Expect(TkSemicolon);
    IF ParsingDefinition THEN Put(Id,N); Append(H,T,Id); RETURN END;

    MetaH:=0; MetaT:=0;
    IF Receiver#0 THEN Append(MetaH,MetaT,Receiver) END;
    WHILE (Cur.Kind=KwPRE) OR (Cur.Kind=KwPOST) DO
        IF Cur.Kind=KwPRE THEN M:=New(NPre,Cur.Line,Cur.Column)
        ELSE ErrorHereCode(EReservedFeature,'POST is reserved for a later language revision'); M:=New(NPost,Cur.Line,Cur.Column) END;
        Advance; MN:=Get(M); MN.A:=ParseExpr(); Put(M,MN); Append(MetaH,MetaT,M); Expect(TkSemicolon)
    END;
    LH:=0; LT:=0;
    WHILE (Cur.Kind=KwCONST) OR (Cur.Kind=KwTYPE) OR (Cur.Kind=KwSUBTYPE) OR (Cur.Kind=KwVAR) OR (Cur.Kind=KwEXCEPTION) DO ParseDecl(LH,LT) END;
    IF LH#0 THEN AppendList(MetaH,MetaT,LH) END;

    IF Cur.Kind=KwABSTRACT THEN
        ErrorHereCode(EReservedFeature,'ABSTRACT procedures are reserved for a later language revision'); Advance; N.C:=0; Expect(TkSemicolon)
    ELSE
        Expect(KwBEGIN); Body:=ParseBlock(KwEXCEPT,KwEND,TkEOF); N.C:=Body;
        IF Cur.Kind=KwEXCEPT THEN ErrorHereCode(EReservedFeature,'EXCEPT is reserved for a later language revision'); MN:=Get(Body); MN.B:=ParseExceptionPart(); Put(Body,MN) END;
        Expect(KwEND);
        IF Cur.Kind=TkIdentifier THEN
            IF NOT HStrings.Equal(Cur.Text,N.Text) THEN ErrorHereCode(EProcedureEndMismatch,'procedure end name does not match its declaration') END;
            Advance
        END;
        Expect(TkSemicolon)
    END;
    (* N.D starts with generic parameters. Meta follows in generic tail when present. *)
    IF N.D=0 THEN N.D:=MetaH ELSE M:=N.D; LOOP MN:=Get(M); IF MN.Next=0 THEN EXIT END; M:=MN.Next END; MN:=Get(M); MN.Next:=MetaH; Put(M,MN) END;
    Put(Id,N); Append(H,T,Id)
END ParseProcedure;

PROCEDURE ParseDecl(VAR H,T:NodeId);
VAR Id:NodeId; N:Node;
BEGIN
    CASE Cur.Kind OF
    | KwCONST:
        Advance;
        WHILE Cur.Kind=TkIdentifier DO Id:=New(NConst,Cur.Line,Cur.Column); N:=Get(Id); Assign(N.Text,Cur.Text); Advance; Expect(TkEqual); N.A:=ParseExpr(); Put(Id,N); Append(H,T,Id); Expect(TkSemicolon) END
    | KwTYPE: ParseTypeSection(H,T,FALSE)
    | KwSUBTYPE: ParseTypeSection(H,T,TRUE)
    | KwVAR: ParseVarSection(H,T,NVar)
    | KwEXCEPTION:
        ErrorHereCode(EReservedFeature,'language exceptions are reserved for a later language revision');
        Advance; WHILE Cur.Kind=TkIdentifier DO Id:=New(NException,Cur.Line,Cur.Column); N:=Get(Id); Assign(N.Text,Cur.Text); Put(Id,N); Append(H,T,Id); Advance; Expect(TkSemicolon) END
    | KwFOREIGN: ParseForeign(H,T)
    | KwPROCEDURE: ParseProcedure(H,T,FALSE)
    | KwTASK: ParseProcedure(H,T,TRUE)
    ELSE ErrorHere('expected declaration'); Advance
    END
END ParseDecl;

PROCEDURE ParseImportList(VAR H,T:NodeId);
VAR D,Alias:NodeId; N,AN:Node; First:Text; Line,Column:CARDINAL;
BEGIN
    Expect(KwIMPORT);
    LOOP
        Line:=Cur.Line; Column:=Cur.Column; First[0]:=0C;
        IF Cur.Kind=TkIdentifier THEN Assign(First,Cur.Text); Advance ELSE ErrorHereCode(EExpectedIdentifier,'expected module name') END;
        D:=New(NImport,Line,Column); N:=Get(D);
        IF Accept(TkAssign) THEN
            Alias:=New(NName,Line,Column); AN:=Get(Alias); Assign(AN.Text,First); Put(Alias,AN); N.A:=Alias;
            QualifiedText(N.Text)
        ELSE
            Assign(N.Text,First);
            WHILE Cur.Kind=TkDot DO
                Advance;
                IF Cur.Kind#TkIdentifier THEN ErrorHereCode(EExpectedIdentifier,'expected identifier after dot')
                ELSE HStrings.Append(N.Text,'.'); HStrings.Append(N.Text,Cur.Text); Advance
                END
            END
        END;
        Put(D,N); Append(H,T,D);
        IF NOT Accept(TkComma) THEN EXIT END
    END;
    Expect(TkSemicolon)
END ParseImportList;

PROCEDURE ParseFromImport(VAR H,T:NodeId);
VAR D,MH,MT,I:NodeId; N:Node; ModuleName:Text; Line,Column:CARDINAL;
BEGIN
    Line:=Cur.Line; Column:=Cur.Column; Expect(KwFROM); QualifiedText(ModuleName); Expect(KwIMPORT);
    MH:=0; MT:=0;
    LOOP
        I:=NameNode(); Append(MH,MT,I);
        IF NOT Accept(TkComma) THEN EXIT END
    END;
    D:=New(NImport,Line,Column); N:=Get(D); Assign(N.Text,ModuleName); N.B:=MH; Put(D,N); Append(H,T,D);
    Expect(TkSemicolon)
END ParseFromImport;

PROCEDURE ParseDivision(VAR H,T:NodeId);
VAR Id,D,DH,DT,EH,ET:NodeId; N,DN:Node;
BEGIN
    Id:=New(NDivision,Cur.Line,Cur.Column); Advance; N:=Get(Id);
    IF Cur.Kind=TkIdentifier THEN Assign(N.Text,Cur.Text); Advance
    ELSE ErrorHereCode(EExpectedIdentifier,'expected division name')
    END;
    IF Accept(KwWHEN) THEN N.A:=ParseExpr() END;
    Expect(TkSemicolon); DH:=0; DT:=0; EH:=0; ET:=0;
    WHILE (Cur.Kind=KwIMPORT) OR (Cur.Kind=KwFROM) OR (Cur.Kind=KwEXPORT) DO
        IF Cur.Kind=KwIMPORT THEN ParseImportList(DH,DT)
        ELSIF Cur.Kind=KwFROM THEN ParseFromImport(DH,DT)
        ELSE
            Advance;
            LOOP
                D:=New(NExport,Cur.Line,Cur.Column); DN:=Get(D);
                IF Cur.Kind=TkIdentifier THEN Assign(DN.Text,Cur.Text); Advance
                ELSE ErrorHereCode(EExpectedIdentifier,'expected division export name')
                END;
                Put(D,DN); Append(EH,ET,D); IF NOT Accept(TkComma) THEN EXIT END
            END;
            Expect(TkSemicolon)
        END
    END;
    WHILE (Cur.Kind=KwCONST) OR (Cur.Kind=KwTYPE) OR (Cur.Kind=KwSUBTYPE) OR (Cur.Kind=KwVAR) OR
          (Cur.Kind=KwPROCEDURE) OR (Cur.Kind=KwTASK) OR (Cur.Kind=KwFOREIGN) OR (Cur.Kind=KwEXCEPTION) DO
        ParseDecl(DH,DT)
    END;
    IF Cur.Kind=KwBEGIN THEN
        ErrorHereCode(EReservedFeature,'DIVISION contains declarations only; module initialization remains singular')
    END;
    Expect(KwEND);
    IF Cur.Kind=TkIdentifier THEN
        IF NOT HStrings.Equal(Cur.Text,N.Text) THEN ErrorHereCode(EDivisionEndMismatch,'division end name does not match its declaration') END;
        Advance
    ELSE ErrorHereCode(EExpectedIdentifier,'expected division name after END')
    END;
    Expect(TkSemicolon); N.B:=DH; N.C:=EH; Put(Id,N); Append(H,T,Id)
END ParseDivision;

PROCEDURE Parse(VAR Root: NodeId): BOOLEAN;
VAR R,N:Node; DH,DT,D:NodeId; IsDef:BOOLEAN;
BEGIN
    Init(); Advance; IsDef:=FALSE; ParsingDefinition:=FALSE;
    IF Cur.Kind=KwDEFINITION THEN
        IsDef:=TRUE; ParsingDefinition:=TRUE; Advance
    END;
    Expect(KwMODULE); Root:=New(NModule,Cur.Line,Cur.Column); R:=Get(Root);
    IF Cur.Kind=TkIdentifier THEN Assign(R.Text,Cur.Text); Advance ELSE ErrorHere('expected module name') END;
    IF IsDef THEN R.Flags:=R.Flags+{0} END;
    Expect(TkSemicolon); DH:=0; DT:=0;

    WHILE (Cur.Kind=KwIMPORT) OR (Cur.Kind=KwFROM) OR (Cur.Kind=KwEXPORT) DO
        IF Cur.Kind=KwIMPORT THEN ParseImportList(DH,DT)
        ELSIF Cur.Kind=KwFROM THEN ParseFromImport(DH,DT)
        ELSE
            Advance;
            LOOP
                D:=New(NExport,Cur.Line,Cur.Column); N:=Get(D); QualifiedText(N.Text); Put(D,N); Append(DH,DT,D);
                IF NOT Accept(TkComma) THEN EXIT END
            END;
            Expect(TkSemicolon)
        END
    END;

    WHILE (Cur.Kind=KwCONST) OR (Cur.Kind=KwTYPE) OR (Cur.Kind=KwSUBTYPE) OR (Cur.Kind=KwVAR) OR
          (Cur.Kind=KwPROCEDURE) OR (Cur.Kind=KwTASK) OR (Cur.Kind=KwFOREIGN) OR (Cur.Kind=KwEXCEPTION) OR
          (Cur.Kind=KwDIVISION) DO
        IF Cur.Kind=KwDIVISION THEN
            IF IsDef THEN ErrorHereCode(EReservedFeature,'DIVISION is an implementation partition and is not valid in a definition module') END;
            ParseDivision(DH,DT)
        ELSE ParseDecl(DH,DT)
        END
    END;
    R.A:=DH;
    IF NOT IsDef AND Accept(KwBEGIN) THEN
        R.B:=ParseBlock(KwEXCEPT,KwEND,TkEOF);
        IF Cur.Kind=KwEXCEPT THEN ErrorHereCode(EReservedFeature,'EXCEPT is reserved for a later language revision'); N:=Get(R.B); N.B:=ParseExceptionPart(); Put(R.B,N) END
    END;
    Expect(KwEND);
    IF Cur.Kind=TkIdentifier THEN
        IF NOT HStrings.Equal(Cur.Text,R.Text) THEN ErrorHereCode(EModuleEndMismatch,'module end name does not match its declaration') END;
        Advance
    ELSE ErrorHereCode(EExpectedIdentifier,'expected module name after END')
    END;
    Expect(TkDot); Put(Root,R);
    RETURN NOT HasErrors()
END Parse;

END Parser.
