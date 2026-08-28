MODULE hilmake;

FROM SYSTEM IMPORT ADR,ADDRESS;
FROM libc IMPORT system,execv,isatty;
FROM M2RTS IMPORT ExecuteTerminationProcedures,HALT;
IMPORT SArgs,DynamicStrings;
FROM Environment IMPORT GetEnvironment;
FROM StrIO IMPORT WriteString;
FROM NumberIO IMPORT WriteCard;
FROM HStrings IMPORT Text,Assign,Append,AppendChar,Equal,Length,StartsWith,EndsWith,ParseCard,Slice,NewLine;
FROM Project IMPORT Config,Profile,Load,Print,PrintInfo;
FROM Diagnostics IMPORT Init,Configure,Summary,SimpleCode,Severity;
FROM ErrorCodes IMPORT EProjectSyntax,ECommandTooLong,EArgumentTooLong;
IMPORT FIO;

CONST MaxCommand=32767; MaxRunArgs=256;
TYPE CommandText=ARRAY [0..MaxCommand] OF CHAR;
     RunArgArray=ARRAY [0..MaxRunArgs-1] OF Text;

VAR CommandOverflow,ArgFailure:BOOLEAN;

PROCEDURE BigClear(VAR S:CommandText);
BEGIN S[0]:=0C; CommandOverflow:=FALSE END BigClear;

PROCEDURE BigAppend(VAR D:CommandText; S:ARRAY OF CHAR);
VAR Pos,SrcPos:CARDINAL;
BEGIN
    Pos:=0;
    WHILE (Pos<=HIGH(D)) AND (D[Pos]#0C) DO INC(Pos) END;
    SrcPos:=0;
    WHILE (Pos<HIGH(D)) AND (SrcPos<=HIGH(S)) AND (S[SrcPos]#0C) DO
        D[Pos]:=S[SrcPos]; INC(Pos); INC(SrcPos)
    END;
    D[Pos]:=0C;
    IF (SrcPos<=HIGH(S)) AND (S[SrcPos]#0C) THEN CommandOverflow:=TRUE END
END BigAppend;

PROCEDURE CommandChar(VAR D:CommandText; C:CHAR);
VAR I:CARDINAL;
BEGIN
    I:=0; WHILE (I<=HIGH(D)) AND (D[I]#0C) DO INC(I) END;
    IF I<HIGH(D) THEN D[I]:=C; D[I+1]:=0C ELSE CommandOverflow:=TRUE END
END CommandChar;

PROCEDURE Quote(VAR D:CommandText; S:ARRAY OF CHAR);
VAR I:CARDINAL;
BEGIN
    CommandChar(D,VAL(CHAR,39)); I:=0;
    WHILE (I<=HIGH(S)) AND (S[I]#0C) DO
        IF S[I]=VAL(CHAR,39) THEN
            CommandChar(D,VAL(CHAR,39)); CommandChar(D,'"'); CommandChar(D,VAL(CHAR,39)); CommandChar(D,'"'); CommandChar(D,VAL(CHAR,39))
        ELSE CommandChar(D,S[I])
        END;
        INC(I)
    END;
    CommandChar(D,VAL(CHAR,39))
END Quote;

PROCEDURE DecodeWaitStatus(Status:INTEGER):INTEGER;
VAR Signal,ExitCode:INTEGER;
BEGIN
    (* POSIX system(3) returns a wait status, not the child's exit code. Passing
       the encoded value to HALT truncates common failures such as 2 << 8 to
       zero. Normalize it before hilmake makes any control-flow decision. *)
    IF Status<0 THEN RETURN 127 END;
    Signal:=Status MOD 128;
    IF Signal#0 THEN RETURN 128+Signal END;
    ExitCode:=(Status DIV 256) MOD 256;
    IF (ExitCode=0) AND (Status#0) THEN RETURN 1 END;
    RETURN ExitCode
END DecodeWaitStatus;

PROCEDURE RunCommand(VAR D:CommandText; Verbose:BOOLEAN):INTEGER;
VAR Status:INTEGER;
BEGIN
    IF CommandOverflow THEN SimpleCode(Error,ECommandTooLong,'generated command exceeds 32767 bytes'); RETURN 2 END;
    IF Verbose THEN WriteString('> '); WriteString(D); NewLine END;
    Status:=system(ADR(D));
    RETURN DecodeWaitStatus(Status)
END RunCommand;

PROCEDURE FetchArg(VAR A:Text; Index:CARDINAL);
VAR S:DynamicStrings.String; N:CARDINAL;
BEGIN
    A[0]:=0C;
    IF NOT SArgs.GetArg(S,Index) THEN RETURN END;
    N:=DynamicStrings.Length(S);
    IF N>HIGH(A) THEN
        DynamicStrings.Fin(S); ArgFailure:=TRUE;
        SimpleCode(Error,EArgumentTooLong,'command-line argument exceeds 1023 bytes'); RETURN
    END;
    DynamicStrings.CopyOut(A,S); DynamicStrings.Fin(S)
END FetchArg;

PROCEDURE HasSlash(S:ARRAY OF CHAR):BOOLEAN;
VAR Pos:CARDINAL;
BEGIN
    Pos:=0;
    WHILE (Pos<=HIGH(S)) AND (S[Pos]#0C) DO
        IF S[Pos]='/' THEN RETURN TRUE END;
        INC(Pos)
    END;
    RETURN FALSE
END HasSlash;

PROCEDURE IsAction(S:ARRAY OF CHAR):BOOLEAN;
BEGIN
    RETURN Equal(S,'build') OR Equal(S,'check') OR Equal(S,'run') OR
           Equal(S,'clean') OR Equal(S,'rebuild') OR Equal(S,'show') OR Equal(S,'info') OR
           Equal(S,'targets') OR Equal(S,'graph') OR Equal(S,'explain') OR
           Equal(S,'install') OR Equal(S,'uninstall')
END IsAction;

PROCEDURE HasParentComponent(Path:ARRAY OF CHAR):BOOLEAN;
VAR I,N:CARDINAL;
BEGIN
    N:=Length(Path); I:=0;
    WHILE I+1<N DO
        IF (Path[I]='.') AND (Path[I+1]='.') THEN
            IF I=0 THEN
                IF I+2=N THEN RETURN TRUE
                ELSIF Path[I+2]='/' THEN RETURN TRUE
                END
            ELSIF Path[I-1]='/' THEN
                IF I+2=N THEN RETURN TRUE
                ELSIF Path[I+2]='/' THEN RETURN TRUE
                END
            END
        END;
        INC(I)
    END;
    RETURN FALSE
END HasParentComponent;

PROCEDURE SafeRemovalPath(Path:ARRAY OF CHAR):BOOLEAN;
BEGIN
    RETURN (Length(Path)>0) AND (Path[0]#'/') AND NOT Equal(Path,'.') AND NOT HasParentComponent(Path)
END SafeRemovalPath;

PROCEDURE SafeInstallDir(Path:ARRAY OF CHAR):BOOLEAN;
BEGIN
    RETURN (Length(Path)>0) AND (Path[0]#'/') AND NOT HasParentComponent(Path)
END SafeInstallDir;

PROCEDURE SafeInstallPrefix(Path:ARRAY OF CHAR):BOOLEAN;
BEGIN
    RETURN (Length(Path)>0) AND NOT HasParentComponent(Path)
END SafeInstallPrefix;

PROCEDURE CheckCleanPaths(Cfg:Config; IncludeOutput:BOOLEAN):BOOLEAN;
VAR BuildPrefix:Text;
BEGIN
    IF NOT SafeRemovalPath(Cfg.BuildDir) THEN
        SimpleCode(Error,EProjectSyntax,'refusing to remove unsafe BUILD_DIR; use a relative path without ..'); RETURN FALSE
    END;
    IF IncludeOutput AND NOT SafeRemovalPath(Cfg.Output) THEN
        SimpleCode(Error,EProjectSyntax,'refusing to remove unsafe OUTPUT; use a relative path without ..'); RETURN FALSE
    END;
    Assign(BuildPrefix,Cfg.BuildDir); IF (Length(BuildPrefix)>0) AND (BuildPrefix[Length(BuildPrefix)-1]#'/') THEN Append(BuildPrefix,'/') END;
    IF StartsWith(Cfg.Root,BuildPrefix) THEN
        SimpleCode(Error,EProjectSyntax,'refusing to clean a BUILD_DIR that contains the project entry source'); RETURN FALSE
    END;
    RETURN TRUE
END CheckCleanPaths;

PROCEDURE ProfileName(P:Profile; VAR Name:Text);
BEGIN
    CASE P OF
    | Debug:Assign(Name,'debug')
    | Release:Assign(Name,'release')
    | Size:Assign(Name,'size')
    END
END ProfileName;

PROCEDURE Status(Verb:ARRAY OF CHAR; Cfg:Config; Quiet:BOOLEAN);
VAR P:Text;
BEGIN
    IF Quiet THEN RETURN END;
    ProfileName(Cfg.Mode,P);
    IF Equal(Verb,'build') OR Equal(Verb,'rebuild') OR Equal(Verb,'check') THEN
        WriteString('hilmake: configuring '); WriteString(Cfg.Name); NewLine;
        WriteString('hilmake: target '); WriteString(Cfg.Target); NewLine;
        WriteString('hilmake: profile '); WriteString(P); NewLine;
        WriteString('hilmake: runtime '); WriteString(Cfg.Runtime); NewLine
    ELSE
        WriteString('hilmake: '); WriteString(Verb); IF Cfg.Name[0]#0C THEN WriteString(' '); WriteString(Cfg.Name) END; NewLine
    END
END Status;

PROCEDURE Help;
BEGIN
    WriteString('hilmake 1.0.0'); NewLine;
    WriteString('project builder for Hilbert'); NewLine;
    NewLine;
    WriteString('usage:'); NewLine;
    WriteString('  hilmake <command> [Hilbertfile] [options]'); NewLine;
    WriteString('  hilmake <command> -f <file> [options]'); NewLine;
    NewLine;
    WriteString('commands:'); NewLine;
    WriteString('  build       build the project (default command)'); NewLine;
    WriteString('  check       parse and type-check the project'); NewLine;
    WriteString('  run         build, then run the output'); NewLine;
    WriteString('  clean       remove project build output'); NewLine;
    WriteString('  rebuild     clean and build again'); NewLine;
    WriteString('  install     build and install the project output'); NewLine;
    WriteString('  uninstall   remove files listed by the install manifest'); NewLine;
    WriteString('  info        print concise project and release metadata'); NewLine;
    WriteString('  targets     list compiler targets'); NewLine;
    WriteString('  graph       print the checked module dependency graph'); NewLine;
    WriteString('  explain     build and explain every cache miss'); NewLine;
    WriteString('  show        print the resolved project settings'); NewLine;
    WriteString('  help        show this help'); NewLine;
    WriteString('  version     show hilmake version'); NewLine;
    NewLine;
    WriteString('options:'); NewLine;
    WriteString('  -f, --file <file>    use another Hilbertfile'); NewLine;
    WriteString('  -v, --verbose        show commands and compiler details'); NewLine;
    WriteString('  -vv, --trace         show commands, dependencies, and cache decisions'); NewLine;
    WriteString('  -q, --quiet          suppress hilmake/compiler chatter'); NewLine;
    WriteString('  -j, --jobs <n>       choose the native build job budget'); NewLine;
    WriteString('  --profile <name>     override debug, release, or size'); NewLine;
    WriteString('  --target <triple>    override the target triple'); NewLine;
    WriteString('  --runtime <name>     override hosted or freestanding selection'); NewLine;
    WriteString('  --no-cache           do not reuse module objects'); NewLine;
    WriteString('  --keep-temps         retain assembly and intermediate files'); NewLine;
    WriteString('  --prefix <dir>       set the install prefix'); NewLine;
    WriteString('  --dot                emit Graphviz DOT from graph'); NewLine;
    WriteString('  --no-color           disable compiler diagnostic color'); NewLine;
    WriteString('  -h, --help           show this help'); NewLine;
    WriteString('  -V, --version        show version'); NewLine;
    NewLine;
    WriteString('run arguments:'); NewLine;
    WriteString('  hilmake run -- <args...>'); NewLine;
    NewLine;
    WriteString('examples:'); NewLine;
    WriteString('  hilmake build'); NewLine;
    WriteString('  hilmake build -v'); NewLine;
    WriteString('  hilmake check -f examples/Hilbertfile'); NewLine;
    WriteString('  hilmake run -- --fullscreen'); NewLine
END Help;

PROCEDURE CommandHelp(VerbName:ARRAY OF CHAR);
BEGIN
    IF Equal(VerbName,'build') THEN
        WriteString('usage: hilmake build [-v|-vv] [-q] [-j n] [--profile name] [--target triple]'); NewLine;
        WriteString('builds the project with dependency-aware compiler caching'); NewLine
    ELSIF Equal(VerbName,'run') THEN
        WriteString('usage: hilmake run [build options] [-- program arguments...]'); NewLine;
        WriteString('executes the output directly so signals, input, and exit status stay native'); NewLine
    ELSIF Equal(VerbName,'graph') THEN
        WriteString('usage: hilmake graph [--dot] [--profile name] [--target triple]'); NewLine
    ELSIF Equal(VerbName,'install') OR Equal(VerbName,'uninstall') THEN
        WriteString('usage: hilmake '); WriteString(VerbName); WriteString(' [--prefix directory]'); NewLine;
        WriteString('uninstall removes only paths recorded by the project install manifest'); NewLine
    ELSE Help
    END
END CommandHelp;

PROCEDURE Version;
BEGIN
    WriteString('hilmake 1.0.0'); NewLine
END Version;

PROCEDURE CardinalText(Number:CARDINAL; VAR Out:Text);
VAR Digits:ARRAY[0..31] OF CHAR; N,I:CARDINAL;
BEGIN
    IF Number=0 THEN Assign(Out,'0'); RETURN END; N:=0;
    WHILE Number>0 DO Digits[N]:=VAL(CHAR,ORD('0')+(Number MOD 10)); INC(N); Number:=Number DIV 10 END;
    I:=0; WHILE N>0 DO DEC(N); Out[I]:=Digits[N]; INC(I) END; Out[I]:=0C
END CardinalText;

PROCEDURE CompilerCommand(Cfg:Config; Operation:ARRAY OF CHAR; Verbose,Quiet,NoColor,Explain,Trace,Dot:BOOLEAN; Jobs:CARDINAL; VAR OutCmd:CommandText);
VAR Index:CARDINAL; P,J:Text;
BEGIN
    BigClear(OutCmd);
    BigAppend(OutCmd,'hilbert '); BigAppend(OutCmd,Operation); BigAppend(OutCmd,' ');
    Quote(OutCmd,Cfg.Root);
    IF Equal(Operation,'build') THEN BigAppend(OutCmd,' -o '); Quote(OutCmd,Cfg.Output) END;
    BigAppend(OutCmd,' --target '); Quote(OutCmd,Cfg.Target);
    BigAppend(OutCmd,' --cache-dir '); Quote(OutCmd,Cfg.BuildDir);
    ProfileName(Cfg.Mode,P); BigAppend(OutCmd,' --profile '); Quote(OutCmd,P);
    BigAppend(OutCmd,' --runtime '); Quote(OutCmd,Cfg.Runtime);
    CASE Cfg.Mode OF
    | Debug:BigAppend(OutCmd,' -O0 -g')
    | Release:BigAppend(OutCmd,' -O3')
    | Size:BigAppend(OutCmd,' -Os')
    END;
    IF Cfg.StaticLink THEN BigAppend(OutCmd,' --static') END;
    IF Cfg.Strip THEN BigAppend(OutCmd,' --strip') END;
    IF Cfg.WarningsAsErrors THEN BigAppend(OutCmd,' -Werror') END;
    IF NOT Cfg.Incremental THEN BigAppend(OutCmd,' --no-incremental') END;
    IF Cfg.KeepTemps THEN BigAppend(OutCmd,' --keep-temps') END;
    IF Verbose THEN BigAppend(OutCmd,' -v') END;
    IF Explain THEN BigAppend(OutCmd,' --explain') END;
    IF Trace THEN BigAppend(OutCmd,' --trace') END;
    IF Dot THEN BigAppend(OutCmd,' --dot') END;
    IF Equal(Operation,'build') AND NOT Quiet THEN BigAppend(OutCmd,' --progress') END;
    IF Jobs>0 THEN CardinalText(Jobs,J); BigAppend(OutCmd,' --jobs '); Quote(OutCmd,J) END;
    IF Quiet THEN BigAppend(OutCmd,' --quiet --no-summary') END;
    IF NoColor THEN BigAppend(OutCmd,' --no-color') END;
    Index:=0;
    WHILE Index<Cfg.ModulePathCount DO
        BigAppend(OutCmd,' -I '); Quote(OutCmd,Cfg.ModulePaths[Index]); INC(Index)
    END;
    Index:=0;
    WHILE Index<Cfg.LibraryPathCount DO
        BigAppend(OutCmd,' -L '); Quote(OutCmd,Cfg.LibraryPaths[Index]); INC(Index)
    END;
    Index:=0;
    WHILE Index<Cfg.LibraryCount DO
        BigAppend(OutCmd,' '); BigAppend(OutCmd,'-l'); Quote(OutCmd,Cfg.Libraries[Index]); INC(Index)
    END
END CompilerCommand;

PROCEDURE RunOutput(Cfg:Config; VAR RunArgs:RunArgArray; RunArgCount:CARDINAL; Verbose:BOOLEAN; VAR OutCmd:CommandText):INTEGER;
VAR Program:Text; Argv:ARRAY[0..MaxRunArgs+1] OF ADDRESS; ExecCode:INTEGER; I:CARDINAL;
BEGIN
    IF HasSlash(Cfg.Output) THEN Assign(Program,Cfg.Output) ELSE Assign(Program,'./'); Append(Program,Cfg.Output) END;
    BigClear(OutCmd);
    Quote(OutCmd,Program); I:=0;
    WHILE I<RunArgCount DO BigAppend(OutCmd,' '); Quote(OutCmd,RunArgs[I]); INC(I) END;
    IF Verbose THEN WriteString('> '); WriteString(OutCmd); NewLine END;
    Argv[0]:=ADR(Program); I:=0;
    WHILE I<RunArgCount DO Argv[I+1]:=ADR(RunArgs[I]); INC(I) END;
    Argv[RunArgCount+1]:=VAL(ADDRESS,0);
    ExecCode:=execv(ADR(Program),ADR(Argv));
    IF ExecCode=0 THEN RETURN 0 END;
    WriteString('hilmake: could not start project output'); NewLine;
    RETURN 127
END RunOutput;

PROCEDURE JoinPath(Left,Right:ARRAY OF CHAR; VAR Out:Text);
BEGIN Assign(Out,Left); IF (Length(Out)>0) AND (Out[Length(Out)-1]#'/') THEN Append(Out,'/') END; Append(Out,Right) END JoinPath;

PROCEDURE LeafName(Path:ARRAY OF CHAR; VAR Out:Text);
VAR I,Start,N:CARDINAL;
BEGIN
    N:=Length(Path); Start:=0; I:=0; WHILE I<N DO IF Path[I]='/' THEN Start:=I+1 END; INC(I) END;
    Out[0]:=0C; I:=Start; WHILE I<N DO AppendChar(Out,Path[I]); INC(I) END
END LeafName;

PROCEDURE ExpandPrefix(Input:ARRAY OF CHAR; VAR Out:Text):BOOLEAN;
VAR Home,Rest:Text;
BEGIN
    IF StartsWith(Input,'~/') THEN
        IF NOT GetEnvironment('HOME',Home) THEN SimpleCode(Error,EProjectSyntax,'cannot expand install prefix without HOME'); RETURN FALSE END;
        Slice(Input,2,Rest); JoinPath(Home,Rest,Out); RETURN TRUE
    END;
    Assign(Out,Input); RETURN TRUE
END ExpandPrefix;

PROCEDURE ManifestPath(Cfg:Config; InstallRoot:ARRAY OF CHAR; VAR Out:Text);
VAR Dir,Name,N:Text; I,A,B:CARDINAL;
BEGIN
    A:=0; B:=0; I:=0;
    WHILE (I<=HIGH(Cfg.Name)) AND (Cfg.Name[I]#0C) DO
        A:=(A*257+ORD(Cfg.Name[I])+1) MOD 2147483629;
        B:=(B*263+ORD(Cfg.Name[I])+1) MOD 2147483587;
        INC(I)
    END;
    Assign(Name,'project-'); CardinalText(A,N); Append(Name,N); Append(Name,'-'); CardinalText(B,N); Append(Name,N); Append(Name,'.manifest');
    JoinPath(InstallRoot,'share/hilmake',Dir); JoinPath(Dir,Name,Out)
END ManifestPath;

PROCEDURE SaveManifest(Path,ProjectName,Installed:ARRAY OF CHAR):BOOLEAN;
VAR F:FIO.File;
BEGIN
    F:=FIO.OpenToWrite(Path); IF NOT FIO.IsNoError(F) THEN FIO.Close(F); RETURN FALSE END;
    FIO.WriteString(F,ProjectName); FIO.WriteChar(F,12C); FIO.WriteString(F,Installed); FIO.WriteChar(F,12C); FIO.Close(F); RETURN TRUE
END SaveManifest;

PROCEDURE ReadManifestLine(F:FIO.File; VAR Out:Text):BOOLEAN;
VAR C:CHAR; I:CARDINAL; TooLong:BOOLEAN;
BEGIN
    Out[0]:=0C; I:=0; TooLong:=FALSE;
    LOOP
        IF FIO.EOF(F) THEN EXIT END;
        C:=FIO.ReadChar(F); IF C=12C THEN EXIT END;
        IF C#15C THEN IF I<HIGH(Out) THEN Out[I]:=C; INC(I) ELSE TooLong:=TRUE END END
    END;
    Out[I]:=0C; RETURN NOT TooLong
END ReadManifestLine;

PROCEDURE ReadManifest(Path,ExpectedProject:ARRAY OF CHAR; VAR Installed:Text):BOOLEAN;
VAR F:FIO.File; ProjectName:Text; OK:BOOLEAN;
BEGIN
    Installed[0]:=0C; F:=FIO.OpenToRead(Path); IF NOT FIO.IsNoError(F) THEN FIO.Close(F); RETURN FALSE END;
    OK:=ReadManifestLine(F,ProjectName) AND ReadManifestLine(F,Installed);
    FIO.Close(F);
    RETURN OK AND Equal(ProjectName,ExpectedProject) AND (Installed[0]#0C)
END ReadManifest;

PROCEDURE InstallOutput(Cfg:Config; PrefixArg:ARRAY OF CHAR; Verbose,Quiet:BOOLEAN; VAR Cmd:CommandText):INTEGER;
VAR ResolvedPrefix,Dir,ManifestDir,Name,Installed,Manifest:Text; InstallCode:INTEGER;
BEGIN
    IF NOT ExpandPrefix(PrefixArg,ResolvedPrefix) THEN RETURN 2 END;
    IF NOT SafeInstallPrefix(ResolvedPrefix) THEN SimpleCode(Error,EProjectSyntax,'install prefix must not contain .. path components'); RETURN 2 END;
    IF NOT SafeInstallDir(Cfg.InstallDir) THEN SimpleCode(Error,EProjectSyntax,'INSTALL_DIR must be a relative path without ..'); RETURN 2 END;
    JoinPath(ResolvedPrefix,Cfg.InstallDir,Dir); LeafName(Cfg.Output,Name); JoinPath(Dir,Name,Installed);
    JoinPath(ResolvedPrefix,'share/hilmake',ManifestDir); BigClear(Cmd); BigAppend(Cmd,'mkdir -p -- '); Quote(Cmd,Dir); BigAppend(Cmd,' '); Quote(Cmd,ManifestDir); InstallCode:=RunCommand(Cmd,Verbose); IF InstallCode#0 THEN RETURN InstallCode END;
    BigClear(Cmd); BigAppend(Cmd,'cp -- '); Quote(Cmd,Cfg.Output); BigAppend(Cmd,' '); Quote(Cmd,Installed); InstallCode:=RunCommand(Cmd,Verbose); IF InstallCode#0 THEN RETURN InstallCode END;
    ManifestPath(Cfg,ResolvedPrefix,Manifest); IF NOT SaveManifest(Manifest,Cfg.Name,Installed) THEN SimpleCode(Error,EProjectSyntax,'cannot write install manifest'); RETURN 2 END;
    IF NOT Quiet THEN WriteString('hilmake: installed '); WriteString(Installed); NewLine END; RETURN 0
END InstallOutput;

PROCEDURE UninstallOutput(Cfg:Config; PrefixArg:ARRAY OF CHAR; Verbose,Quiet:BOOLEAN; VAR Cmd:CommandText):INTEGER;
VAR ResolvedPrefix,Allowed,Manifest,Installed:Text; UninstallCode:INTEGER;
BEGIN
    IF NOT ExpandPrefix(PrefixArg,ResolvedPrefix) THEN RETURN 2 END;
    IF NOT SafeInstallPrefix(ResolvedPrefix) THEN SimpleCode(Error,EProjectSyntax,'install prefix must not contain .. path components'); RETURN 2 END;
    ManifestPath(Cfg,ResolvedPrefix,Manifest);
    IF NOT ReadManifest(Manifest,Cfg.Name,Installed) THEN SimpleCode(Error,EProjectSyntax,'install manifest is missing, corrupt or belongs to another project'); RETURN 2 END;
    Assign(Allowed,ResolvedPrefix); IF (Length(Allowed)=0) OR (Allowed[Length(Allowed)-1]#'/') THEN Append(Allowed,'/') END;
    IF HasParentComponent(Installed) OR NOT StartsWith(Installed,Allowed) THEN SimpleCode(Error,EProjectSyntax,'install manifest contains a path outside the selected prefix'); RETURN 2 END;
    BigClear(Cmd); BigAppend(Cmd,'rm -f -- '); Quote(Cmd,Installed); UninstallCode:=RunCommand(Cmd,Verbose); IF UninstallCode#0 THEN RETURN UninstallCode END;
    BigClear(Cmd); BigAppend(Cmd,'rm -f -- '); Quote(Cmd,Manifest); UninstallCode:=RunCommand(Cmd,Verbose);
    IF (UninstallCode=0) AND NOT Quiet THEN WriteString('hilmake: uninstalled '); WriteString(Installed); NewLine END; RETURN UninstallCode
END UninstallOutput;

PROCEDURE BadArgument(S:ARRAY OF CHAR);
BEGIN
    WriteString('hilmake: unknown option or argument: '); WriteString(S); NewLine;
    WriteString("try 'hilmake help'"); NewLine
END BadArgument;

PROCEDURE Min3(A,B,C:CARDINAL):CARDINAL;
BEGIN IF A>B THEN A:=B END; IF A>C THEN A:=C END; RETURN A END Min3;

PROCEDURE EditDistance(A,B:ARRAY OF CHAR):CARDINAL;
VAR Previous,Current:ARRAY[0..64] OF CARDINAL; I,J,ALen,BLen,Cost:CARDINAL;
BEGIN
    ALen:=Length(A); BLen:=Length(B); IF ALen>64 THEN ALen:=64 END; IF BLen>64 THEN BLen:=64 END;
    J:=0; WHILE J<=BLen DO Previous[J]:=J; INC(J) END;
    I:=1;
    WHILE I<=ALen DO
        Current[0]:=I; J:=1;
        WHILE J<=BLen DO IF A[I-1]=B[J-1] THEN Cost:=0 ELSE Cost:=1 END;
            Current[J]:=Min3(Current[J-1]+1,Previous[J]+1,Previous[J-1]+Cost); INC(J)
        END;
        J:=0; WHILE J<=BLen DO Previous[J]:=Current[J]; INC(J) END; INC(I)
    END;
    RETURN Previous[BLen]
END EditDistance;

PROCEDURE ConsiderSuggestion(Input,Candidate:ARRAY OF CHAR; VAR Best:Text; VAR Score:CARDINAL);
VAR D:CARDINAL;
BEGIN D:=EditDistance(Input,Candidate); IF D<Score THEN Score:=D; Assign(Best,Candidate) END END ConsiderSuggestion;

PROCEDURE UnknownCommand(S:ARRAY OF CHAR);
VAR Best:Text; Score:CARDINAL;
BEGIN
    Best[0]:=0C; Score:=100;
    ConsiderSuggestion(S,'build',Best,Score); ConsiderSuggestion(S,'check',Best,Score); ConsiderSuggestion(S,'run',Best,Score);
    ConsiderSuggestion(S,'clean',Best,Score); ConsiderSuggestion(S,'rebuild',Best,Score); ConsiderSuggestion(S,'install',Best,Score);
    ConsiderSuggestion(S,'uninstall',Best,Score); ConsiderSuggestion(S,'info',Best,Score); ConsiderSuggestion(S,'targets',Best,Score);
    ConsiderSuggestion(S,'graph',Best,Score); ConsiderSuggestion(S,'explain',Best,Score);
    WriteString("hilmake: unknown command '"); WriteString(S); WriteString("'"); NewLine;
    IF Score<=3 THEN WriteString("did you mean '"); WriteString(Best); WriteString("'?"); NewLine END
END UnknownCommand;

PROCEDURE ApplyOverrides(VAR Cfg:Config; ProfileValue,TargetValue,RuntimeValue:ARRAY OF CHAR; NoCache,KeepTemps:BOOLEAN):BOOLEAN;
BEGIN
    IF ProfileValue[0]#0C THEN
        IF Equal(ProfileValue,'debug') THEN Cfg.Mode:=Debug
        ELSIF Equal(ProfileValue,'release') THEN Cfg.Mode:=Release
        ELSIF Equal(ProfileValue,'size') THEN Cfg.Mode:=Size
        ELSE SimpleCode(Error,EProjectSyntax,'profile must be debug, release, or size'); RETURN FALSE
        END
    END;
    IF TargetValue[0]#0C THEN Assign(Cfg.Target,TargetValue) END;
    IF RuntimeValue[0]#0C THEN
        IF Equal(RuntimeValue,'hosted') OR Equal(RuntimeValue,'freestanding') THEN Assign(Cfg.Runtime,RuntimeValue)
        ELSE SimpleCode(Error,EProjectSyntax,'runtime must be hosted or freestanding'); RETURN FALSE
        END
    END;
    IF NoCache THEN Cfg.Incremental:=FALSE END; IF KeepTemps THEN Cfg.KeepTemps:=TRUE END; RETURN TRUE
END ApplyOverrides;

VAR MainConfig:Config; MainCommand:CommandText; MainRunArgs:RunArgArray;
    Action,FileName,Arg,Value,ProfileOverride,TargetOverride,RuntimeOverride,Prefix:Text;
    ArgCount,ArgIndex,MainRunArgCount,MainJobs:CARDINAL; Code:INTEGER;
    DoWork,FileSet,MainVerbose,MainQuiet,MainNoColor,RunTail,ParseOK,MainExplain,MainTrace,MainDot,MainNoCache,MainKeepTemps:BOOLEAN;
BEGIN
    MainNoColor:=GetEnvironment('NO_COLOR',Value); IF isatty(2)=0 THEN MainNoColor:=TRUE END; Init(NOT MainNoColor); Configure(20,FALSE,FALSE,TRUE);
    Assign(Action,'build'); Assign(FileName,'Hilbertfile');
    Assign(Prefix,'/usr/local'); ProfileOverride[0]:=0C; TargetOverride[0]:=0C; RuntimeOverride[0]:=0C;
    MainRunArgCount:=0;
    MainVerbose:=FALSE; MainQuiet:=FALSE; RunTail:=FALSE; MainExplain:=FALSE; MainTrace:=FALSE; MainDot:=FALSE; MainNoCache:=FALSE; MainKeepTemps:=FALSE; MainJobs:=1;
    FileSet:=FALSE; ParseOK:=TRUE; Code:=0; DoWork:=TRUE;

    ArgFailure:=FALSE; ArgCount:=SArgs.Narg();
    IF ArgCount>0 THEN DEC(ArgCount) END;  (* Args.Narg includes argv[0]. *)
    ArgIndex:=1;

    IF ArgCount=0 THEN
        Help; DoWork:=FALSE
    ELSE
        FetchArg(Arg,1);
        IF ArgFailure THEN DoWork:=FALSE; Code:=2
        ELSIF Equal(Arg,'--help') OR Equal(Arg,'-h') OR Equal(Arg,'help') THEN
            Help; DoWork:=FALSE
        ELSIF Equal(Arg,'--version') OR Equal(Arg,'-V') OR Equal(Arg,'version') THEN
            Version; DoWork:=FALSE
        ELSIF IsAction(Arg) THEN
            Assign(Action,Arg); ArgIndex:=2
        ELSIF Arg[0]='-' THEN
            ArgIndex:=1
        ELSIF FIO.Exists(Arg) OR HasSlash(Arg) OR EndsWith(Arg,'Hilbertfile') THEN
            Assign(FileName,Arg); FileSet:=TRUE; ArgIndex:=2
        ELSE
            UnknownCommand(Arg); DoWork:=FALSE; Code:=2
        END
    END;

    IF DoWork THEN
        WHILE (ArgIndex<=ArgCount) AND ParseOK DO
            FetchArg(Arg,ArgIndex);
            IF ArgFailure THEN
                ParseOK:=FALSE
            ELSIF RunTail THEN
                IF MainRunArgCount>=MaxRunArgs THEN
                    WriteString('hilmake: too many program arguments'); NewLine; ParseOK:=FALSE
                ELSE Assign(MainRunArgs[MainRunArgCount],Arg); INC(MainRunArgCount)
                END
            ELSIF Equal(Arg,'--') THEN
                IF Equal(Action,'run') THEN RunTail:=TRUE ELSE BadArgument(Arg); ParseOK:=FALSE END
            ELSIF Equal(Arg,'-f') OR Equal(Arg,'--file') THEN
                INC(ArgIndex);
                IF ArgIndex>ArgCount THEN
                    WriteString('hilmake: -f requires a file'); NewLine; ParseOK:=FALSE
                ELSE
                    FetchArg(FileName,ArgIndex); FileSet:=TRUE
                END
            ELSIF Equal(Arg,'-v') OR Equal(Arg,'--verbose') THEN
                MainVerbose:=TRUE
            ELSIF Equal(Arg,'-vv') OR Equal(Arg,'--trace') THEN
                MainVerbose:=TRUE; MainTrace:=TRUE; MainExplain:=TRUE
            ELSIF Equal(Arg,'-q') OR Equal(Arg,'--quiet') THEN
                MainQuiet:=TRUE
            ELSIF Equal(Arg,'--explain') THEN
                MainExplain:=TRUE
            ELSIF Equal(Arg,'--dot') THEN
                MainDot:=TRUE
            ELSIF Equal(Arg,'--no-cache') THEN
                MainNoCache:=TRUE
            ELSIF Equal(Arg,'--keep-temps') THEN
                MainKeepTemps:=TRUE
            ELSIF Equal(Arg,'--no-color') THEN
                MainNoColor:=TRUE
            ELSIF Equal(Arg,'--color') THEN
                INC(ArgIndex); IF ArgIndex>ArgCount THEN WriteString('hilmake: --color requires auto, always, or never'); NewLine; ParseOK:=FALSE
                ELSE FetchArg(Value,ArgIndex); IF Equal(Value,'never') THEN MainNoColor:=TRUE ELSIF Equal(Value,'always') THEN MainNoColor:=FALSE ELSIF Equal(Value,'auto') THEN MainNoColor:=GetEnvironment('NO_COLOR',Value); IF isatty(2)=0 THEN MainNoColor:=TRUE END ELSE WriteString('hilmake: --color requires auto, always, or never'); NewLine; ParseOK:=FALSE END END
            ELSIF Equal(Arg,'--profile') OR Equal(Arg,'--target') OR Equal(Arg,'--runtime') OR Equal(Arg,'--prefix') THEN
                Assign(Value,Arg); INC(ArgIndex);
                IF ArgIndex>ArgCount THEN WriteString('hilmake: option requires a value: '); WriteString(Value); NewLine; ParseOK:=FALSE
                ELSE FetchArg(Arg,ArgIndex); IF Equal(Value,'--profile') THEN Assign(ProfileOverride,Arg) ELSIF Equal(Value,'--target') THEN Assign(TargetOverride,Arg) ELSIF Equal(Value,'--runtime') THEN Assign(RuntimeOverride,Arg) ELSE Assign(Prefix,Arg) END END
            ELSIF Equal(Arg,'-j') OR Equal(Arg,'--jobs') THEN
                INC(ArgIndex); IF ArgIndex>ArgCount THEN WriteString('hilmake: --jobs requires a positive number'); NewLine; ParseOK:=FALSE
                ELSE FetchArg(Value,ArgIndex); IF NOT ParseCard(Value,MainJobs) OR (MainJobs=0) OR (MainJobs>8) THEN WriteString('hilmake: jobs must be between 1 and 8'); NewLine; ParseOK:=FALSE END END
            ELSIF StartsWith(Arg,'-j') AND (Length(Arg)>2) THEN
                Slice(Arg,2,Value); IF NOT ParseCard(Value,MainJobs) OR (MainJobs=0) OR (MainJobs>8) THEN WriteString('hilmake: jobs must be between 1 and 8'); NewLine; ParseOK:=FALSE END
            ELSIF Equal(Arg,'--help') OR Equal(Arg,'-h') THEN
                CommandHelp(Action); DoWork:=FALSE
            ELSIF Equal(Arg,'--version') OR Equal(Arg,'-V') THEN
                Version; DoWork:=FALSE
            ELSIF Arg[0]='-' THEN
                BadArgument(Arg); ParseOK:=FALSE
            ELSIF NOT FileSet THEN
                Assign(FileName,Arg); FileSet:=TRUE
            ELSE
                BadArgument(Arg); ParseOK:=FALSE
            END;
            IF ArgFailure THEN ParseOK:=FALSE END;
            INC(ArgIndex)
        END;
        IF NOT ParseOK THEN Code:=2 END
    END;

    IF DoWork AND ParseOK THEN
        Init(NOT MainNoColor); Configure(20,FALSE,MainQuiet,TRUE);
        IF Equal(Action,'targets') THEN
            BigClear(MainCommand); BigAppend(MainCommand,'hilbert targets'); Code:=RunCommand(MainCommand,MainVerbose)
        ELSIF NOT Load(FileName,MainConfig) THEN
            Summary; Code:=2
        ELSIF NOT ApplyOverrides(MainConfig,ProfileOverride,TargetOverride,RuntimeOverride,MainNoCache,MainKeepTemps) THEN
            Summary; Code:=2
        ELSIF Equal(Action,'show') THEN
            Print(MainConfig)
        ELSIF Equal(Action,'info') THEN
            PrintInfo(MainConfig); Code:=0
        ELSIF Equal(Action,'clean') THEN
            IF NOT CheckCleanPaths(MainConfig,TRUE) THEN Summary; Code:=2
            ELSE
                Status('clean',MainConfig,MainQuiet);
                BigClear(MainCommand); BigAppend(MainCommand,'rm -rf -- '); Quote(MainCommand,MainConfig.BuildDir);
                Code:=RunCommand(MainCommand,MainVerbose);
                IF Code=0 THEN BigClear(MainCommand); BigAppend(MainCommand,'rm -f -- '); Quote(MainCommand,MainConfig.Output); Code:=RunCommand(MainCommand,MainVerbose) END
            END
        ELSIF Equal(Action,'check') THEN
            Status('check',MainConfig,MainQuiet);
            CompilerCommand(MainConfig,'check',MainVerbose,MainQuiet,MainNoColor,MainExplain,MainTrace,FALSE,MainJobs,MainCommand);
            Code:=RunCommand(MainCommand,MainVerbose)
        ELSIF Equal(Action,'graph') THEN
            CompilerCommand(MainConfig,'graph',MainVerbose,MainQuiet,MainNoColor,FALSE,MainTrace,MainDot,MainJobs,MainCommand);
            Code:=RunCommand(MainCommand,MainVerbose)
        ELSIF Equal(Action,'run') THEN
            Status('build',MainConfig,MainQuiet);
            CompilerCommand(MainConfig,'build',MainVerbose,MainQuiet,MainNoColor,MainExplain,MainTrace,FALSE,MainJobs,MainCommand);
            Code:=RunCommand(MainCommand,MainVerbose);
            IF Code=0 THEN
                Status('run',MainConfig,MainQuiet);
                Code:=RunOutput(MainConfig,MainRunArgs,MainRunArgCount,MainVerbose,MainCommand)
            END
        ELSIF Equal(Action,'rebuild') THEN
            IF NOT CheckCleanPaths(MainConfig,TRUE) THEN Summary; Code:=2
            ELSE
                Status('rebuild',MainConfig,MainQuiet);
                BigClear(MainCommand); BigAppend(MainCommand,'rm -rf -- '); Quote(MainCommand,MainConfig.BuildDir);
                Code:=RunCommand(MainCommand,MainVerbose);
                IF Code=0 THEN BigClear(MainCommand); BigAppend(MainCommand,'rm -f -- '); Quote(MainCommand,MainConfig.Output); Code:=RunCommand(MainCommand,MainVerbose) END;
                IF Code=0 THEN
                    CompilerCommand(MainConfig,'build',MainVerbose,MainQuiet,MainNoColor,MainExplain,MainTrace,FALSE,MainJobs,MainCommand);
                    Code:=RunCommand(MainCommand,MainVerbose)
                END
            END
        ELSIF Equal(Action,'build') OR Equal(Action,'explain') THEN
            IF Equal(Action,'explain') THEN MainExplain:=TRUE END;
            Status('build',MainConfig,MainQuiet);
            CompilerCommand(MainConfig,'build',MainVerbose,MainQuiet,MainNoColor,MainExplain,MainTrace,FALSE,MainJobs,MainCommand);
            Code:=RunCommand(MainCommand,MainVerbose)
        ELSIF Equal(Action,'install') THEN
            Status('build',MainConfig,MainQuiet);
            CompilerCommand(MainConfig,'build',MainVerbose,MainQuiet,MainNoColor,MainExplain,MainTrace,FALSE,MainJobs,MainCommand);
            Code:=RunCommand(MainCommand,MainVerbose); IF Code=0 THEN Code:=InstallOutput(MainConfig,Prefix,MainVerbose,MainQuiet,MainCommand) END
        ELSIF Equal(Action,'uninstall') THEN
            Code:=UninstallOutput(MainConfig,Prefix,MainVerbose,MainQuiet,MainCommand)
        ELSE
            Help; Code:=2
        END;
        IF (Code=0) AND NOT MainQuiet AND (Equal(Action,'build') OR Equal(Action,'rebuild') OR Equal(Action,'explain')) THEN
            WriteString('hilmake: built '); WriteString(MainConfig.Output); NewLine
        ELSIF (Code#0) AND NOT MainQuiet AND (Equal(Action,'build') OR Equal(Action,'rebuild') OR Equal(Action,'check') OR Equal(Action,'run') OR Equal(Action,'install') OR Equal(Action,'explain')) THEN
            WriteString('hilmake: '); WriteString(Action); WriteString(' failed'); NewLine
        END;
        IF (Code=0) AND NOT MainQuiet AND NOT Equal(Action,'show') AND NOT Equal(Action,'info') THEN Summary END
    END;

    IF Code#0 THEN
        ExecuteTerminationProcedures;
        HALT(Code)
    END
END hilmake.
