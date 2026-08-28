IMPLEMENTATION MODULE HStrings;

FROM IO IMPORT Write;

PROCEDURE Clear(VAR S: Text);
BEGIN
    S[0] := 0C
END Clear;

PROCEDURE Length(S: ARRAY OF CHAR): CARDINAL;
VAR I: CARDINAL;
BEGIN
    I := 0;
    WHILE (I <= HIGH(S)) AND (S[I] # 0C) DO
        INC(I)
    END;
    RETURN I
END Length;

PROCEDURE Assign(VAR Dst: Text; Src: ARRAY OF CHAR);
VAR I, N: CARDINAL;
BEGIN
    N := Length(Src);
    IF N > MaxText THEN N := MaxText END;
    I := 0;
    WHILE I < N DO Dst[I] := Src[I]; INC(I) END;
    Dst[I] := 0C
END Assign;

PROCEDURE Append(VAR Dst: Text; Src: ARRAY OF CHAR);
VAR I, J: CARDINAL;
BEGIN
    I := Length(Dst); J := 0;
    WHILE (I < MaxText) AND (J <= HIGH(Src)) AND (Src[J] # 0C) DO
        Dst[I] := Src[J]; INC(I); INC(J)
    END;
    Dst[I] := 0C
END Append;

PROCEDURE AppendChar(VAR Dst: Text; Ch: CHAR);
VAR I: CARDINAL;
BEGIN
    I := Length(Dst);
    IF I < MaxText THEN Dst[I] := Ch; Dst[I+1] := 0C END
END AppendChar;

PROCEDURE Equal(A, B: ARRAY OF CHAR): BOOLEAN;
VAR I: CARDINAL;
BEGIN
    I := 0;
    LOOP
        IF (I > HIGH(A)) OR (I > HIGH(B)) THEN RETURN FALSE END;
        IF A[I] # B[I] THEN RETURN FALSE END;
        IF A[I] = 0C THEN RETURN TRUE END;
        INC(I)
    END
END Equal;

PROCEDURE BaseName(Path: ARRAY OF CHAR; VAR Out: Text);
VAR I, Start, N: CARDINAL;
BEGIN
    N := Length(Path); Start := 0; I := 0;
    WHILE I < N DO
        IF Path[I] = '/' THEN Start := I + 1 END;
        INC(I)
    END;
    Clear(Out); I := Start;
    WHILE (I < N) AND (Path[I] # '.') DO AppendChar(Out, Path[I]); INC(I) END
END BaseName;

PROCEDURE ReplaceExtension(Path, Ext: ARRAY OF CHAR; VAR Out: Text);
VAR I, N, Dot: CARDINAL;
BEGIN
    N := Length(Path); Dot := N; I := 0;
    WHILE I < N DO
        IF Path[I] = '/' THEN Dot := N
        ELSIF Path[I] = '.' THEN Dot := I
        END;
        INC(I)
    END;
    Clear(Out); I := 0;
    WHILE I < Dot DO AppendChar(Out, Path[I]); INC(I) END;
    Append(Out, Ext)
END ReplaceExtension;

PROCEDURE ToUpper(VAR S: Text);
VAR I: CARDINAL;
BEGIN
    I := 0;
    WHILE (I <= HIGH(S)) AND (S[I] # 0C) DO
        IF (S[I] >= 'a') AND (S[I] <= 'z') THEN S[I] := CAP(S[I]) END;
        INC(I)
    END
END ToUpper;

PROCEDURE StartsWith(S, Prefix: ARRAY OF CHAR): BOOLEAN;
VAR I:CARDINAL;
BEGIN
    I:=0;
    WHILE (I<=HIGH(Prefix)) AND (Prefix[I]#0C) DO
        IF (I>HIGH(S)) OR (S[I]#Prefix[I]) THEN RETURN FALSE END; INC(I)
    END;
    RETURN TRUE
END StartsWith;

PROCEDURE EndsWith(S,Suffix:ARRAY OF CHAR):BOOLEAN;
VAR N,M,I:CARDINAL;
BEGIN
    N:=Length(S); M:=Length(Suffix); IF M>N THEN RETURN FALSE END; I:=0;
    WHILE I<M DO IF S[N-M+I]#Suffix[I] THEN RETURN FALSE END; INC(I) END; RETURN TRUE
END EndsWith;

PROCEDURE ParseCard(S:ARRAY OF CHAR; VAR Value:CARDINAL):BOOLEAN;
VAR I,D:CARDINAL; V,MaxValue:CARDINAL;
BEGIN
    I:=0; V:=0; MaxValue:=MAX(CARDINAL); IF (I>HIGH(S)) OR (S[I]=0C) THEN RETURN FALSE END;
    WHILE (I<=HIGH(S)) AND (S[I]#0C) DO
        IF (S[I]<'0') OR (S[I]>'9') THEN RETURN FALSE END;
        D:=VAL(CARDINAL,ORD(S[I])-ORD('0'));
        IF V>(MaxValue-D) DIV 10 THEN RETURN FALSE END;
        V:=V*10+D; INC(I)
    END; Value:=V; RETURN TRUE
END ParseCard;

PROCEDURE Trim(VAR S:Text);
VAR I,J,N:CARDINAL; T:Text;
BEGIN
    N:=Length(S); I:=0; WHILE (I<N) AND ((S[I]=' ') OR (S[I]=11C) OR (S[I]=15C) OR (S[I]=12C)) DO INC(I) END;
    J:=N; WHILE (J>I) AND ((S[J-1]=' ') OR (S[J-1]=11C) OR (S[J-1]=15C) OR (S[J-1]=12C)) DO DEC(J) END;
    T[0]:=0C; N:=0; WHILE I<J DO T[N]:=S[I]; INC(N); INC(I) END; T[N]:=0C; Assign(S,T)
END Trim;

PROCEDURE Slice(S:ARRAY OF CHAR; Start:CARDINAL; VAR Out:Text);
VAR I:CARDINAL;
BEGIN
    Clear(Out); I:=Start;
    WHILE (I<=HIGH(S)) AND (S[I]#0C) DO AppendChar(Out,S[I]); INC(I) END
END Slice;

(* gm2 documents StrIO.WriteLn as carriage return plus newline but the Linux
   implementation emits a bare newline.  Terminals that do not translate LF
   on output render that as a diagonal staircase, so every logical line ends
   with an explicit CR+LF pair instead of relying on tty translation.  *)
PROCEDURE NewLine;
BEGIN
    Write(15C);
    Write(12C)
END NewLine;

END HStrings.
