IMPLEMENTATION MODULE Diagnostics;

IMPORT FIO;
FROM ErrorCodes IMPORT DefaultMessage;
FROM HStrings IMPORT Text;

VAR Errors,Warnings: CARDINAL;
    UseColor,WarnAsError,QuietMode,ShowEndSummary,Stopped:BOOLEAN;
    ErrorLimit:CARDINAL;

PROCEDURE DString(S:ARRAY OF CHAR); BEGIN FIO.WriteString(FIO.StdErr,S) END DString;
PROCEDURE DChar(C:CHAR); BEGIN FIO.WriteChar(FIO.StdErr,C) END DChar;
PROCEDURE DLine; BEGIN FIO.WriteLine(FIO.StdErr) END DLine;

PROCEDURE DCard(Value:CARDINAL);
VAR Digits:ARRAY[0..31] OF CHAR; Count:CARDINAL;
BEGIN
    IF Value=0 THEN DChar('0'); RETURN END; Count:=0;
    WHILE Value>0 DO Digits[Count]:=VAL(CHAR,ORD('0')+(Value MOD 10)); INC(Count); Value:=Value DIV 10 END;
    WHILE Count>0 DO DEC(Count); DChar(Digits[Count]) END
END DCard;

PROCEDURE Init(Color:BOOLEAN);
BEGIN
    Errors:=0; Warnings:=0; UseColor:=Color; WarnAsError:=FALSE; QuietMode:=FALSE;
    ShowEndSummary:=TRUE; ErrorLimit:=50; Stopped:=FALSE
END Init;

PROCEDURE Configure(MaxErrors:CARDINAL; WarningsAsErrors,Quiet,ShowSummary:BOOLEAN);
BEGIN
    IF MaxErrors=0 THEN ErrorLimit:=50 ELSE ErrorLimit:=MaxErrors END;
    WarnAsError:=WarningsAsErrors; QuietMode:=Quiet; ShowEndSummary:=ShowSummary
END Configure;

PROCEDURE SetColor(Color:BOOLEAN); BEGIN UseColor:=Color END SetColor;

PROCEDURE Color(S:ARRAY OF CHAR);
BEGIN IF UseColor THEN DChar(33C); DString(S) END END Color;

PROCEDURE Prefix(Level:Severity; Code:CARDINAL);
BEGIN
    CASE Level OF
    | Note:Color('[36m')
    | Warning:Color('[33m')
    | Error:Color('[31m')
    | Fatal:Color('[1;31m')
    END;
    CASE Level OF
    | Note:DString('note')
    | Warning:DString('warning')
    | Error:DString('error')
    | Fatal:DString('fatal')
    END;
    IF Code#0 THEN DString('[H'); DCard(Code); DString(']') END;
    Color('[0m')
END Prefix;

PROCEDURE Count(Level:Severity);
BEGIN
    IF Level=Warning THEN
        INC(Warnings); IF WarnAsError THEN INC(Errors) END
    ELSIF (Level=Error) OR (Level=Fatal) THEN INC(Errors)
    END;
    IF (ErrorLimit>0) AND (Errors>=ErrorLimit) THEN Stopped:=TRUE END
END Count;

PROCEDURE Header(Level:Severity; Code:CARDINAL; File:ARRAY OF CHAR; Line,Column:CARDINAL; Message:ARRAY OF CHAR);
BEGIN
    IF QuietMode AND (Level=Note) THEN RETURN END;
    IF File[0]#0C THEN
        Color('[1m'); DString(File); Color('[0m');
        IF Line#0 THEN DString(':'); DCard(Line); IF Column#0 THEN DString(':'); DCard(Column) END END;
        DString(': ')
    END;
    Prefix(Level,Code); DString(': '); DString(Message); DLine
END Header;

PROCEDURE Coded(Level:Severity; Code:CARDINAL; File:ARRAY OF CHAR; Line,Column:CARDINAL; Message:ARRAY OF CHAR);
VAR M:Text; WasStopped:BOOLEAN;
BEGIN
    WasStopped:=Stopped;
    IF WasStopped AND ((Level=Error) OR (Level=Fatal)) THEN RETURN END;
    Count(Level); M[0]:=0C; IF Message[0]=0C THEN DefaultMessage(Code,M); Header(Level,Code,File,Line,Column,M) ELSE Header(Level,Code,File,Line,Column,Message) END;
    IF (NOT WasStopped) AND Stopped AND (Errors=ErrorLimit) THEN
        Color('[1;31m'); DString('error'); Color('[0m'); DString(': too many errors; stopping after '); DCard(ErrorLimit); DLine
    END
END Coded;

PROCEDURE CodedContext(Level:Severity; Code:CARDINAL; File:ARRAY OF CHAR; Line,Column:CARDINAL; Message,Context:ARRAY OF CHAR);
VAR I:CARDINAL; WasStopped:BOOLEAN;
BEGIN
    WasStopped:=Stopped; IF WasStopped AND ((Level=Error) OR (Level=Fatal)) THEN RETURN END;
    Coded(Level,Code,File,Line,Column,Message); IF Context[0]=0C THEN RETURN END;
    Color('[2m'); DString('  |'); Color('[0m'); DLine;
    Color('[2m'); DCard(Line); DString(' | '); Color('[0m'); DString(Context); DLine;
    Color('[2m'); DString('  | '); Color('[0m'); I:=1; WHILE I<Column DO DChar(' '); INC(I) END;
    Color('[1;32m'); DChar('^'); Color('[0m'); DLine
END CodedContext;

PROCEDURE Report(Level:Severity; File:ARRAY OF CHAR; Line,Column:CARDINAL; Message:ARRAY OF CHAR);
BEGIN Coded(Level,0,File,Line,Column,Message) END Report;

PROCEDURE ReportContext(Level:Severity; File:ARRAY OF CHAR; Line,Column:CARDINAL; Message,Context:ARRAY OF CHAR);
BEGIN CodedContext(Level,0,File,Line,Column,Message,Context) END ReportContext;

PROCEDURE Help(Message:ARRAY OF CHAR);
BEGIN
    IF QuietMode OR Stopped THEN RETURN END; Color('[1;32m'); DString('help'); Color('[0m'); DString(': '); DString(Message); DLine
END Help;

PROCEDURE NoteMessage(Message:ARRAY OF CHAR); BEGIN Coded(Note,0,'',0,0,Message) END NoteMessage;
PROCEDURE Simple(Level:Severity; Message:ARRAY OF CHAR); BEGIN Coded(Level,0,'',0,0,Message) END Simple;
PROCEDURE SimpleCode(Level:Severity; Code:CARDINAL; Message:ARRAY OF CHAR); BEGIN Coded(Level,Code,'',0,0,Message) END SimpleCode;

PROCEDURE Summary;
BEGIN
    IF NOT ShowEndSummary OR QuietMode THEN RETURN END;
    IF (Errors=0) AND (Warnings=0) THEN RETURN END;
    IF Errors#0 THEN Color('[1;31m'); DCard(Errors); DString(' error'); IF Errors#1 THEN DString('s') END; Color('[0m') END;
    IF (Errors#0) AND (Warnings#0) THEN DString(', ') END;
    IF Warnings#0 THEN Color('[1;33m'); DCard(Warnings); DString(' warning'); IF Warnings#1 THEN DString('s') END; Color('[0m') END;
    DLine; FIO.FlushOutErr
END Summary;

PROCEDURE ErrorCount():CARDINAL; BEGIN RETURN Errors END ErrorCount;
PROCEDURE WarningCount():CARDINAL; BEGIN RETURN Warnings END WarningCount;
PROCEDURE HasErrors():BOOLEAN; BEGIN RETURN Errors#0 END HasErrors;
PROCEDURE LimitReached():BOOLEAN; BEGIN RETURN Stopped END LimitReached;

END Diagnostics.
