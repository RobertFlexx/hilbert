IMPLEMENTATION MODULE Project;

FROM FIO IMPORT File,OpenToRead,Close,EOF,ReadChar,IsNoError;
FROM StrIO IMPORT WriteString;
FROM HStrings IMPORT Text,Assign,Equal,ToUpper,Clear,NewLine;
FROM Diagnostics IMPORT SimpleCode,Severity;
FROM ErrorCodes IMPORT EProjectOpen,EProjectSyntax,EProjectMissingRoot,EProjectUnknownKey;

CONST MaxProjectSource=65535;
VAR Data:ARRAY [0..MaxProjectSource] OF CHAR; Len,Pos:CARDINAL;


PROCEDURE Defaults(VAR C:Config);
BEGIN
    C.Name[0]:=0C; C.Root[0]:=0C; C.Output[0]:=0C; Assign(C.Target,'x86_64-linux-gnu'); Assign(C.BuildDir,'build/.hilbert');
    Assign(C.Runtime,'hosted'); Assign(C.InstallDir,'bin'); C.IdentificationName[0]:=0C; C.Version[0]:=0C;
    C.Description[0]:=0C; C.Author[0]:=0C; C.License[0]:=0C;
    C.ModulePathCount:=0; C.LibraryPathCount:=0; C.LibraryCount:=0; C.Mode:=Debug;
    C.StaticLink:=FALSE; C.Strip:=FALSE; C.WarningsAsErrors:=FALSE; C.Incremental:=TRUE; C.KeepTemps:=FALSE
END Defaults;

PROCEDURE ReadFile(Path:ARRAY OF CHAR):BOOLEAN;
VAR F:File; Ch:CHAR;
BEGIN
    Len:=0; Pos:=0; F:=OpenToRead(Path); IF NOT IsNoError(F) THEN SimpleCode(Error,EProjectOpen,'cannot open Hilbertfile'); Close(F); RETURN FALSE END;
    WHILE NOT EOF(F) DO
        Ch:=ReadChar(F);
        IF Len>=MaxProjectSource THEN SimpleCode(Error,EProjectSyntax,'Hilbertfile exceeds 65535 bytes'); Close(F); RETURN FALSE END;
        Data[Len]:=Ch; INC(Len)
    END;
    Data[Len]:=0C; Close(F); RETURN TRUE
END ReadFile;

PROCEDURE Peek():CHAR; BEGIN IF Pos>Len THEN RETURN 0C ELSE RETURN Data[Pos] END END Peek;
PROCEDURE NextChar():CHAR; VAR C:CHAR; BEGIN C:=Peek(); IF Pos<Len THEN INC(Pos) END; RETURN C END NextChar;
PROCEDURE Skip;
BEGIN
    LOOP
        WHILE (Peek()=' ') OR (Peek()=11C) OR (Peek()=12C) OR (Peek()=15C) DO INC(Pos) END;
        IF (Peek()='#') OR ((Peek()='/') AND (Pos<Len) AND (Data[Pos+1]='/')) THEN WHILE (Peek()#0C) AND (Peek()#12C) DO INC(Pos) END ELSE RETURN END
    END
END Skip;

PROCEDURE Word(VAR Out:Text):BOOLEAN;
VAR C:CHAR; I:CARDINAL; TooLong:BOOLEAN;
BEGIN
    Skip; Clear(Out); I:=0; TooLong:=FALSE; C:=Peek();
    IF C='"' THEN
        INC(Pos); C:=Peek();
        WHILE (C#0C) AND (C#'"') DO
            IF I<HIGH(Out) THEN Out[I]:=NextChar(); INC(I) ELSE C:=NextChar(); TooLong:=TRUE END;
            C:=Peek()
        END;
        Out[I]:=0C;
        IF Peek()#'"' THEN SimpleCode(Error,EProjectSyntax,'unterminated string in Hilbertfile'); RETURN FALSE END; INC(Pos);
        IF TooLong THEN SimpleCode(Error,EProjectSyntax,'Hilbertfile token exceeds 1023 bytes'); RETURN FALSE END;
        RETURN TRUE
    END;
    WHILE (C#0C) AND (C#';') AND (C#'.') AND (C#' ') AND (C#11C) AND (C#12C) AND (C#15C) DO
        IF I<HIGH(Out) THEN Out[I]:=NextChar(); INC(I) ELSE C:=NextChar(); TooLong:=TRUE END;
        C:=Peek()
    END;
    Out[I]:=0C;
    IF TooLong THEN SimpleCode(Error,EProjectSyntax,'Hilbertfile token exceeds 1023 bytes'); RETURN FALSE END;
    RETURN Out[0]#0C
END Word;

PROCEDURE Semi():BOOLEAN;
BEGIN Skip; IF Peek()#';' THEN SimpleCode(Error,EProjectSyntax,'expected semicolon in Hilbertfile'); RETURN FALSE END; INC(Pos); RETURN TRUE END Semi;

PROCEDURE AddPath(VAR A:TextArray; VAR N:CARDINAL; V:ARRAY OF CHAR):BOOLEAN;
BEGIN IF N>HIGH(A) THEN SimpleCode(Error,EProjectSyntax,'too many project paths'); RETURN FALSE END; Assign(A[N],V); INC(N); RETURN TRUE END AddPath;
PROCEDURE AddLib(VAR A:LibArray; VAR N:CARDINAL; V:ARRAY OF CHAR):BOOLEAN;
BEGIN IF N>HIGH(A) THEN SimpleCode(Error,EProjectSyntax,'too many project libraries'); RETURN FALSE END; Assign(A[N],V); INC(N); RETURN TRUE END AddLib;

PROCEDURE BoolValue(V:ARRAY OF CHAR; VAR B:BOOLEAN):BOOLEAN;
VAR T:Text;
BEGIN Assign(T,V); ToUpper(T); IF Equal(T,'TRUE') OR Equal(T,'YES') OR Equal(T,'ON') THEN B:=TRUE; RETURN TRUE END; IF Equal(T,'FALSE') OR Equal(T,'NO') OR Equal(T,'OFF') THEN B:=FALSE; RETURN TRUE END; RETURN FALSE END BoolValue;

PROCEDURE Identification(VAR C:Config):BOOLEAN;
VAR K,V:Text;
BEGIN
    LOOP
        IF NOT Word(K) THEN SimpleCode(Error,EProjectSyntax,'IDENTIFICATION has no END'); RETURN FALSE END; ToUpper(K);
        IF Equal(K,'END') THEN Skip; IF Peek()=';' THEN INC(Pos) END; RETURN TRUE END;
        IF NOT Word(V) THEN SimpleCode(Error,EProjectSyntax,'identification field requires a value'); RETURN FALSE END;
        IF Equal(K,'NAME') THEN Assign(C.IdentificationName,V)
        ELSIF Equal(K,'VERSION') THEN Assign(C.Version,V)
        ELSIF Equal(K,'DESCRIPTION') THEN Assign(C.Description,V)
        ELSIF Equal(K,'AUTHOR') THEN Assign(C.Author,V)
        ELSIF Equal(K,'LICENSE') THEN Assign(C.License,V)
        ELSE SimpleCode(Error,EProjectUnknownKey,K); RETURN FALSE
        END;
        Skip; IF Peek()=';' THEN INC(Pos) END
    END
END Identification;

PROCEDURE Load(Path:ARRAY OF CHAR; VAR C:Config):BOOLEAN;
VAR K,V,EndName:Text;
BEGIN
    Defaults(C); IF NOT ReadFile(Path) THEN RETURN FALSE END;
    IF NOT Word(K) THEN SimpleCode(Error,EProjectSyntax,'empty Hilbertfile'); RETURN FALSE END; ToUpper(K);
    IF NOT Equal(K,'PROJECT') THEN SimpleCode(Error,EProjectSyntax,'Hilbertfile must begin with PROJECT'); RETURN FALSE END;
    IF NOT Word(C.Name) OR NOT Semi() THEN RETURN FALSE END;
    LOOP
        IF NOT Word(K) THEN SimpleCode(Error,EProjectSyntax,'unexpected end of Hilbertfile'); RETURN FALSE END; ToUpper(K);
        IF Equal(K,'END') THEN
            IF NOT Word(EndName) THEN RETURN FALSE END;
            Skip;
            IF (Peek()#';') AND (Peek()#'.') THEN SimpleCode(Error,EProjectSyntax,'expected project terminator in Hilbertfile'); RETURN FALSE END;
            INC(Pos);
            IF (C.Name[0]#0C) AND NOT Equal(C.Name,EndName) THEN SimpleCode(Error,EProjectSyntax,'PROJECT and END names differ'); RETURN FALSE END;
            EXIT
        END;
        IF Equal(K,'IDENTIFICATION') THEN
            IF NOT Identification(C) THEN RETURN FALSE END
        ELSE
        IF NOT Word(V) THEN SimpleCode(Error,EProjectSyntax,'project setting requires a value'); RETURN FALSE END;
        IF Equal(K,'ROOT') THEN Assign(C.Root,V)
        ELSIF Equal(K,'OUTPUT') THEN Assign(C.Output,V)
        ELSIF Equal(K,'TARGET') THEN Assign(C.Target,V)
        ELSIF Equal(K,'BUILD_DIR') THEN Assign(C.BuildDir,V)
        ELSIF Equal(K,'RUNTIME') THEN ToUpper(V); IF Equal(V,'HOSTED') THEN Assign(C.Runtime,'hosted') ELSIF Equal(V,'FREESTANDING') THEN Assign(C.Runtime,'freestanding') ELSE SimpleCode(Error,EProjectSyntax,'RUNTIME must be HOSTED or FREESTANDING'); RETURN FALSE END
        ELSIF Equal(K,'INSTALL_DIR') THEN Assign(C.InstallDir,V)
        ELSIF Equal(K,'MODULE_PATH') THEN IF NOT AddPath(C.ModulePaths,C.ModulePathCount,V) THEN RETURN FALSE END
        ELSIF Equal(K,'LIBRARY_PATH') THEN IF NOT AddPath(C.LibraryPaths,C.LibraryPathCount,V) THEN RETURN FALSE END
        ELSIF Equal(K,'LIBRARY') THEN IF NOT AddLib(C.Libraries,C.LibraryCount,V) THEN RETURN FALSE END
        ELSIF Equal(K,'PROFILE') THEN ToUpper(V); IF Equal(V,'DEBUG') THEN C.Mode:=Debug ELSIF Equal(V,'RELEASE') THEN C.Mode:=Release ELSIF Equal(V,'SIZE') THEN C.Mode:=Size ELSE SimpleCode(Error,EProjectSyntax,'PROFILE must be DEBUG, RELEASE or SIZE'); RETURN FALSE END
        ELSIF Equal(K,'STATIC') THEN IF NOT BoolValue(V,C.StaticLink) THEN SimpleCode(Error,EProjectSyntax,'STATIC expects TRUE or FALSE'); RETURN FALSE END
        ELSIF Equal(K,'STRIP') THEN IF NOT BoolValue(V,C.Strip) THEN SimpleCode(Error,EProjectSyntax,'STRIP expects TRUE or FALSE'); RETURN FALSE END
        ELSIF Equal(K,'WARNINGS_AS_ERRORS') THEN IF NOT BoolValue(V,C.WarningsAsErrors) THEN SimpleCode(Error,EProjectSyntax,'WARNINGS_AS_ERRORS expects TRUE or FALSE'); RETURN FALSE END
        ELSIF Equal(K,'INCREMENTAL') THEN IF NOT BoolValue(V,C.Incremental) THEN SimpleCode(Error,EProjectSyntax,'INCREMENTAL expects TRUE or FALSE'); RETURN FALSE END
        ELSIF Equal(K,'KEEP_TEMPS') THEN IF NOT BoolValue(V,C.KeepTemps) THEN SimpleCode(Error,EProjectSyntax,'KEEP_TEMPS expects TRUE or FALSE'); RETURN FALSE END
        ELSE SimpleCode(Error,EProjectUnknownKey,K); RETURN FALSE
        END;
        IF NOT Semi() THEN RETURN FALSE END
        END
    END;
    IF C.Root[0]=0C THEN SimpleCode(Error,EProjectMissingRoot,'project has no ROOT entry'); RETURN FALSE END;
    IF C.Output[0]=0C THEN Assign(C.Output,C.Name) END; RETURN TRUE
END Load;

PROCEDURE PrintProfile(P:Profile);
BEGIN
    CASE P OF
    | Debug:WriteString('debug')
    | Release:WriteString('release')
    | Size:WriteString('size')
    END
END PrintProfile;

PROCEDURE Print(C:Config);
BEGIN
    WriteString('project '); WriteString(C.Name); NewLine;
    WriteString('  root       '); WriteString(C.Root); NewLine;
    WriteString('  output     '); WriteString(C.Output); NewLine;
    WriteString('  profile    '); PrintProfile(C.Mode); NewLine;
    WriteString('  target     '); WriteString(C.Target); NewLine;
    WriteString('  runtime    '); WriteString(C.Runtime); NewLine;
    WriteString('  build dir  '); WriteString(C.BuildDir); NewLine;
    WriteString('  static     '); IF C.StaticLink THEN WriteString('yes') ELSE WriteString('no') END; NewLine;
    WriteString('  strip      '); IF C.Strip THEN WriteString('yes') ELSE WriteString('no') END; NewLine;
    WriteString('  incremental '); IF C.Incremental THEN WriteString('yes') ELSE WriteString('no') END; NewLine;
    WriteString('  keep temps  '); IF C.KeepTemps THEN WriteString('yes') ELSE WriteString('no') END; NewLine
END Print;

PROCEDURE Field(Label,Value:ARRAY OF CHAR);
BEGIN IF Value[0]#0C THEN WriteString(Label); WriteString(Value); NewLine END END Field;

PROCEDURE PrintInfo(C:Config);
VAR DisplayName:Text;
BEGIN
    IF C.IdentificationName[0]#0C THEN Assign(DisplayName,C.IdentificationName) ELSE Assign(DisplayName,C.Name) END;
    Field('project: ',DisplayName); Field('version: ',C.Version); Field('description: ',C.Description);
    Field('author: ',C.Author); Field('license: ',C.License); Field('entry: ',C.Root);
    Field('target: ',C.Target); WriteString('profile: '); PrintProfile(C.Mode); NewLine;
    Field('runtime: ',C.Runtime); Field('output: ',C.Output); Field('build directory: ',C.BuildDir)
END PrintInfo;

END Project.
