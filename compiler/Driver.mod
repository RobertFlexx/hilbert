IMPLEMENTATION MODULE Driver;

FROM SYSTEM IMPORT ADR;
FROM libc IMPORT system;
FROM FIO IMPORT Exists;
IMPORT FIO, Source, Lexer, AST, Parser, Divisions, Semantics, BorrowCheck, Lower, Optimize, Verify, HIR, Diagnostics, HStrings, Target, GenericProcedures;
FROM AST IMPORT NodeId,Node,NodeKind;
FROM Options IMPORT Settings,Command;
FROM HStrings IMPORT Text,Assign,Append,ReplaceExtension,BaseName,Equal,Length,AppendChar,StartsWith,NewLine;
FROM Diagnostics IMPORT Simple,SimpleCode,Severity;
FROM ErrorCodes IMPORT EModuleGraphLimit,EImportLimit,EForeignLibraryLimit,ECircularImport,EModuleNotFound,EModuleChanged,EAssemblerFailed,ELinkerFailed,EUnknownTarget,EBackendTarget,EBuildDirectory,ERuntimeBuild,ECommandTooLong;
FROM StrIO IMPORT WriteString;
FROM NumberIO IMPORT WriteCard;
FROM X64 IMPORT EmitAssembly;

CONST
    MaxModules=4096;
    MaxImports=512;
    MaxCommand=32767;
    MaxAutoLibraries=256;
    MaxParallelJobs=8;

TYPE
    ModuleState=(ModNone,ModCompiling,ModDone);
    ModuleRec=RECORD Name,Path,DefinitionPath,AsmPath,ObjPath:Text; State:ModuleState; Cached,IsMain:BOOLEAN END;
    CommandText=ARRAY [0..MaxCommand] OF CHAR;
    ImportArray=ARRAY [0..MaxImports-1] OF Text;
    LibraryArray=ARRAY [0..MaxAutoLibraries-1] OF Text;
    JobArray=ARRAY [0..MaxParallelJobs-1] OF CommandText;

VAR
    Modules:ARRAY [0..MaxModules-1] OF ModuleRec;
    ModuleCount:CARDINAL;
    AutoLibraries:LibraryArray;
    AutoLibraryCount:CARDINAL;
    RuntimeObject:Text;
    RuntimeNeeded:BOOLEAN;
    AssemblyJobs:JobArray;
    AssemblyJobLogs,AssemblyJobStamps,AssemblyJobFingerprints:ARRAY [0..MaxParallelJobs-1] OF Text;
    AssemblyJobCount:CARDINAL;
    PlanNames:ARRAY [0..MaxModules-1] OF Text;
    PlanStates:ARRAY [0..MaxModules-1] OF ModuleState;
    PlanModuleCount,ProcessedModuleCount:CARDINAL;
    CommandOverflow:BOOLEAN;

PROCEDURE Shell(VAR Cmd:ARRAY OF CHAR):INTEGER;
BEGIN
    IF CommandOverflow THEN SimpleCode(Error,ECommandTooLong,'generated native command exceeds 32767 bytes'); RETURN 2 END;
    RETURN system(ADR(Cmd))
END Shell;

PROCEDURE BigClear(VAR S:CommandText);
BEGIN S[0]:=0C; CommandOverflow:=FALSE END BigClear;

PROCEDURE BigAppend(VAR Dst:CommandText; Src:ARRAY OF CHAR);
VAR I,J:CARDINAL;
BEGIN
    I:=0; WHILE (I<=HIGH(Dst)) AND (Dst[I]#0C) DO INC(I) END; J:=0;
    WHILE (I<HIGH(Dst)) AND (J<=HIGH(Src)) AND (Src[J]#0C) DO Dst[I]:=Src[J]; INC(I); INC(J) END;
    Dst[I]:=0C;
    IF (J<=HIGH(Src)) AND (Src[J]#0C) THEN CommandOverflow:=TRUE END
END BigAppend;

PROCEDURE CommandChar(VAR Dst:CommandText; C:CHAR);
VAR I:CARDINAL;
BEGIN
    I:=0; WHILE (I<=HIGH(Dst)) AND (Dst[I]#0C) DO INC(I) END;
    IF I<HIGH(Dst) THEN Dst[I]:=C; Dst[I+1]:=0C ELSE CommandOverflow:=TRUE END
END CommandChar;

PROCEDURE BigLength(VAR S:CommandText):CARDINAL;
VAR I:CARDINAL;
BEGIN I:=0; WHILE (I<=HIGH(S)) AND (S[I]#0C) DO INC(I) END; RETURN I END BigLength;

PROCEDURE QuoteAppend(VAR Dst:CommandText; S:ARRAY OF CHAR);
VAR I:CARDINAL;
BEGIN
    (* POSIX single-quote escaping. Paths with an apostrophe are unusual, not illegal. *)
    CommandChar(Dst,VAL(CHAR,39)); I:=0;
    WHILE (I<=HIGH(S)) AND (S[I]#0C) DO
        IF S[I]=VAL(CHAR,39) THEN
            CommandChar(Dst,VAL(CHAR,39)); CommandChar(Dst,'"'); CommandChar(Dst,VAL(CHAR,39)); CommandChar(Dst,'"'); CommandChar(Dst,VAL(CHAR,39))
        ELSE CommandChar(Dst,S[I])
        END;
        INC(I)
    END;
    CommandChar(Dst,VAL(CHAR,39))
END QuoteAppend;

PROCEDURE Directory(Path:ARRAY OF CHAR; VAR Out:Text);
VAR I,N,Last:CARDINAL;
BEGIN
    Out[0]:=0C; N:=Length(Path); Last:=0; I:=0;
    WHILE I<N DO IF Path[I]='/' THEN Last:=I+1 END; INC(I) END;
    I:=0; WHILE (I<Last) AND (I<HIGH(Out)) DO Out[I]:=Path[I]; INC(I) END; Out[I]:=0C
END Directory;

PROCEDURE ModuleFileName(Name:ARRAY OF CHAR; VAR Out:Text);
VAR I:CARDINAL; C:CHAR;
BEGIN
    Out[0]:=0C; I:=0;
    WHILE (I<=HIGH(Name)) AND (Name[I]#0C) DO
        C:=Name[I]; IF C='.' THEN C:='/' END; AppendChar(Out,C); INC(I)
    END;
    Append(Out,'.hil')
END ModuleFileName;

PROCEDURE FindDefinitionPath(Implementation:ARRAY OF CHAR; VAR Out:Text):BOOLEAN;
VAR N:CARDINAL;
BEGIN
    Assign(Out,Implementation); N:=Length(Out);
    IF (N<4) OR (Out[N-4]#'.') OR (Out[N-3]#'h') OR (Out[N-2]#'i') OR (Out[N-1]#'l') THEN Out[0]:=0C; RETURN FALSE END;
    Out[N-4]:=0C; Append(Out,'.def.hil'); IF Exists(Out) THEN RETURN TRUE END; Out[0]:=0C; RETURN FALSE
END FindDefinitionPath;

PROCEDURE SafeModuleName(Name:ARRAY OF CHAR; VAR Out:Text);
VAR I:CARDINAL; C:CHAR;
BEGIN
    Out[0]:=0C; I:=0;
    WHILE (I<=HIGH(Name)) AND (Name[I]#0C) DO
        C:=Name[I]; IF (C='.') OR (C='/') THEN C:='_' END; AppendChar(Out,C); INC(I)
    END
END SafeModuleName;

PROCEDURE ScanRuntimeTree(Id:NodeId);
VAR I:NodeId; N:Node;
BEGIN
    I:=Id;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF (N.Kind=NNew) OR (N.Kind=NStart) OR (N.Kind=NAwait) OR (N.Kind=NParallel) THEN RuntimeNeeded:=TRUE END;
        IF (N.Kind=NForeign) AND (StartsWith(N.Text,'hilbert_gc_') OR StartsWith(N.Text,'hilbert_rt_')) THEN RuntimeNeeded:=TRUE END;
        ScanRuntimeTree(N.A); ScanRuntimeTree(N.B); ScanRuntimeTree(N.C); ScanRuntimeTree(N.D); I:=N.Next
    END
END ScanRuntimeTree;

PROCEDURE ScanRuntimeNeeds(Root:NodeId);
BEGIN ScanRuntimeTree(Root) END ScanRuntimeNeeds;

PROCEDURE JoinPath(Dir,Rel:ARRAY OF CHAR; VAR Out:Text);
BEGIN
    Assign(Out,Dir); IF (Length(Out)>0) AND (Out[Length(Out)-1]#'/') THEN Append(Out,'/') END; Append(Out,Rel)
END JoinPath;

PROCEDURE FindModule(Name,FromPath:ARRAY OF CHAR; VAR S:Settings; VAR Path:Text):BOOLEAN;
VAR Rel,Dir:Text; I:CARDINAL;
BEGIN
    ModuleFileName(Name,Rel); Directory(FromPath,Dir);
    Assign(Path,Dir); Append(Path,Rel); IF Exists(Path) THEN RETURN TRUE END;
    Assign(Path,Rel); IF Exists(Path) THEN RETURN TRUE END;
    I:=0; WHILE I<S.ModulePathCount DO JoinPath(S.ModulePaths[I],Rel,Path); IF Exists(Path) THEN RETURN TRUE END; INC(I) END;
    IF NOT S.NoStdlib THEN
        (* Source checkout first, then the installed toolchain tree.  Bindings live in the
           same public import namespace as the stdlib, but keep the old bindings/ lookup
           for source trees and older installs. *)
        Assign(Path,'stdlib/'); Append(Path,Rel); IF Exists(Path) THEN RETURN TRUE END;
        Assign(Path,'bindings/'); Append(Path,Rel); IF Exists(Path) THEN RETURN TRUE END;
        IF S.ToolchainRoot[0]#0C THEN
            JoinPath(S.ToolchainRoot,'stdlib',Dir); JoinPath(Dir,Rel,Path); IF Exists(Path) THEN RETURN TRUE END;
            JoinPath(S.ToolchainRoot,'bindings',Dir); JoinPath(Dir,Rel,Path); IF Exists(Path) THEN RETURN TRUE END
        END;
        Assign(Path,'/usr/local/share/hilbert/stdlib/'); Append(Path,Rel); IF Exists(Path) THEN RETURN TRUE END;
        Assign(Path,'/usr/local/share/hilbert/bindings/'); Append(Path,Rel); IF Exists(Path) THEN RETURN TRUE END;
        Assign(Path,'/usr/share/hilbert/stdlib/'); Append(Path,Rel); IF Exists(Path) THEN RETURN TRUE END;
        Assign(Path,'/usr/share/hilbert/bindings/'); Append(Path,Rel); IF Exists(Path) THEN RETURN TRUE END
    END;
    RETURN FALSE
END FindModule;

PROCEDURE FindRecorded(Name:ARRAY OF CHAR):INTEGER;
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<ModuleCount DO IF Equal(Modules[I].Name,Name) THEN RETURN VAL(INTEGER,I) END; INC(I) END; RETURN -1 END FindRecorded;

PROCEDURE AddRecorded(Name,Path:ARRAY OF CHAR):INTEGER;
VAR I:INTEGER;
BEGIN
    I:=FindRecorded(Name); IF I>=0 THEN RETURN I END;
    IF ModuleCount>=MaxModules THEN SimpleCode(Fatal,EModuleGraphLimit,'module graph limit exceeded'); RETURN -1 END;
    Assign(Modules[ModuleCount].Name,Name); Assign(Modules[ModuleCount].Path,Path); Modules[ModuleCount].DefinitionPath[0]:=0C; Modules[ModuleCount].AsmPath[0]:=0C; Modules[ModuleCount].ObjPath[0]:=0C; Modules[ModuleCount].Cached:=FALSE; Modules[ModuleCount].IsMain:=FALSE; Modules[ModuleCount].State:=ModCompiling;
    I:=VAL(INTEGER,ModuleCount); INC(ModuleCount); RETURN I
END AddRecorded;

PROCEDURE MakeAsmPath(Name,Dir:ARRAY OF CHAR; VAR Path:Text);
VAR Safe:Text;
BEGIN SafeModuleName(Name,Safe); Assign(Path,Dir); IF (Length(Path)>0) AND (Path[Length(Path)-1]#'/') THEN Append(Path,'/') END; Append(Path,Safe); Append(Path,'.s') END MakeAsmPath;

PROCEDURE MakeObjPath(Name,Dir:ARRAY OF CHAR; IsMain:BOOLEAN; VAR S:Settings; VAR Path:Text);
VAR Safe,SafeTarget,SafeProfile,SafeRuntime:Text;
BEGIN
    SafeModuleName(Name,Safe); SafeModuleName(S.Target,SafeTarget); SafeModuleName(S.Profile,SafeProfile); SafeModuleName(S.Runtime,SafeRuntime);
    Assign(Path,Dir); IF (Length(Path)>0) AND (Path[Length(Path)-1]#'/') THEN Append(Path,'/') END;
    (* bump this when codegen changes. old objects can be wrong even when the
       source, target and optimization level did not move. *)
    Append(Path,Safe); Append(Path,'.v31.'); Append(Path,SafeTarget); Append(Path,'.'); Append(Path,SafeProfile); Append(Path,'.'); Append(Path,SafeRuntime);
    IF IsMain THEN Append(Path,'.main.') ELSE Append(Path,'.module.') END;
    CASE S.Opt OF
    | 0:Append(Path,'O0')
    | 1:Append(Path,'O1')
    | 2:Append(Path,'O2')
    | 3:Append(Path,'O3')
    | 4:Append(Path,'Os')
    ELSE Append(Path,'O2')
    END;
    IF S.DebugInfo THEN Append(Path,'.g') END;
    Append(Path,'.o')
END MakeObjPath;

PROCEDURE NewerThan(Newer,Older:ARRAY OF CHAR):BOOLEAN;
VAR Cmd:CommandText; R:INTEGER;
BEGIN
    BigClear(Cmd); BigAppend(Cmd,'test '); QuoteAppend(Cmd,Newer); BigAppend(Cmd,' -nt '); QuoteAppend(Cmd,Older); R:=Shell(Cmd); RETURN R=0
END NewerThan;

PROCEDURE CacheInputStamp(ObjPath:ARRAY OF CHAR; VAR Stamp:Text);
BEGIN Assign(Stamp,ObjPath); Append(Stamp,'.inputs') END CacheInputStamp;

PROCEDURE MixFingerprint(VAR A,B:CARDINAL; C:CARDINAL);
BEGIN
    A:=(A*257+C+1) MOD 2147483629; B:=(B*263+C+1) MOD 2147483587
END MixFingerprint;

PROCEDURE FingerprintFile(Path:ARRAY OF CHAR; VAR A,B:CARDINAL):BOOLEAN;
VAR F:FIO.File; C:CHAR; I:CARDINAL;
BEGIN
    I:=0; WHILE (I<=HIGH(Path)) AND (Path[I]#0C) DO MixFingerprint(A,B,ORD(Path[I])); INC(I) END; MixFingerprint(A,B,255);
    F:=FIO.OpenToRead(Path); IF NOT FIO.IsNoError(F) THEN FIO.Close(F); RETURN FALSE END;
    WHILE NOT FIO.EOF(F) DO C:=FIO.ReadChar(F); IF NOT FIO.EOF(F) OR (C#0C) THEN MixFingerprint(A,B,ORD(C)) END END;
    FIO.Close(F); MixFingerprint(A,B,254); RETURN TRUE
END FingerprintFile;

PROCEDURE SmallCardText(Value:CARDINAL; VAR Out:Text);
VAR D:ARRAY[0..31] OF CHAR; N,I:CARDINAL;
BEGIN
    IF Value=0 THEN Assign(Out,'0'); RETURN END; N:=0;
    WHILE Value>0 DO D[N]:=VAL(CHAR,ORD('0')+(Value MOD 10)); INC(N); Value:=Value DIV 10 END;
    I:=0; WHILE N>0 DO DEC(N); Out[I]:=D[N]; INC(I) END; Out[I]:=0C
END SmallCardText;

PROCEDURE InputFingerprint(SourcePath,DefinitionPath:ARRAY OF CHAR; VAR Imports:ImportArray; ImportCount:CARDINAL; VAR Out:Text):BOOLEAN;
VAR A,B,I:CARDINAL; D:INTEGER; N:Text;
BEGIN
    A:=17; B:=29; IF NOT FingerprintFile(SourcePath,A,B) THEN RETURN FALSE END;
    IF (DefinitionPath[0]#0C) AND NOT FingerprintFile(DefinitionPath,A,B) THEN RETURN FALSE END;
    I:=0;
    WHILE I<ImportCount DO
        D:=FindRecorded(Imports[I]);
        IF D>=0 THEN
            IF NOT FingerprintFile(Modules[D].Path,A,B) THEN RETURN FALSE END;
            IF (Modules[D].DefinitionPath[0]#0C) AND NOT FingerprintFile(Modules[D].DefinitionPath,A,B) THEN RETURN FALSE END
        END;
        INC(I)
    END;
    SmallCardText(A,Out); Append(Out,':'); SmallCardText(B,N); Append(Out,N); RETURN TRUE
END InputFingerprint;

PROCEDURE ReadFingerprint(Path:ARRAY OF CHAR; VAR Out:Text):BOOLEAN;
VAR F:FIO.File; C:CHAR; I:CARDINAL;
BEGIN
    F:=FIO.OpenToRead(Path); IF NOT FIO.IsNoError(F) THEN FIO.Close(F); RETURN FALSE END; I:=0;
    WHILE NOT FIO.EOF(F) DO C:=FIO.ReadChar(F); IF NOT FIO.EOF(F) OR (C#0C) THEN IF (C#12C) AND (C#15C) AND (I<HIGH(Out)) THEN Out[I]:=C; INC(I) END END END;
    Out[I]:=0C; FIO.Close(F); RETURN TRUE
END ReadFingerprint;

PROCEDURE WriteFingerprint(Path,Value:ARRAY OF CHAR):BOOLEAN;
VAR F:FIO.File;
BEGIN F:=FIO.OpenToWrite(Path); IF NOT FIO.IsNoError(F) THEN FIO.Close(F); RETURN FALSE END; FIO.WriteString(F,Value); FIO.WriteChar(F,12C); FIO.Close(F); RETURN TRUE END WriteFingerprint;

PROCEDURE CacheFresh(SourcePath,DefinitionPath,ObjPath:ARRAY OF CHAR; VAR Imports:ImportArray; ImportCount:CARDINAL):BOOLEAN;
VAR Stamp,Expected,Actual:Text;
BEGIN
    CacheInputStamp(ObjPath,Stamp); IF NOT Exists(ObjPath) OR NOT Exists(Stamp) THEN RETURN FALSE END;
    IF NOT InputFingerprint(SourcePath,DefinitionPath,Imports,ImportCount,Expected) THEN RETURN FALSE END;
    IF NOT ReadFingerprint(Stamp,Actual) THEN RETURN FALSE END; RETURN Equal(Expected,Actual)
END CacheFresh;

PROCEDURE SaveCacheInputs(SourcePath,DefinitionPath,ObjPath:ARRAY OF CHAR; VAR Imports:ImportArray; ImportCount:CARDINAL; VAR S:Settings):BOOLEAN;
VAR Stamp,Fingerprint:Text;
BEGIN
    CacheInputStamp(ObjPath,Stamp); IF NOT InputFingerprint(SourcePath,DefinitionPath,Imports,ImportCount,Fingerprint) THEN RETURN FALSE END;
    IF S.Trace THEN WriteString('hilbert: fingerprint '); WriteString(ObjPath); NewLine END; RETURN WriteFingerprint(Stamp,Fingerprint)
END SaveCacheInputs;

PROCEDURE FlushAssemblyJobs(VAR S:Settings):BOOLEAN;
VAR Cmd:CommandText; I:CARDINAL; N:Text; R:INTEGER;
BEGIN
    IF AssemblyJobCount=0 THEN RETURN TRUE END; BigClear(Cmd); I:=0;
    WHILE I<AssemblyJobCount DO
        BigAppend(Cmd,'( '); BigAppend(Cmd,AssemblyJobs[I]); BigAppend(Cmd,' ) > '); QuoteAppend(Cmd,AssemblyJobLogs[I]); BigAppend(Cmd,' 2>&1 & p'); SmallCardText(I,N); BigAppend(Cmd,N); BigAppend(Cmd,'=$!; '); INC(I)
    END;
    BigAppend(Cmd,'status=0; '); I:=0;
    WHILE I<AssemblyJobCount DO
        BigAppend(Cmd,'wait "$p'); SmallCardText(I,N); BigAppend(Cmd,N); BigAppend(Cmd,'" || { code=$?; status=$code; cat '); QuoteAppend(Cmd,AssemblyJobLogs[I]); BigAppend(Cmd,'; }; '); INC(I)
    END;
    BigAppend(Cmd,'rm -f -- '); I:=0; WHILE I<AssemblyJobCount DO QuoteAppend(Cmd,AssemblyJobLogs[I]); BigAppend(Cmd,' '); INC(I) END;
    BigAppend(Cmd,'; exit "$status"'); IF S.Trace THEN WriteString('hilbert: parallel native batch '); WriteCard(AssemblyJobCount,0); NewLine END;
    R:=Shell(Cmd);
    IF R#0 THEN AssemblyJobCount:=0; SimpleCode(Error,EAssemblerFailed,'one or more parallel native assembly jobs failed'); RETURN FALSE END;
    I:=0; WHILE I<AssemblyJobCount DO IF NOT WriteFingerprint(AssemblyJobStamps[I],AssemblyJobFingerprints[I]) THEN AssemblyJobCount:=0; SimpleCode(Error,EBuildDirectory,'cannot write parallel module cache metadata'); RETURN FALSE END; INC(I) END;
    AssemblyJobCount:=0; RETURN TRUE
END FlushAssemblyJobs;

PROCEDURE QueueAssembly(AsmPath,ObjPath,SourcePath,DefinitionPath:ARRAY OF CHAR; VAR Imports:ImportArray; ImportCount:CARDINAL; VAR S:Settings):BOOLEAN;
VAR Job:CommandText; Stamp,Fingerprint:Text;
BEGIN
    IF S.Jobs<=1 THEN
        IF NOT Assemble(AsmPath,ObjPath,S) THEN RETURN FALSE END;
        RETURN SaveCacheInputs(SourcePath,DefinitionPath,ObjPath,Imports,ImportCount,S)
    END;
    IF NOT InputFingerprint(SourcePath,DefinitionPath,Imports,ImportCount,Fingerprint) THEN RETURN FALSE END;
    BigClear(Job); BigAppend(Job,'cc -c -ffunction-sections -fdata-sections -o '); QuoteAppend(Job,ObjPath); BigAppend(Job,' '); QuoteAppend(Job,AsmPath);
    CacheInputStamp(ObjPath,Stamp);
    IF NOT S.KeepTemps THEN BigAppend(Job,' && rm -f -- '); QuoteAppend(Job,AsmPath) END;
    IF CommandOverflow THEN SimpleCode(Error,ECommandTooLong,'parallel assembler command exceeds 32767 bytes'); RETURN FALSE END;
    IF S.Verbose THEN WriteString('hilbert: exec  '); WriteString(Job); NewLine END;
    AssemblyJobs[AssemblyJobCount]:=Job; Assign(AssemblyJobLogs[AssemblyJobCount],AsmPath); Append(AssemblyJobLogs[AssemblyJobCount],'.job.log');
    Assign(AssemblyJobStamps[AssemblyJobCount],Stamp); Assign(AssemblyJobFingerprints[AssemblyJobCount],Fingerprint); INC(AssemblyJobCount);
    IF AssemblyJobCount>=S.Jobs THEN RETURN FlushAssemblyJobs(S) END; RETURN TRUE
END QueueAssembly;

PROCEDURE FindRuntimeSource(VAR S:Settings; VAR Path:Text):BOOLEAN;
VAR Dir:Text;
BEGIN
    Assign(Path,'runtime/hilbert_rt.c'); IF Exists(Path) THEN RETURN TRUE END;
    IF S.ToolchainRoot[0]#0C THEN
        JoinPath(S.ToolchainRoot,'runtime',Dir); JoinPath(Dir,'hilbert_rt.c',Path); IF Exists(Path) THEN RETURN TRUE END
    END;
    Assign(Path,'/usr/local/share/hilbert/runtime/hilbert_rt.c'); IF Exists(Path) THEN RETURN TRUE END;
    Assign(Path,'/usr/share/hilbert/runtime/hilbert_rt.c'); IF Exists(Path) THEN RETURN TRUE END;
    Path[0]:=0C; RETURN FALSE
END FindRuntimeSource;

PROCEDURE EnsureRuntime(VAR S:Settings):BOOLEAN;
VAR Src,Stamp,Expected,Actual:Text; Cmd:CommandText; R:INTEGER; NoImports:ImportArray;
BEGIN
    IF NOT FindRuntimeSource(S,Src) THEN SimpleCode(Error,ERuntimeBuild,'cannot find runtime/hilbert_rt.c'); RETURN FALSE END;
    Assign(RuntimeObject,S.CacheDir); IF (Length(RuntimeObject)>0) AND (RuntimeObject[Length(RuntimeObject)-1]#'/') THEN Append(RuntimeObject,'/') END;
    Append(RuntimeObject,'hilbert_rt.v4.'); Append(RuntimeObject,S.Target);
    CASE S.Opt OF
    | 0:Append(RuntimeObject,'.O0')
    | 1:Append(RuntimeObject,'.O1')
    | 2:Append(RuntimeObject,'.O2')
    | 3:Append(RuntimeObject,'.O3')
    | 4:Append(RuntimeObject,'.Os')
    END;
    Append(RuntimeObject,'.o');
    Assign(Stamp,RuntimeObject); Append(Stamp,'.inputs');
    IF Exists(RuntimeObject) AND Exists(Stamp) AND InputFingerprint(Src,'',NoImports,0,Expected) AND ReadFingerprint(Stamp,Actual) AND Equal(Expected,Actual) THEN RETURN TRUE END;
    BigClear(Cmd); BigAppend(Cmd,'cc -std=c11 ');
    CASE S.Opt OF
    | 0:BigAppend(Cmd,'-O0 ')
    | 4:BigAppend(Cmd,'-Os ')
    ELSE BigAppend(Cmd,'-O3 ')
    END;
    BigAppend(Cmd,'-pthread -fno-strict-aliasing -ffunction-sections -fdata-sections -c -o '); QuoteAppend(Cmd,RuntimeObject); BigAppend(Cmd,' '); QuoteAppend(Cmd,Src);
    IF S.Verbose THEN WriteString('hilbert: exec  '); WriteString(Cmd); NewLine END;
    R:=Shell(Cmd); IF R#0 THEN SimpleCode(Error,ERuntimeBuild,'failed to compile the Hilbert native runtime'); RETURN FALSE END;
    IF NOT InputFingerprint(Src,'',NoImports,0,Expected) OR NOT WriteFingerprint(Stamp,Expected) THEN SimpleCode(Error,ERuntimeBuild,'failed to write runtime cache metadata'); RETURN FALSE END;
    RETURN TRUE
END EnsureRuntime;

PROCEDURE Assemble(AsmPath,ObjPath:ARRAY OF CHAR; VAR S:Settings):BOOLEAN;
VAR Cmd:CommandText; R:INTEGER;
BEGIN
    BigClear(Cmd); BigAppend(Cmd,'cc -c -ffunction-sections -fdata-sections -o '); QuoteAppend(Cmd,ObjPath); BigAppend(Cmd,' '); QuoteAppend(Cmd,AsmPath);
    IF S.Verbose THEN WriteString('hilbert: exec  '); WriteString(Cmd); NewLine END; R:=Shell(Cmd);
    IF R#0 THEN SimpleCode(Error,EAssemblerFailed,'assembler failed'); RETURN FALSE END;
    IF NOT S.KeepTemps THEN BigClear(Cmd); BigAppend(Cmd,'rm -f '); QuoteAppend(Cmd,AsmPath); R:=Shell(Cmd) END;
    RETURN TRUE
END Assemble;

PROCEDURE SaveImports(Decl:NodeId; VAR Names:ImportArray; VAR Count:CARDINAL);
VAR I:NodeId; N:Node;
BEGIN
    I:=Decl;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF N.Kind=NImport THEN
            IF Count<=HIGH(Names) THEN Assign(Names[Count],N.Text); INC(Count)
            ELSE SimpleCode(Fatal,EImportLimit,'too many imports in module'); RETURN
            END
        ELSIF (N.Kind=NDivision) AND Divisions.Active(I,FALSE) THEN SaveImports(N.B,Names,Count)
        END;
        I:=N.Next
    END
END SaveImports;

PROCEDURE HasAutoLibrary(Name:ARRAY OF CHAR):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<AutoLibraryCount DO IF Equal(AutoLibraries[I],Name) THEN RETURN TRUE END; INC(I) END; RETURN FALSE END HasAutoLibrary;

PROCEDURE SaveLibraries(Decl:NodeId);
VAR I:NodeId; N:Node;
BEGIN
    I:=Decl;
    WHILE I#0 DO
        N:=AST.Get(I);
        IF (N.Kind=NForeignLibrary) AND NOT HasAutoLibrary(N.Text) THEN
            IF AutoLibraryCount>=MaxAutoLibraries THEN SimpleCode(Fatal,EForeignLibraryLimit,'too many foreign libraries in module graph'); RETURN END;
            Assign(AutoLibraries[AutoLibraryCount],N.Text); INC(AutoLibraryCount)
        ELSIF (N.Kind=NDivision) AND Divisions.Active(I,FALSE) THEN SaveLibraries(N.B)
        END;
        I:=N.Next
    END
END SaveLibraries;

PROCEDURE FindPlanned(Name:ARRAY OF CHAR):INTEGER;
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<PlanModuleCount DO IF Equal(PlanNames[I],Name) THEN RETURN VAL(INTEGER,I) END; INC(I) END; RETURN -1 END FindPlanned;

PROCEDURE DiscoverPlan(Path:ARRAY OF CHAR; VAR S:Settings):BOOLEAN;
VAR Root:NodeId; R:Node; Name,DefinitionPath,DepPath:Text; Imports:ImportArray; Count,I:CARDINAL; Existing,Index:INTEGER;
BEGIN
    IF NOT Source.Load(Path) THEN RETURN FALSE END; AST.Init; Lexer.Init; IF NOT Parser.Parse(Root) THEN RETURN FALSE END; R:=AST.Get(Root); Assign(Name,R.Text);
    Existing:=FindPlanned(Name);
    IF Existing>=0 THEN IF PlanStates[Existing]=ModCompiling THEN SimpleCode(Error,ECircularImport,'circular module import detected'); RETURN FALSE END; RETURN TRUE END;
    IF PlanModuleCount>=MaxModules THEN SimpleCode(Fatal,EModuleGraphLimit,'module graph limit exceeded'); RETURN FALSE END;
    Index:=VAL(INTEGER,PlanModuleCount); Assign(PlanNames[PlanModuleCount],Name); PlanStates[PlanModuleCount]:=ModCompiling; INC(PlanModuleCount);
    Count:=0; SaveImports(R.A,Imports,Count);
    IF NOT (0 IN R.Flags) AND FindDefinitionPath(Path,DefinitionPath) THEN
        IF NOT Source.Load(DefinitionPath) THEN RETURN FALSE END; AST.Init; Lexer.Init; IF NOT Parser.Parse(Root) THEN RETURN FALSE END; R:=AST.Get(Root); SaveImports(R.A,Imports,Count)
    END;
    I:=0;
    WHILE I<Count DO
        IF NOT FindModule(Imports[I],Path,S,DepPath) THEN SimpleCode(Error,EModuleNotFound,'imported module was not found'); RETURN FALSE END;
        IF NOT DiscoverPlan(DepPath,S) THEN RETURN FALSE END; INC(I)
    END;
    PlanStates[Index]:=ModDone; RETURN TRUE
END DiscoverPlan;

PROCEDURE PrintGraph(VAR S:Settings):BOOLEAN;
VAR I,J,Count:CARDINAL; Root:NodeId; R:Node; Imports:ImportArray;
BEGIN
    IF S.GraphCount THEN WriteString('modules: '); WriteCard(ModuleCount,0); NewLine; RETURN TRUE END;
    IF S.GraphDot THEN WriteString('digraph hilbert {'); NewLine END;
    I:=0;
    WHILE I<ModuleCount DO
        IF NOT Source.Load(Modules[I].Path) THEN RETURN FALSE END; AST.Init; Lexer.Init;
        IF NOT Parser.Parse(Root) THEN RETURN FALSE END; R:=AST.Get(Root); Count:=0; SaveImports(R.A,Imports,Count);
        IF S.GraphDot THEN
            IF Count=0 THEN WriteString('  "'); WriteString(R.Text); WriteString('";'); NewLine END;
            J:=0; WHILE J<Count DO WriteString('  "'); WriteString(R.Text); WriteString('" -> "'); WriteString(Imports[J]); WriteString('";'); NewLine; INC(J) END
        ELSE
            WriteString(R.Text); NewLine; J:=0;
            WHILE J<Count DO WriteString('  -> '); WriteString(Imports[J]); NewLine; INC(J) END
        END;
        INC(I)
    END;
    IF S.GraphDot THEN WriteString('}'); NewLine END;
    RETURN TRUE
END PrintGraph;

PROCEDURE ExplainRebuild(Name,SourcePath,DefinitionPath,ObjPath:ARRAY OF CHAR; VAR Imports:ImportArray; ImportCount:CARDINAL; VAR S:Settings);
VAR I:CARDINAL; D:INTEGER; Said:BOOLEAN;
BEGIN
    IF NOT S.Explain THEN RETURN END; WriteString(Name); WriteString(' rebuilt because:'); NewLine; Said:=FALSE;
    IF NOT S.Incremental THEN WriteString('  cache use is disabled'); NewLine; RETURN END;
    IF NOT Exists(ObjPath) THEN WriteString('  no object matches this compiler, target, profile, and runtime key'); NewLine; RETURN END;
    IF NewerThan(SourcePath,ObjPath) THEN WriteString('  '); WriteString(SourcePath); WriteString(' changed'); NewLine; Said:=TRUE END;
    IF (DefinitionPath[0]#0C) AND NewerThan(DefinitionPath,ObjPath) THEN WriteString('  definition module changed'); NewLine; Said:=TRUE END;
    I:=0;
    WHILE I<ImportCount DO
        D:=FindRecorded(Imports[I]);
        IF (D>=0) AND (NewerThan(Modules[D].Path,ObjPath) OR ((Modules[D].ObjPath[0]#0C) AND NewerThan(Modules[D].ObjPath,ObjPath))) THEN
            WriteString('  imports '); WriteString(Imports[I]); WriteString(', which changed'); NewLine; Said:=TRUE
        END;
        INC(I)
    END;
    IF NOT Said THEN WriteString('  dependency or cache metadata changed'); NewLine END
END ExplainRebuild;

PROCEDURE CompileOne(Path:ARRAY OF CHAR; IsMain,NeedCode:BOOLEAN; VAR S:Settings):BOOLEAN;
VAR Root:NodeId; R:Node; Imports:ImportArray; ImportCount,I:CARDINAL;
    Index,Existing:INTEGER; DepPath,AsmPath,ModuleName,DefinitionPath:Text; HasDefinition,InputIsDefinition,Fresh:BOOLEAN;
BEGIN
    (* First parse discovers the graph. Dependencies are compiled before semantic analysis so
       their typed public interfaces are available to this module. *)
    IF NOT Source.Load(Path) THEN RETURN FALSE END; AST.Init; Lexer.Init;
    IF NOT Parser.Parse(Root) THEN RETURN FALSE END; R:=AST.Get(Root); Assign(ModuleName,R.Text); InputIsDefinition:=0 IN R.Flags;
    Existing:=FindRecorded(ModuleName);
    IF Existing>=0 THEN
        IF Modules[Existing].State=ModCompiling THEN SimpleCode(Error,ECircularImport,'circular module import detected'); RETURN FALSE END;
        RETURN TRUE
    END;
    Index:=AddRecorded(ModuleName,Path); IF Index<0 THEN RETURN FALSE END;
    Modules[Index].IsMain:=IsMain;
    ImportCount:=0; SaveImports(R.A,Imports,ImportCount); SaveLibraries(R.A); HasDefinition:=FALSE; DefinitionPath[0]:=0C;
    IF NOT InputIsDefinition AND FindDefinitionPath(Path,DefinitionPath) THEN
        HasDefinition:=TRUE; Assign(Modules[Index].DefinitionPath,DefinitionPath);
        IF NOT Source.Load(DefinitionPath) THEN RETURN FALSE END; AST.Init; Lexer.Init;
        IF NOT Parser.Parse(Root) THEN RETURN FALSE END; R:=AST.Get(Root);
        IF NOT (0 IN R.Flags) OR NOT Equal(R.Text,ModuleName) THEN SimpleCode(Error,EModuleChanged,'definition and implementation module names do not match'); RETURN FALSE END;
        SaveImports(R.A,Imports,ImportCount); SaveLibraries(R.A)
    END;
    IF Diagnostics.HasErrors() THEN RETURN FALSE END;

    I:=0;
    WHILE I<ImportCount DO
        IF NOT FindModule(Imports[I],Path,S,DepPath) THEN SimpleCode(Error,EModuleNotFound,'imported module was not found'); WriteString('  module: '); WriteString(Imports[I]); NewLine; RETURN FALSE END;
        IF NOT CompileOne(DepPath,FALSE,NeedCode,S) THEN RETURN FALSE END; INC(I)
    END;

    IF HasDefinition THEN
        IF NOT Source.Load(DefinitionPath) THEN RETURN FALSE END; AST.Init; Lexer.Init;
        IF NOT Parser.Parse(Root) THEN RETURN FALSE END; R:=AST.Get(Root);
        IF NOT Semantics.Check(Root) THEN RETURN FALSE END
    END;

    (* Recursive compilation reuses the source/AST arenas, so reparse the current module. *)
    IF NOT Source.Load(Path) THEN RETURN FALSE END; AST.Init; Lexer.Init;
    IF NOT Parser.Parse(Root) THEN RETURN FALSE END; R:=AST.Get(Root);
    IF NOT Equal(R.Text,ModuleName) THEN SimpleCode(Error,EModuleChanged,'module name changed between graph and compile pass'); RETURN FALSE END;
    IF HasDefinition THEN IF NOT Semantics.CheckImplementation(Root) THEN RETURN FALSE END
    ELSE IF NOT Semantics.Check(Root) THEN RETURN FALSE END
    END;
    IF NOT BorrowCheck.Check(Root) THEN RETURN FALSE END;
    ScanRuntimeNeeds(Root);
    IF NeedCode THEN
        INC(ProcessedModuleCount);
        MakeObjPath(R.Text,S.CacheDir,IsMain,S,Modules[Index].ObjPath);
        Fresh:=S.Incremental AND CacheFresh(Path,Modules[Index].DefinitionPath,Modules[Index].ObjPath,Imports,ImportCount);
        IF Fresh THEN
            Modules[Index].Cached:=TRUE; IF S.Verbose THEN WriteString('hilbert: cache '); WriteString(R.Text); NewLine END
        ELSE
            ExplainRebuild(R.Text,Path,Modules[Index].DefinitionPath,Modules[Index].ObjPath,Imports,ImportCount,S);
            IF NOT S.Quiet THEN
                IF PlanModuleCount>0 THEN WriteString('['); WriteCard(ProcessedModuleCount,0); WriteString('/'); WriteCard(PlanModuleCount,0); WriteString('] ') END;
                WriteString('compile '); WriteString(R.Text); NewLine
            END;
            IF NOT Lower.Run(Root,IsMain) THEN RETURN FALSE END; Optimize.Run(S.Opt); IF NOT Verify.Run() THEN RETURN FALSE END; MakeAsmPath(R.Text,S.CacheDir,AsmPath);
            IF NOT EmitAssembly(AsmPath,S.DebugInfo) THEN RETURN FALSE END; Assign(Modules[Index].AsmPath,AsmPath);
            IF NOT QueueAssembly(AsmPath,Modules[Index].ObjPath,Path,Modules[Index].DefinitionPath,Imports,ImportCount,S) THEN RETURN FALSE END
        END
    END;
    Modules[Index].State:=ModDone; RETURN TRUE
END CompileOne;

PROCEDURE RecompileGenericOwner(Index:CARDINAL; NeedCode:BOOLEAN; VAR S:Settings):BOOLEAN;
VAR Root:NodeId; R:Node; AsmPath:Text; Imports:ImportArray; ImportCount:CARDINAL;
BEGIN
    IF Modules[Index].DefinitionPath[0]#0C THEN
        IF NOT Source.Load(Modules[Index].DefinitionPath) THEN RETURN FALSE END; AST.Init; Lexer.Init;
        IF NOT Parser.Parse(Root) THEN RETURN FALSE END; IF NOT Semantics.Check(Root) THEN RETURN FALSE END
    END;
    IF NOT Source.Load(Modules[Index].Path) THEN RETURN FALSE END; AST.Init; Lexer.Init;
    IF NOT Parser.Parse(Root) THEN RETURN FALSE END; R:=AST.Get(Root); ImportCount:=0; SaveImports(R.A,Imports,ImportCount);
    IF Modules[Index].DefinitionPath[0]#0C THEN IF NOT Semantics.CheckImplementation(Root) THEN RETURN FALSE END
    ELSE IF NOT Semantics.Check(Root) THEN RETURN FALSE END
    END;
    IF NOT BorrowCheck.Check(Root) THEN RETURN FALSE END; ScanRuntimeNeeds(Root);
    IF NeedCode THEN
        IF NOT Lower.Run(Root,Modules[Index].IsMain) THEN RETURN FALSE END; Optimize.Run(S.Opt); IF NOT Verify.Run() THEN RETURN FALSE END;
        MakeAsmPath(R.Text,S.CacheDir,AsmPath); IF NOT EmitAssembly(AsmPath,S.DebugInfo) THEN RETURN FALSE END;
        Assign(Modules[Index].AsmPath,AsmPath);
        IF NOT QueueAssembly(AsmPath,Modules[Index].ObjPath,Modules[Index].Path,Modules[Index].DefinitionPath,Imports,ImportCount,S) THEN RETURN FALSE END; Modules[Index].Cached:=FALSE
    END;
    GenericProcedures.MarkEmitted(Modules[Index].Name); RETURN TRUE
END RecompileGenericOwner;

PROCEDURE EmitGenericRequests(NeedCode:BOOLEAN; VAR S:Settings):BOOLEAN;
VAR I:CARDINAL; Progress:BOOLEAN;
BEGIN
    LOOP
        Progress:=FALSE; I:=0;
        WHILE I<ModuleCount DO
            IF GenericProcedures.NeedsEmission(Modules[I].Name) THEN IF NOT RecompileGenericOwner(I,NeedCode,S) THEN RETURN FALSE END; Progress:=TRUE END;
            INC(I)
        END;
        IF NOT Progress THEN RETURN TRUE END
    END
END EmitGenericRequests;

PROCEDURE CompileRootOnly(VAR S:Settings; WantHIR,WantAsm:BOOLEAN):INTEGER;
VAR Root:NodeId; Path,Obj:Text; Cmd:CommandText; R:INTEGER;
BEGIN
    Semantics.InitGraph;
    IF S.Cmd=CmdDumpAST THEN
        IF NOT Source.Load(S.Input) THEN RETURN 1 END; AST.Init; Lexer.Init;
        IF NOT Parser.Parse(Root) THEN RETURN 1 END; AST.Dump(Root); RETURN 0
    END;
    (* Typed and native root-only artifacts still need imported public
       interfaces.  Discover and check the graph without code generation,
       then reparse the root because recursive discovery reuses the AST arena. *)
    ModuleCount:=0; AutoLibraryCount:=0; RuntimeNeeded:=FALSE; AssemblyJobCount:=0; ProcessedModuleCount:=0; PlanModuleCount:=0;
    IF NOT CompileOne(S.Input,TRUE,FALSE,S) THEN RETURN 1 END;
    IF NOT Source.Load(S.Input) THEN RETURN 1 END; AST.Init; Lexer.Init;
    IF NOT Parser.Parse(Root) THEN RETURN 1 END;
    IF NOT Semantics.Check(Root) THEN RETURN 1 END;
    IF NOT BorrowCheck.Check(Root) THEN RETURN 1 END;
    IF S.Cmd=CmdCheck THEN RETURN 0 END;
    IF NOT Lower.Run(Root,TRUE) THEN RETURN 1 END; Optimize.Run(S.Opt); IF NOT Verify.Run() THEN RETURN 1 END;
    IF WantHIR THEN HIR.Dump; RETURN 0 END;
    ReplaceExtension(S.Input,'.s',Path);
    IF S.Cmd=CmdEmitAsm THEN
        IF S.Output[0]#0C THEN Assign(Path,S.Output) END;
        IF EmitAssembly(Path,S.DebugInfo) THEN RETURN 0 ELSE RETURN 1 END
    END;
    IF S.Cmd=CmdEmitObj THEN
        IF NOT EmitAssembly(Path,S.DebugInfo) THEN RETURN 1 END;
        IF S.Output[0]#0C THEN Assign(Obj,S.Output) ELSE ReplaceExtension(S.Input,'.o',Obj) END;
        BigClear(Cmd); BigAppend(Cmd,'cc -c -ffunction-sections -fdata-sections -o '); QuoteAppend(Cmd,Obj); BigAppend(Cmd,' '); QuoteAppend(Cmd,Path);
        IF S.Verbose THEN WriteString('hilbert: exec  '); WriteString(Cmd); NewLine END;
        R:=Shell(Cmd); IF (R=0) AND NOT S.KeepTemps THEN BigClear(Cmd); BigAppend(Cmd,'rm -f '); QuoteAppend(Cmd,Path); R:=Shell(Cmd) END;
        IF R=0 THEN RETURN 0 ELSE SimpleCode(Error,EAssemblerFailed,'assembler failed'); RETURN 1 END
    END;
    RETURN 0
END CompileRootOnly;

PROCEDURE CachedCount():CARDINAL;
VAR I,N:CARDINAL;
BEGIN I:=0; N:=0; WHILE I<ModuleCount DO IF Modules[I].Cached THEN INC(N) END; INC(I) END; RETURN N END CachedCount;

PROCEDURE AppendLibraryArg(VAR Cmd:CommandText; Name:ARRAY OF CHAR);
VAR Arg:Text;
BEGIN Assign(Arg,'-l'); Append(Arg,Name); QuoteAppend(Cmd,Arg); BigAppend(Cmd,' ') END AppendLibraryArg;

PROCEDURE MakeLinkStamp(Out,Dir:ARRAY OF CHAR; VAR Path:Text);
VAR Safe:Text;
BEGIN
    SafeModuleName(Out,Safe); Assign(Path,Dir);
    IF (Length(Path)>0) AND (Path[Length(Path)-1]#'/') THEN Append(Path,'/') END;
    Append(Path,'.link.v1.'); Append(Path,Safe)
END MakeLinkStamp;

PROCEDURE LinkStampMatches(Path:ARRAY OF CHAR; VAR Expected:CommandText):BOOLEAN;
VAR F:FIO.File; C:CHAR; I:CARDINAL;
BEGIN
    F:=FIO.OpenToRead(Path); IF NOT FIO.IsNoError(F) THEN FIO.Close(F); RETURN FALSE END; I:=0;
    WHILE NOT FIO.EOF(F) DO
        C:=FIO.ReadChar(F);
        IF NOT FIO.EOF(F) OR (C#0C) THEN
            IF (I>HIGH(Expected)) OR (Expected[I]#C) THEN FIO.Close(F); RETURN FALSE END;
            INC(I)
        END
    END;
    FIO.Close(F); RETURN (I<=HIGH(Expected)) AND (Expected[I]=0C)
END LinkStampMatches;

PROCEDURE SaveLinkStamp(Path:ARRAY OF CHAR; VAR Value:CommandText);
VAR F:FIO.File;
BEGIN
    F:=FIO.OpenToWrite(Path); IF NOT FIO.IsNoError(F) THEN FIO.Close(F); RETURN END;
    FIO.WriteString(F,Value); FIO.Close(F)
END SaveLinkStamp;

PROCEDURE FreshLinkBatch(VAR Check:CommandText):BOOLEAN;
VAR R:INTEGER;
BEGIN R:=Shell(Check); BigClear(Check); RETURN R=0 END FreshLinkBatch;

PROCEDURE LinkFresh(Out,Stamp:ARRAY OF CHAR; VAR LinkCommand:CommandText; VAR S:Settings):BOOLEAN;
VAR Check:CommandText; I:CARDINAL;

    PROCEDURE AddObject(Path:ARRAY OF CHAR):BOOLEAN;
    BEGIN
        IF BigLength(Check)+Length(Out)+Length(Path)+24>MaxCommand THEN
            IF NOT FreshLinkBatch(Check) THEN RETURN FALSE END;
            BigAppend(Check,'test '); QuoteAppend(Check,Out); BigAppend(Check,' -nt '); QuoteAppend(Check,Path)
        ELSE
            BigAppend(Check,' && test '); QuoteAppend(Check,Out); BigAppend(Check,' -nt '); QuoteAppend(Check,Path)
        END;
        RETURN TRUE
    END AddObject;

BEGIN
    IF NOT S.Incremental OR (CachedCount()#ModuleCount) OR NOT Exists(Out) OR NOT Exists(Stamp) THEN RETURN FALSE END;
    IF NOT LinkStampMatches(Stamp,LinkCommand) THEN RETURN FALSE END;
    BigClear(Check); BigAppend(Check,'test '); QuoteAppend(Check,Stamp); BigAppend(Check,' -nt '); QuoteAppend(Check,Out);
    IF RuntimeNeeded THEN IF NOT AddObject(RuntimeObject) THEN RETURN FALSE END END;
    I:=0;
    WHILE I<ModuleCount DO
        IF (Modules[I].ObjPath[0]#0C) AND NOT AddObject(Modules[I].ObjPath) THEN RETURN FALSE END;
        INC(I)
    END;
    IF BigLength(Check)#0 THEN RETURN FreshLinkBatch(Check) END;
    RETURN TRUE
END LinkFresh;

PROCEDURE Link(VAR S:Settings):INTEGER;
VAR Cmd:CommandText; Out,Stamp:Text; I:CARDINAL; R:INTEGER;
BEGIN
    IF RuntimeNeeded AND NOT EnsureRuntime(S) THEN RETURN 1 END;
    IF S.Output[0]=0C THEN BaseName(S.Input,Out) ELSE Assign(Out,S.Output) END;
    BigClear(Cmd); BigAppend(Cmd,'cc ');
    IF S.Sysroot[0]#0C THEN BigAppend(Cmd,'--sysroot='); QuoteAppend(Cmd,S.Sysroot); BigAppend(Cmd,' ') END;
    IF S.StaticLink THEN BigAppend(Cmd,'-static ') END; IF S.Strip THEN BigAppend(Cmd,'-s ') END;
    I:=0; WHILE I<S.LibraryPathCount DO BigAppend(Cmd,'-L'); QuoteAppend(Cmd,S.LibraryPaths[I]); BigAppend(Cmd,' '); INC(I) END;
    IF RuntimeNeeded THEN BigAppend(Cmd,'-pthread ') END; BigAppend(Cmd,'-Wl,-O1 -Wl,--gc-sections -Wl,--as-needed -o '); QuoteAppend(Cmd,Out); BigAppend(Cmd,' ');
    IF RuntimeNeeded THEN QuoteAppend(Cmd,RuntimeObject); BigAppend(Cmd,' ') END;
    I:=0;
    WHILE I<ModuleCount DO
        IF Modules[I].ObjPath[0]#0C THEN QuoteAppend(Cmd,Modules[I].ObjPath); BigAppend(Cmd,' ') END; INC(I)
    END;
    I:=0; WHILE I<AutoLibraryCount DO AppendLibraryArg(Cmd,AutoLibraries[I]); INC(I) END;
    I:=0; WHILE I<S.LinkLibraryCount DO AppendLibraryArg(Cmd,S.LinkLibraries[I]); INC(I) END;
    MakeLinkStamp(Out,S.CacheDir,Stamp);
    IF LinkFresh(Out,Stamp,Cmd,S) THEN
        IF NOT S.Quiet THEN WriteString('hilbert: up to date '); WriteString(Out); WriteString(' ('); WriteCard(ModuleCount,0); WriteString(' modules cached)'); NewLine END;
        RETURN 0
    END;
    IF S.Verbose THEN WriteString('hilbert: exec  '); WriteString(Cmd); NewLine END;
    R:=Shell(Cmd); IF R#0 THEN SimpleCode(Error,ELinkerFailed,'assembler/linker failed'); RETURN 1 END;
    SaveLinkStamp(Stamp,Cmd);
    IF NOT S.Quiet THEN WriteString('hilbert: linked '); WriteString(Out); WriteString(' ('); WriteCard(ModuleCount,0); WriteString(' modules'); IF CachedCount()#0 THEN WriteString(', '); WriteCard(CachedCount(),0); WriteString(' cached') END; WriteString(')'); NewLine END;
    RETURN 0
END Link;

PROCEDURE Run(VAR S:Settings):INTEGER;
VAR Cmd:CommandText; R:INTEGER; T:Target.Info;
BEGIN
    Diagnostics.Init(S.Color); Diagnostics.Configure(S.ErrorLimit,S.WarningsAsErrors,S.Quiet,S.ShowSummary); Semantics.InitGraph;
    IF NOT Target.Parse(S.Target,T) THEN SimpleCode(Error,EUnknownTarget,'unknown target triple'); RETURN 1 END;
    Divisions.Configure(T,S.Profile,S.Runtime);
    IF Equal(S.Runtime,'freestanding') AND (S.Cmd#CmdCheck) AND (S.Cmd#CmdDumpAST) THEN
        SimpleCode(Error,EBackendTarget,'freestanding selection is available to check, but native freestanding startup is not implemented yet'); RETURN 1
    END;
    IF (S.Cmd#CmdCheck) AND (S.Cmd#CmdGraph) AND (S.Cmd#CmdDumpAST) AND (S.Cmd#CmdDumpHIR) AND NOT Target.Supported(T) THEN
        SimpleCode(Error,EBackendTarget,'target front end exists but native backend is not implemented yet'); RETURN 1
    END;
    IF S.Cmd=CmdDumpAST THEN RETURN CompileRootOnly(S,FALSE,FALSE) END;
    IF S.Cmd=CmdDumpHIR THEN RETURN CompileRootOnly(S,TRUE,FALSE) END;
    IF (S.Cmd=CmdEmitAsm) OR (S.Cmd=CmdEmitObj) THEN RETURN CompileRootOnly(S,FALSE,TRUE) END;

    ModuleCount:=0; AutoLibraryCount:=0; RuntimeNeeded:=FALSE; AssemblyJobCount:=0; ProcessedModuleCount:=0; PlanModuleCount:=0;
    IF S.Cmd=CmdCheck THEN IF CompileOne(S.Input,TRUE,FALSE,S) AND EmitGenericRequests(FALSE,S) THEN RETURN 0 ELSE RETURN 1 END END;
    IF S.Cmd=CmdGraph THEN
        IF CompileOne(S.Input,TRUE,FALSE,S) AND EmitGenericRequests(FALSE,S) AND PrintGraph(S) THEN RETURN 0 ELSE RETURN 1 END
    END;
    BigClear(Cmd); BigAppend(Cmd,'mkdir -p '); QuoteAppend(Cmd,S.CacheDir); R:=Shell(Cmd);
    IF R#0 THEN SimpleCode(Error,EBuildDirectory,'cannot create build directory'); RETURN 1 END;
    IF S.Progress AND NOT S.Quiet THEN
        PlanModuleCount:=0; IF NOT DiscoverPlan(S.Input,S) THEN RETURN 1 END;
        WriteString('hilbert: '); WriteCard(PlanModuleCount,0); WriteString(' module'); IF PlanModuleCount#1 THEN WriteString('s') END; WriteString(' in build graph'); NewLine
    END;
    IF NOT CompileOne(S.Input,TRUE,TRUE,S) THEN RETURN 1 END;
    IF NOT FlushAssemblyJobs(S) THEN RETURN 1 END;
    IF NOT EmitGenericRequests(TRUE,S) THEN RETURN 1 END;
    IF NOT FlushAssemblyJobs(S) THEN RETURN 1 END;
    RETURN Link(S)
END Run;

END Driver.
