IMPLEMENTATION MODULE Asm;
IMPORT FIO;
FROM FIO IMPORT File,OpenToWrite,WriteString,WriteLine,WriteChar,IsNoError;
VAR F:File;
PROCEDURE Open(Path:ARRAY OF CHAR):BOOLEAN; BEGIN F:=OpenToWrite(Path); RETURN IsNoError(F) END Open;
PROCEDURE Close; BEGIN FIO.Close(F) END Close;
PROCEDURE Line(S:ARRAY OF CHAR); BEGIN WriteString(F,S); WriteLine(F) END Line;
PROCEDURE Text(S:ARRAY OF CHAR); BEGIN WriteString(F,S) END Text;
PROCEDURE Char(C:CHAR); BEGIN WriteChar(F,C) END Char;
END Asm.
