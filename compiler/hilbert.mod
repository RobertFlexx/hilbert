MODULE hilbert;
FROM Options IMPORT Settings,Parse,PrintHelp,PrintVersion,PrintTargets,Command;
FROM Driver IMPORT Run;
FROM Diagnostics IMPORT Init,Configure,SetColor,Summary;
FROM Environment IMPORT GetEnvironment;
FROM libc IMPORT isatty;
FROM HStrings IMPORT Text;
FROM M2RTS IMPORT ExecuteTerminationProcedures,HALT;

PROCEDURE InitialColor():BOOLEAN;
VAR Dummy:Text;
BEGIN
    IF GetEnvironment('NO_COLOR',Dummy) THEN RETURN FALSE END;
    RETURN isatty(2)#0
END InitialColor;

VAR S:Settings; Code:INTEGER; Parsed:BOOLEAN;
BEGIN
    Init(InitialColor()); Configure(50,FALSE,FALSE,TRUE);
    Parsed:=Parse(S); Code:=0;
    IF NOT Parsed THEN
        Summary; Code:=2
    ELSE
        SetColor(S.Color);
        CASE S.Cmd OF
        | CmdHelp: PrintHelp
        | CmdVersion: PrintVersion
        | CmdTargets: PrintTargets
        ELSE
            Code:=Run(S);
            IF S.ShowSummary THEN Summary END
        END
    END;
    IF Code#0 THEN
        ExecuteTerminationProcedures;
        HALT(Code)
    END
END hilbert.
