IMPLEMENTATION MODULE Lexer;

FROM Source IMPORT CharAt, FileName;
FROM Tokens IMPORT Token, TokenKind;
FROM HStrings IMPORT Text, Clear, AppendChar, Equal, Length;
FROM Diagnostics IMPORT Coded, Severity;
FROM ErrorCodes IMPORT EUnterminatedComment,EUnterminatedLiteral,EInvalidCharacter,EInvalidNumber,ETokenTooLong;

VAR Pos, Line, Col: CARDINAL;
    Cached: Token;
    HasCached,TokenTextOverflow: BOOLEAN;

PROCEDURE IsAlpha(C: CHAR): BOOLEAN;
BEGIN RETURN ((C >= 'A') AND (C <= 'Z')) OR ((C >= 'a') AND (C <= 'z')) OR (C = '_') END IsAlpha;
PROCEDURE IsDigit(C: CHAR): BOOLEAN; BEGIN RETURN (C >= '0') AND (C <= '9') END IsDigit;
PROCEDURE IsHex(C: CHAR): BOOLEAN;
BEGIN RETURN IsDigit(C) OR ((C>='a') AND (C<='f')) OR ((C>='A') AND (C<='F')) END IsHex;
PROCEDURE HexValue(C:CHAR):CARDINAL;
BEGIN
    IF IsDigit(C) THEN RETURN ORD(C)-ORD('0') END;
    IF (C>='a') AND (C<='f') THEN RETURN 10+ORD(C)-ORD('a') END;
    RETURN 10+ORD(C)-ORD('A')
END HexValue;

PROCEDURE TokenAppend(VAR Out:Text; C:CHAR; StartLine,StartColumn:CARDINAL);
VAR F:Text;
BEGIN
    IF Length(Out)<HIGH(Out) THEN AppendChar(Out,C)
    ELSIF NOT TokenTextOverflow THEN
        FileName(F); Coded(Error,ETokenTooLong,F,StartLine,StartColumn,'token text exceeds 1023 bytes'); TokenTextOverflow:=TRUE
    END
END TokenAppend;

PROCEDURE AppendUTF8(VAR Out:Text; Value,StartLine,StartColumn:CARDINAL);
BEGIN
    IF Value<=127 THEN TokenAppend(Out,VAL(CHAR,Value),StartLine,StartColumn)
    ELSIF Value<=2047 THEN
        TokenAppend(Out,VAL(CHAR,192+Value DIV 64),StartLine,StartColumn); TokenAppend(Out,VAL(CHAR,128+Value MOD 64),StartLine,StartColumn)
    ELSIF (Value<55296) OR ((Value>57343) AND (Value<=65535)) THEN
        TokenAppend(Out,VAL(CHAR,224+Value DIV 4096),StartLine,StartColumn);
        TokenAppend(Out,VAL(CHAR,128+(Value DIV 64) MOD 64),StartLine,StartColumn); TokenAppend(Out,VAL(CHAR,128+Value MOD 64),StartLine,StartColumn)
    ELSIF Value<=1114111 THEN
        TokenAppend(Out,VAL(CHAR,240+Value DIV 262144),StartLine,StartColumn);
        TokenAppend(Out,VAL(CHAR,128+(Value DIV 4096) MOD 64),StartLine,StartColumn);
        TokenAppend(Out,VAL(CHAR,128+(Value DIV 64) MOD 64),StartLine,StartColumn); TokenAppend(Out,VAL(CHAR,128+Value MOD 64),StartLine,StartColumn)
    END
END AppendUTF8;
PROCEDURE SingleUTF8(S:ARRAY OF CHAR; VAR Value:CARDINAL):BOOLEAN;
VAR N,A,B,C,D:CARDINAL;
BEGIN
    N:=Length(S); IF N=0 THEN RETURN FALSE END; A:=ORD(S[0]);
    IF A<128 THEN IF N#1 THEN RETURN FALSE END; Value:=A; RETURN TRUE END;
    IF N<2 THEN RETURN FALSE END; B:=ORD(S[1]); IF (B<128) OR (B>191) THEN RETURN FALSE END;
    IF (A>=194) AND (A<=223) THEN IF N#2 THEN RETURN FALSE END; Value:=(A-192)*64+(B-128); RETURN TRUE END;
    IF N<3 THEN RETURN FALSE END; C:=ORD(S[2]); IF (C<128) OR (C>191) THEN RETURN FALSE END;
    IF (A>=224) AND (A<=239) THEN
        IF N#3 THEN RETURN FALSE END; Value:=(A-224)*4096+(B-128)*64+(C-128);
        RETURN (Value>=2048) AND ((Value<55296) OR (Value>57343))
    END;
    IF N<4 THEN RETURN FALSE END; D:=ORD(S[3]); IF (D<128) OR (D>191) OR (N#4) OR (A<240) OR (A>244) THEN RETURN FALSE END;
    Value:=(A-240)*262144+(B-128)*4096+(C-128)*64+(D-128); RETURN (Value>=65536) AND (Value<=1114111)
END SingleUTF8;
PROCEDURE Advance;
BEGIN
    IF CharAt(Pos) = 12C THEN INC(Line); Col := 1 ELSE INC(Col) END;
    INC(Pos)
END Advance;

PROCEDURE Keyword(S: ARRAY OF CHAR): TokenKind;
BEGIN
    IF Equal(S,'MODULE') THEN RETURN KwMODULE
    ELSIF Equal(S,'DEFINITION') THEN RETURN KwDEFINITION
    ELSIF Equal(S,'IMPORT') THEN RETURN KwIMPORT
    ELSIF Equal(S,'FROM') THEN RETURN KwFROM
    ELSIF Equal(S,'EXPORT') THEN RETURN KwEXPORT
    ELSIF Equal(S,'CONST') THEN RETURN KwCONST
    ELSIF Equal(S,'TYPE') THEN RETURN KwTYPE
    ELSIF Equal(S,'SUBTYPE') THEN RETURN KwSUBTYPE
    ELSIF Equal(S,'VAR') THEN RETURN KwVAR
    ELSIF Equal(S,'PROCEDURE') THEN RETURN KwPROCEDURE
    ELSIF Equal(S,'BEGIN') THEN RETURN KwBEGIN
    ELSIF Equal(S,'END') THEN RETURN KwEND
    ELSIF Equal(S,'RETURN') THEN RETURN KwRETURN
    ELSIF Equal(S,'IF') THEN RETURN KwIF
    ELSIF Equal(S,'THEN') THEN RETURN KwTHEN
    ELSIF Equal(S,'ELSIF') THEN RETURN KwELSIF
    ELSIF Equal(S,'ELSE') THEN RETURN KwELSE
    ELSIF Equal(S,'CASE') THEN RETURN KwCASE
    ELSIF Equal(S,'OF') THEN RETURN KwOF
    ELSIF Equal(S,'WHILE') THEN RETURN KwWHILE
    ELSIF Equal(S,'DO') THEN RETURN KwDO
    ELSIF Equal(S,'FOR') THEN RETURN KwFOR
    ELSIF Equal(S,'TO') THEN RETURN KwTO
    ELSIF Equal(S,'BY') THEN RETURN KwBY
    ELSIF Equal(S,'IN') THEN RETURN KwIN
    ELSIF Equal(S,'LOOP') THEN RETURN KwLOOP
    ELSIF Equal(S,'EXIT') THEN RETURN KwEXIT
    ELSIF Equal(S,'RECORD') THEN RETURN KwRECORD
    ELSIF Equal(S,'ARRAY') THEN RETURN KwARRAY
    ELSIF Equal(S,'SLICE') THEN RETURN KwSLICE
    ELSIF Equal(S,'SET') THEN RETURN KwSET
    ELSIF Equal(S,'POINTER') THEN RETURN KwPOINTER
    ELSIF Equal(S,'REF') THEN RETURN KwREF
    ELSIF Equal(S,'DISTINCT') THEN RETURN KwDISTINCT
    ELSIF Equal(S,'RANGE') THEN RETURN KwRANGE
    ELSIF Equal(S,'TRUE') THEN RETURN KwTRUE
    ELSIF Equal(S,'FALSE') THEN RETURN KwFALSE
    ELSIF Equal(S,'NIL') THEN RETURN KwNIL
    ELSIF Equal(S,'AND') THEN RETURN KwAND
    ELSIF Equal(S,'OR') THEN RETURN KwOR
    ELSIF Equal(S,'XOR') THEN RETURN KwXOR
    ELSIF Equal(S,'NOT') THEN RETURN KwNOT
    ELSIF Equal(S,'DIV') THEN RETURN KwDIV
    ELSIF Equal(S,'MOD') THEN RETURN KwMOD
    ELSIF Equal(S,'SHL') THEN RETURN KwSHL
    ELSIF Equal(S,'SHR') THEN RETURN KwSHR
    ELSIF Equal(S,'PRE') THEN RETURN KwPRE
    ELSIF Equal(S,'POST') THEN RETURN KwPOST
    ELSIF Equal(S,'ASSERT') THEN RETURN KwASSERT
    ELSIF Equal(S,'INVARIANT') THEN RETURN KwINVARIANT
    ELSIF Equal(S,'TASK') THEN RETURN KwTASK
    ELSIF Equal(S,'START') THEN RETURN KwSTART
    ELSIF Equal(S,'AWAIT') THEN RETURN KwAWAIT
    ELSIF Equal(S,'PARALLEL') THEN RETURN KwPARALLEL
    ELSIF Equal(S,'PROTECTED') THEN RETURN KwPROTECTED
    ELSIF Equal(S,'ATOMIC') THEN RETURN KwATOMIC
    ELSIF Equal(S,'UNSAFE') THEN RETURN KwUNSAFE
    ELSIF Equal(S,'FOREIGN') THEN RETURN KwFOREIGN
    ELSIF Equal(S,'EXTERNAL') THEN RETURN KwEXTERNAL
    ELSIF Equal(S,'NAME') THEN RETURN KwNAME
    ELSIF Equal(S,'LIBRARY') THEN RETURN KwLIBRARY
    ELSIF Equal(S,'VARARGS') THEN RETURN KwVARARGS
    ELSIF Equal(S,'EXCEPTION') THEN RETURN KwEXCEPTION
    ELSIF Equal(S,'RAISE') THEN RETURN KwRAISE
    ELSIF Equal(S,'EXCEPT') THEN RETURN KwEXCEPT
    ELSIF Equal(S,'GENERIC') THEN RETURN KwGENERIC
    ELSIF Equal(S,'WHERE') THEN RETURN KwWHERE
    ELSIF Equal(S,'IS') THEN RETURN KwIS
    ELSIF Equal(S,'ABSTRACT') THEN RETURN KwABSTRACT
    ELSIF Equal(S,'PRIVATE') THEN RETURN KwPRIVATE
    ELSIF Equal(S,'NEW') THEN RETURN KwNEW
    ELSIF Equal(S,'WITH') THEN RETURN KwWITH
    ELSIF Equal(S,'DEFER') THEN RETURN KwDEFER
    ELSIF Equal(S,'REPEAT') THEN RETURN KwREPEAT
    ELSIF Equal(S,'UNTIL') THEN RETURN KwUNTIL
    ELSIF Equal(S,'SIZEOF') THEN RETURN KwSIZEOF
    ELSIF Equal(S,'ALIGNOF') THEN RETURN KwALIGNOF
    ELSIF Equal(S,'ADR') THEN RETURN KwADR
    ELSIF Equal(S,'DIVISION') THEN RETURN KwDIVISION
    ELSIF Equal(S,'WHEN') THEN RETURN KwWHEN
    ELSE RETURN TkIdentifier
    END
END Keyword;

PROCEDURE SkipTrivia;
VAR Depth: INTEGER; F: Text;
BEGIN
    LOOP
        WHILE (CharAt(Pos) = ' ') OR (CharAt(Pos) = 11C) OR (CharAt(Pos) = 15C) OR (CharAt(Pos) = 12C) DO Advance END;
        IF (CharAt(Pos) = '(') AND (CharAt(Pos+1) = '*') THEN
            Advance; Advance; Depth := 1;
            WHILE (Depth > 0) AND (CharAt(Pos) # 0C) DO
                IF (CharAt(Pos) = '(') AND (CharAt(Pos+1) = '*') THEN Advance; Advance; INC(Depth)
                ELSIF (CharAt(Pos) = '*') AND (CharAt(Pos+1) = ')') THEN Advance; Advance; DEC(Depth)
                ELSE Advance
                END
            END;
            IF Depth # 0 THEN FileName(F); Coded(Error,EUnterminatedComment,F,Line,Col,'unterminated comment') END
        ELSIF (CharAt(Pos) = '/') AND (CharAt(Pos+1) = '/') THEN
            WHILE (CharAt(Pos) # 0C) AND (CharAt(Pos) # 12C) DO Advance END
        ELSE EXIT
        END
    END
END SkipTrivia;

PROCEDURE Scan(VAR T: Token);
VAR C, Quote: CHAR; F: Text; Code:CARDINAL;
BEGIN
    SkipTrivia; Clear(T.Text); TokenTextOverflow:=FALSE; T.Line := Line; T.Column := Col; T.Offset := Pos; T.IntValue:=0; C := CharAt(Pos);
    IF C = 0C THEN T.Kind := TkEOF; RETURN END;
    IF IsAlpha(C) THEN
        WHILE IsAlpha(CharAt(Pos)) OR IsDigit(CharAt(Pos)) DO TokenAppend(T.Text,CharAt(Pos),T.Line,T.Column); Advance END;
        T.Kind := Keyword(T.Text); RETURN
    END;
    IF IsDigit(C) THEN
        IF (C='0') AND ((CharAt(Pos+1)='x') OR (CharAt(Pos+1)='X')) THEN
            TokenAppend(T.Text,'0',T.Line,T.Column); TokenAppend(T.Text,'x',T.Line,T.Column); Advance; Advance;
            WHILE IsHex(CharAt(Pos)) OR (CharAt(Pos)='_') DO IF CharAt(Pos)#'_' THEN TokenAppend(T.Text,CharAt(Pos),T.Line,T.Column) END; Advance END;
            T.Kind:=TkInteger; RETURN
        ELSIF (C='0') AND ((CharAt(Pos+1)='b') OR (CharAt(Pos+1)='B')) THEN
            TokenAppend(T.Text,'0',T.Line,T.Column); TokenAppend(T.Text,'b',T.Line,T.Column); Advance; Advance;
            WHILE (CharAt(Pos)='0') OR (CharAt(Pos)='1') OR (CharAt(Pos)='_') DO IF CharAt(Pos)#'_' THEN TokenAppend(T.Text,CharAt(Pos),T.Line,T.Column) END; Advance END;
            T.Kind:=TkInteger; RETURN
        ELSIF (C='0') AND ((CharAt(Pos+1)='o') OR (CharAt(Pos+1)='O')) THEN
            TokenAppend(T.Text,'0',T.Line,T.Column); TokenAppend(T.Text,'o',T.Line,T.Column); Advance; Advance;
            WHILE ((CharAt(Pos)>='0') AND (CharAt(Pos)<='7')) OR (CharAt(Pos)='_') DO IF CharAt(Pos)#'_' THEN TokenAppend(T.Text,CharAt(Pos),T.Line,T.Column) END; Advance END;
            T.Kind:=TkInteger; RETURN
        END;
        WHILE IsDigit(CharAt(Pos)) OR (CharAt(Pos)='_') DO IF CharAt(Pos)#'_' THEN TokenAppend(T.Text,CharAt(Pos),T.Line,T.Column) END; Advance END;
        IF (CharAt(Pos)='.') AND (CharAt(Pos+1)#'.') THEN
            TokenAppend(T.Text,'.',T.Line,T.Column); Advance;
            WHILE IsDigit(CharAt(Pos)) OR (CharAt(Pos)='_') DO IF CharAt(Pos)#'_' THEN TokenAppend(T.Text,CharAt(Pos),T.Line,T.Column) END; Advance END;
            IF (CharAt(Pos)='e') OR (CharAt(Pos)='E') THEN
                TokenAppend(T.Text,CharAt(Pos),T.Line,T.Column); Advance;
                IF (CharAt(Pos)='+') OR (CharAt(Pos)='-') THEN TokenAppend(T.Text,CharAt(Pos),T.Line,T.Column); Advance END;
                IF NOT IsDigit(CharAt(Pos)) THEN
                    FileName(F); Coded(Error,EInvalidNumber,F,T.Line,T.Column,'real exponent needs at least one digit')
                ELSE
                    WHILE IsDigit(CharAt(Pos)) OR (CharAt(Pos)='_') DO
                        IF CharAt(Pos)#'_' THEN TokenAppend(T.Text,CharAt(Pos),T.Line,T.Column) END;
                        Advance
                    END
                END
            END;
            T.Kind := TkReal
        ELSE T.Kind := TkInteger
        END;
        RETURN
    END;
    IF (C='"') OR (C=47C) THEN
        Quote := C; Advance;
        WHILE (CharAt(Pos)#0C) AND (CharAt(Pos)#Quote) AND
              (CharAt(Pos)#12C) AND (CharAt(Pos)#15C) DO
            C := CharAt(Pos);
            IF C=134C THEN
                Advance; C := CharAt(Pos);
                CASE C OF
                | 'n': TokenAppend(T.Text,12C,T.Line,T.Column)
                | 'r': TokenAppend(T.Text,15C,T.Line,T.Column)
                | 't': TokenAppend(T.Text,11C,T.Line,T.Column)
                | 'e': TokenAppend(T.Text,33C,T.Line,T.Column)
                | 134C: TokenAppend(T.Text,134C,T.Line,T.Column)
                | '"': TokenAppend(T.Text,'"',T.Line,T.Column)
                | 47C: TokenAppend(T.Text,47C,T.Line,T.Column)
                | 'u':
                    IF IsHex(CharAt(Pos+1)) AND IsHex(CharAt(Pos+2)) AND IsHex(CharAt(Pos+3)) AND IsHex(CharAt(Pos+4)) THEN
                        Code:=HexValue(CharAt(Pos+1))*4096+HexValue(CharAt(Pos+2))*256+HexValue(CharAt(Pos+3))*16+HexValue(CharAt(Pos+4));
                        IF (Code>=55296) AND (Code<=57343) THEN FileName(F); Coded(Error,EInvalidCharacter,F,Line,Col,'unicode escape is a surrogate code point')
                        ELSE AppendUTF8(T.Text,Code,T.Line,T.Column)
                        END;
                        Advance; Advance; Advance; Advance
                    ELSE FileName(F); Coded(Error,EInvalidCharacter,F,Line,Col,'unicode escape needs four hexadecimal digits')
                    END
                ELSE
                    FileName(F); Coded(Error,EInvalidCharacter,F,Line,Col,'unknown escape sequence');
                    TokenAppend(T.Text,C,T.Line,T.Column)
                END;
                Advance
            ELSE TokenAppend(T.Text,C,T.Line,T.Column); Advance
            END
        END;
        IF CharAt(Pos)=Quote THEN Advance ELSE FileName(F); Coded(Error,EUnterminatedLiteral,F,T.Line,T.Column,'unterminated literal') END;
        IF Quote='"' THEN T.Kind := TkString
        ELSE
            T.Kind := TkChar;
            IF NOT SingleUTF8(T.Text,Code) THEN
                FileName(F); Coded(Error,EInvalidCharacter,F,T.Line,T.Column,'character literal must contain exactly one character')
            ELSE T.IntValue:=VAL(LONGINT,Code) END
        END;
        RETURN
    END;
    Advance;
    CASE C OF
    | '+': T.Kind:=TkPlus
    | '-': IF CharAt(Pos)='>' THEN Advance; T.Kind:=TkArrow ELSE T.Kind:=TkMinus END
    | '*': T.Kind:=TkStar
    | '/': T.Kind:=TkSlash
    | '=': IF CharAt(Pos)='>' THEN Advance; T.Kind:=TkFatArrow ELSE T.Kind:=TkEqual END
    | '#': T.Kind:=TkNotEqual
    | '<': IF CharAt(Pos)='=' THEN Advance; T.Kind:=TkLessEqual ELSE T.Kind:=TkLess END
    | '>': IF CharAt(Pos)='=' THEN Advance; T.Kind:=TkGreaterEqual ELSE T.Kind:=TkGreater END
    | ':': IF CharAt(Pos)='=' THEN Advance; T.Kind:=TkAssign ELSE T.Kind:=TkColon END
    | ';': T.Kind:=TkSemicolon
    | ',': T.Kind:=TkComma
    | '.': IF CharAt(Pos)='.' THEN Advance; T.Kind:=TkRange ELSE T.Kind:=TkDot END
    | '(': T.Kind:=TkLParen
    | ')': T.Kind:=TkRParen
    | '[': T.Kind:=TkLBracket
    | ']': T.Kind:=TkRBracket
    | '{': T.Kind:=TkLBrace
    | '}': T.Kind:=TkRBrace
    | '|': T.Kind:=TkBar
    | '^': T.Kind:=TkCaret
    | 47C: T.Kind:=TkApostrophe
    ELSE FileName(F); Coded(Error,EInvalidCharacter,F,T.Line,T.Column,'invalid character'); T.Kind:=TkEOF
    END
END Scan;

PROCEDURE Init;
BEGIN Pos:=0; Line:=1; Col:=1; HasCached:=FALSE END Init;
PROCEDURE Next(VAR T: Token);
BEGIN IF HasCached THEN T:=Cached; HasCached:=FALSE ELSE Scan(T) END END Next;
PROCEDURE Peek(VAR T: Token);
BEGIN IF NOT HasCached THEN Scan(Cached); HasCached:=TRUE END; T:=Cached END Peek;

END Lexer.
