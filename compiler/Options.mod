IMPLEMENTATION MODULE Options;

IMPORT SArgs,DynamicStrings;
FROM libc IMPORT isatty;
FROM Environment IMPORT GetEnvironment;
FROM StrIO IMPORT WriteString;
FROM HStrings IMPORT Text,Assign,Equal,StartsWith,Slice,ParseCard,NewLine;
FROM Diagnostics IMPORT SimpleCode,Severity;
FROM ErrorCodes IMPORT EOptionUnknown,EOptionValue,EMissingInput,ETooManySearchPaths,ETooManyLibraries,EArgumentTooLong;

VAR ArgFailure:BOOLEAN;

PROCEDURE PrintVersion;
BEGIN
    WriteString('Hilbert 1.0.0'); NewLine;
    WriteString('bootstrap compiler, x86-64 Linux'); NewLine
END PrintVersion;

PROCEDURE PrintTargets;
BEGIN
    WriteString('target                 status'); NewLine;
    WriteString('  x86_64-linux-gnu     native ELF, SysV AMD64'); NewLine;
    WriteString('  aarch64-linux-gnu    front end only'); NewLine
END PrintTargets;

PROCEDURE PrintHelp;
BEGIN
    WriteString('Hilbert 1.0.0'); NewLine;
    WriteString('compiler for the Hilbert language'); NewLine;
    NewLine;
    WriteString('usage:'); NewLine;
    WriteString('  hilbert <command> <file> [options]'); NewLine;
    WriteString('  hilbert <file> [options]'); NewLine;
    NewLine;
    WriteString('commands:'); NewLine;
    WriteString('  build       compile and link a native program (default)'); NewLine;
    WriteString('  check       parse and type-check only'); NewLine;
    WriteString('  emit-asm    write generated assembly'); NewLine;
    WriteString('  emit-obj    write a native object file'); NewLine;
    WriteString('  dump-ast    print the parsed syntax tree'); NewLine;
    WriteString('  dump-hir    print typed Hilbert IR'); NewLine;
    WriteString('  graph       print the checked module dependency graph'); NewLine;
    WriteString('  targets     list known compilation targets'); NewLine;
    WriteString('  help        show this help'); NewLine;
    WriteString('  version     show compiler version'); NewLine;
    NewLine;
    WriteString('output and optimization:'); NewLine;
    WriteString('  -o <file>            set output file'); NewLine;
    WriteString('  -O0, -O1, -O2, -O3  optimization level'); NewLine;
    WriteString('  -Os                  optimize for size'); NewLine;
    WriteString('  -g                   keep debug-oriented labels'); NewLine;
    WriteString('  --static             request a static final link'); NewLine;
    WriteString('  --strip              strip the final executable'); NewLine;
    NewLine;
    WriteString('paths and linking:'); NewLine;
    WriteString('  -I <dir>, -Idir      add module search path'); NewLine;
    WriteString('  -L <dir>, -Ldir      add native library path'); NewLine;
    WriteString('  -l <name>, -lname    link a native library'); NewLine;
    WriteString('  --no-stdlib          skip bundled stdlib and bindings'); NewLine;
    WriteString('  --toolchain-root <dir>  use another installed Hilbert tree'); NewLine;
    WriteString('  --target <triple>    set compilation target'); NewLine;
    WriteString('  --profile <name>     select debug, release, or size conditions'); NewLine;
    WriteString('  --runtime <name>     select hosted or freestanding conditions'); NewLine;
    WriteString('  --sysroot <dir>      set linker sysroot'); NewLine;
    NewLine;
    WriteString('build control:'); NewLine;
    WriteString('  --incremental        reuse cached module objects (default)'); NewLine;
    WriteString('  --no-incremental     rebuild native objects'); NewLine;
    WriteString('  --cache-dir <dir>    set object cache directory'); NewLine;
    WriteString('  --keep-temps         keep generated assembly'); NewLine;
    WriteString('  --no-cache           rebuild native objects'); NewLine;
    WriteString('  --explain            explain cache misses'); NewLine;
    WriteString('  --trace              show commands, cache decisions, and dependencies'); NewLine;
    WriteString('  -j <n>, --jobs <n>   reserve native build jobs (dependency work remains ordered)'); NewLine;
    NewLine;
    WriteString('diagnostics:'); NewLine;
    WriteString('  -v                   print compiler and linker commands'); NewLine;
    WriteString('  --quiet              suppress build notes'); NewLine;
    WriteString('  --color <mode>       diagnostic color: auto, always, or never'); NewLine;
    WriteString('  --no-color           alias for --color never'); NewLine;
    WriteString('  -Werror              treat warnings as errors'); NewLine;
    WriteString('  --error-limit <n>    stop after n errors (default 50)'); NewLine;
    WriteString('  --no-summary         omit final diagnostic counts'); NewLine;
    NewLine;
    WriteString('examples:'); NewLine;
    WriteString('  hilbert hello.hil'); NewLine;
    WriteString('  hilbert check src/Main.hil'); NewLine;
    WriteString('  hilbert build src/Main.hil -O3 -o build/app'); NewLine
END PrintHelp;

PROCEDURE AddModulePath(VAR S:Settings; P:ARRAY OF CHAR):BOOLEAN;
BEGIN
    IF S.ModulePathCount>=MaxSearchPaths THEN SimpleCode(Error,ETooManySearchPaths,'too many -I paths'); RETURN FALSE END;
    Assign(S.ModulePaths[S.ModulePathCount],P); INC(S.ModulePathCount); RETURN TRUE
END AddModulePath;
PROCEDURE AddLibraryPath(VAR S:Settings; P:ARRAY OF CHAR):BOOLEAN;
BEGIN
    IF S.LibraryPathCount>=MaxSearchPaths THEN SimpleCode(Error,ETooManySearchPaths,'too many -L paths'); RETURN FALSE END;
    Assign(S.LibraryPaths[S.LibraryPathCount],P); INC(S.LibraryPathCount); RETURN TRUE
END AddLibraryPath;
PROCEDURE AddLibrary(VAR S:Settings; P:ARRAY OF CHAR):BOOLEAN;
BEGIN
    IF S.LinkLibraryCount>=MaxLinkLibraries THEN SimpleCode(Error,ETooManyLibraries,'too many -l libraries'); RETURN FALSE END;
    Assign(S.LinkLibraries[S.LinkLibraryCount],P); INC(S.LinkLibraryCount); RETURN TRUE
END AddLibrary;


PROCEDURE FetchArg(VAR A:Text; I:CARDINAL);
VAR S:DynamicStrings.String; N:CARDINAL;
BEGIN
    A[0]:=0C;
    IF NOT SArgs.GetArg(S,I) THEN RETURN END;
    N:=DynamicStrings.Length(S);
    IF N>HIGH(A) THEN
        DynamicStrings.Fin(S); ArgFailure:=TRUE;
        SimpleCode(Error,EArgumentTooLong,'command-line argument exceeds 1023 bytes'); RETURN
    END;
    DynamicStrings.CopyOut(A,S); DynamicStrings.Fin(S)
END FetchArg;

PROCEDURE AutoColor():BOOLEAN;
VAR Dummy:Text;
BEGIN
    IF GetEnvironment('NO_COLOR',Dummy) THEN RETURN FALSE END;
    RETURN isatty(2)#0
END AutoColor;

PROCEDURE NeedValue(VAR I,N:CARDINAL; Opt:ARRAY OF CHAR):BOOLEAN;
BEGIN
    INC(I); IF I>N THEN SimpleCode(Error,EOptionValue,Opt); RETURN FALSE END; RETURN TRUE
END NeedValue;

PROCEDURE Parse(VAR S:Settings):BOOLEAN;
VAR I,N:CARDINAL; A,V:Text;
BEGIN
    S.Cmd:=CmdHelp; S.Input[0]:=0C; S.Output[0]:=0C; Assign(S.Target,'x86_64-linux-gnu'); S.Sysroot[0]:=0C; Assign(S.CacheDir,'build/.hilbert');
    Assign(S.Profile,'release'); Assign(S.Runtime,'hosted');
    S.ToolchainRoot[0]:=0C; IF NOT GetEnvironment('HILBERT_HOME',S.ToolchainRoot) THEN S.ToolchainRoot[0]:=0C END;
    S.ModulePathCount:=0; S.LibraryPathCount:=0; S.LinkLibraryCount:=0; S.Opt:=O2; S.ErrorLimit:=50; S.Jobs:=1;
    S.StaticLink:=FALSE; S.Strip:=FALSE; S.KeepTemps:=FALSE; S.Color:=AutoColor(); S.DebugInfo:=FALSE; S.Verbose:=FALSE; S.NoStdlib:=FALSE;
    S.Incremental:=TRUE; S.WarningsAsErrors:=FALSE; S.Quiet:=FALSE; S.ShowSummary:=TRUE; S.Explain:=FALSE; S.Trace:=FALSE; S.GraphDot:=FALSE; S.GraphCount:=FALSE; S.Progress:=FALSE;
    ArgFailure:=FALSE; N:=SArgs.Narg();
    IF N>0 THEN DEC(N) END;  (* Args.Narg includes argv[0]. *)
    IF N=0 THEN RETURN TRUE END;
    FetchArg(A,1); IF ArgFailure THEN RETURN FALSE END;
    IF Equal(A,'--help') OR Equal(A,'-h') OR Equal(A,'help') THEN S.Cmd:=CmdHelp; RETURN TRUE END;
    IF Equal(A,'--version') OR Equal(A,'-V') OR Equal(A,'version') THEN S.Cmd:=CmdVersion; RETURN TRUE END;
    IF Equal(A,'targets') THEN S.Cmd:=CmdTargets; RETURN TRUE END;
    IF Equal(A,'build') THEN S.Cmd:=CmdBuild
    ELSIF Equal(A,'check') THEN S.Cmd:=CmdCheck
    ELSIF Equal(A,'emit-asm') THEN S.Cmd:=CmdEmitAsm
    ELSIF Equal(A,'emit-obj') THEN S.Cmd:=CmdEmitObj
    ELSIF Equal(A,'dump-ast') THEN S.Cmd:=CmdDumpAST
    ELSIF Equal(A,'dump-hir') THEN S.Cmd:=CmdDumpHIR
    ELSIF Equal(A,'graph') THEN S.Cmd:=CmdGraph
    ELSIF A[0]='-' THEN SimpleCode(Error,EOptionUnknown,A); RETURN FALSE
    ELSE S.Cmd:=CmdBuild; Assign(S.Input,A)
    END;
    I:=2;
    IF S.Input[0]=0C THEN
        IF I>N THEN SimpleCode(Error,EMissingInput,'missing input file'); RETURN FALSE END;
        FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END; Assign(S.Input,A); INC(I)
    END;
    WHILE I<=N DO
        FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END;
        IF Equal(A,'-o') THEN
            IF NOT NeedValue(I,N,'-o requires a file') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END; Assign(S.Output,A)
        ELSIF Equal(A,'-O0') THEN S.Opt:=O0
        ELSIF Equal(A,'-O1') THEN S.Opt:=O1
        ELSIF Equal(A,'-O2') THEN S.Opt:=O2
        ELSIF Equal(A,'-O3') THEN S.Opt:=O3
        ELSIF Equal(A,'-Os') THEN S.Opt:=Os
        ELSIF Equal(A,'--static') THEN S.StaticLink:=TRUE
        ELSIF Equal(A,'--strip') THEN S.Strip:=TRUE
        ELSIF Equal(A,'--keep-temps') THEN S.KeepTemps:=TRUE
        ELSIF Equal(A,'--incremental') THEN S.Incremental:=TRUE
        ELSIF Equal(A,'--no-incremental') THEN S.Incremental:=FALSE
        ELSIF Equal(A,'--no-cache') THEN S.Incremental:=FALSE
        ELSIF Equal(A,'--explain') THEN S.Explain:=TRUE
        ELSIF Equal(A,'--trace') THEN S.Trace:=TRUE; S.Verbose:=TRUE; S.Explain:=TRUE
        ELSIF Equal(A,'--dot') THEN S.GraphDot:=TRUE
        ELSIF Equal(A,'--count') THEN S.GraphCount:=TRUE
        ELSIF Equal(A,'--progress') THEN S.Progress:=TRUE
        ELSIF Equal(A,'--no-color') THEN S.Color:=FALSE
        ELSIF Equal(A,'--color') THEN
            IF NOT NeedValue(I,N,'--color requires auto, always, or never') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END;
            IF Equal(A,'auto') THEN S.Color:=AutoColor() ELSIF Equal(A,'always') THEN S.Color:=TRUE ELSIF Equal(A,'never') THEN S.Color:=FALSE ELSE SimpleCode(Error,EOptionValue,'--color requires auto, always, or never'); RETURN FALSE END
        ELSIF Equal(A,'--no-stdlib') THEN S.NoStdlib:=TRUE
        ELSIF Equal(A,'--quiet') THEN S.Quiet:=TRUE
        ELSIF Equal(A,'--no-summary') THEN S.ShowSummary:=FALSE
        ELSIF Equal(A,'-Werror') THEN S.WarningsAsErrors:=TRUE
        ELSIF Equal(A,'-g') THEN S.DebugInfo:=TRUE
        ELSIF Equal(A,'-v') THEN S.Verbose:=TRUE
        ELSIF Equal(A,'-vv') THEN S.Verbose:=TRUE; S.Explain:=TRUE
        ELSIF Equal(A,'-j') OR Equal(A,'--jobs') THEN
            IF NOT NeedValue(I,N,'--jobs requires a positive number') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END;
            IF NOT ParseCard(A,S.Jobs) OR (S.Jobs=0) OR (S.Jobs>8) THEN SimpleCode(Error,EOptionValue,'jobs must be between 1 and 8'); RETURN FALSE END
        ELSIF Equal(A,'--target') THEN
            IF NOT NeedValue(I,N,'--target requires a triple') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END; Assign(S.Target,A)
        ELSIF Equal(A,'--profile') THEN
            IF NOT NeedValue(I,N,'--profile requires debug, release, or size') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END;
            IF Equal(A,'debug') THEN Assign(S.Profile,A); S.Opt:=O0; S.DebugInfo:=TRUE
            ELSIF Equal(A,'release') THEN Assign(S.Profile,A); S.Opt:=O3
            ELSIF Equal(A,'size') THEN Assign(S.Profile,A); S.Opt:=Os
            ELSE SimpleCode(Error,EOptionValue,'unknown build profile; expected debug, release, or size'); RETURN FALSE
            END
        ELSIF Equal(A,'--runtime') THEN
            IF NOT NeedValue(I,N,'--runtime requires hosted or freestanding') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END;
            IF Equal(A,'hosted') OR Equal(A,'freestanding') THEN Assign(S.Runtime,A)
            ELSE SimpleCode(Error,EOptionValue,'unknown runtime profile; expected hosted or freestanding'); RETURN FALSE
            END
        ELSIF Equal(A,'--sysroot') THEN
            IF NOT NeedValue(I,N,'--sysroot requires a directory') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END; Assign(S.Sysroot,A)
        ELSIF Equal(A,'--cache-dir') THEN
            IF NOT NeedValue(I,N,'--cache-dir requires a directory') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END; Assign(S.CacheDir,A)
        ELSIF Equal(A,'--toolchain-root') THEN
            IF NOT NeedValue(I,N,'--toolchain-root requires a directory') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END; Assign(S.ToolchainRoot,A)
        ELSIF Equal(A,'--error-limit') THEN
            IF NOT NeedValue(I,N,'--error-limit requires a number') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END; IF NOT ParseCard(A,S.ErrorLimit) THEN SimpleCode(Error,EOptionValue,'invalid --error-limit value'); RETURN FALSE END
        ELSIF Equal(A,'-I') THEN
            IF NOT NeedValue(I,N,'-I requires a directory') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END; IF NOT AddModulePath(S,A) THEN RETURN FALSE END
        ELSIF Equal(A,'-L') THEN
            IF NOT NeedValue(I,N,'-L requires a directory') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END; IF NOT AddLibraryPath(S,A) THEN RETURN FALSE END
        ELSIF Equal(A,'-l') THEN
            IF NOT NeedValue(I,N,'-l requires a library name') THEN RETURN FALSE END; FetchArg(A,I); IF ArgFailure THEN RETURN FALSE END; IF NOT AddLibrary(S,A) THEN RETURN FALSE END
        ELSIF StartsWith(A,'-I') THEN Slice(A,2,V); IF NOT AddModulePath(S,V) THEN RETURN FALSE END
        ELSIF StartsWith(A,'-L') THEN Slice(A,2,V); IF NOT AddLibraryPath(S,V) THEN RETURN FALSE END
        ELSIF StartsWith(A,'-l') THEN Slice(A,2,V); IF NOT AddLibrary(S,V) THEN RETURN FALSE END
        ELSE SimpleCode(Error,EOptionUnknown,A); RETURN FALSE
        END;
        INC(I)
    END;
    RETURN TRUE
END Parse;

END Options.
