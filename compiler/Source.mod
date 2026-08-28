IMPLEMENTATION MODULE Source;

FROM FIO IMPORT File, OpenToRead, Close, EOF, ReadChar, IsNoError;
IMPORT HStrings;
FROM HStrings IMPORT Text, Assign;
FROM Diagnostics IMPORT Coded, Severity;
FROM ErrorCodes IMPORT ESourceOpen,ESourceTooLarge;

VAR Data: ARRAY [0..MaxSource] OF CHAR;
    Len: CARDINAL;
    Name: Text;

PROCEDURE Load(Path: ARRAY OF CHAR): BOOLEAN;
VAR F: File; Ch: CHAR;
BEGIN
    Len := 0; Assign(Name, Path); F := OpenToRead(Path);
    IF NOT IsNoError(F) THEN Coded(Error,ESourceOpen,Path,0,0,'cannot open source file'); Close(F); RETURN FALSE END;
    WHILE NOT EOF(F) DO
        Ch := ReadChar(F);
        IF NOT EOF(F) OR (Ch # 0C) THEN
            IF Len >= MaxSource THEN Coded(Fatal,ESourceTooLarge,Path,0,0,'source file exceeds compiler limit'); Close(F); RETURN FALSE END;
            Data[Len] := Ch; INC(Len)
        END
    END;
    Data[Len] := 0C; Close(F); RETURN TRUE
END Load;
PROCEDURE Length(): CARDINAL; BEGIN RETURN Len END Length;
PROCEDURE CharAt(Pos: CARDINAL): CHAR; BEGIN IF Pos > Len THEN RETURN 0C ELSE RETURN Data[Pos] END END CharAt;
PROCEDURE FileName(VAR Out: Text); BEGIN Assign(Out, Name) END FileName;
PROCEDURE LineText(LineNo:CARDINAL; VAR Out:Text);
VAR I,L:CARDINAL;
BEGIN
    Out[0]:=0C; IF LineNo=0 THEN RETURN END; I:=0; L:=1;
    WHILE (I<Len) AND (L<LineNo) DO IF Data[I]=12C THEN INC(L) END; INC(I) END;
    WHILE (I<Len) AND (Data[I]#12C) AND (Data[I]#15C) DO HStrings.AppendChar(Out,Data[I]); INC(I) END
END LineText;

END Source.
