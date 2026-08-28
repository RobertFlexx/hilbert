IMPLEMENTATION MODULE Target;
FROM HStrings IMPORT Assign,Equal;
PROCEDURE Default(VAR T:Info);
BEGIN Assign(T.Triple,'x86_64-linux-gnu'); T.Arch:=ArchX8664; T.OS:=OSLinux; T.Calling:=ABISysV; T.PointerSize:=8; T.PointerAlign:=8 END Default;
PROCEDURE Parse(Name:ARRAY OF CHAR; VAR T:Info):BOOLEAN;
BEGIN
    IF Equal(Name,'x86_64-linux-gnu') OR Equal(Name,'x86_64-linux') THEN Default(T); Assign(T.Triple,'x86_64-linux-gnu'); RETURN TRUE END;
    IF Equal(Name,'aarch64-linux-gnu') OR Equal(Name,'aarch64-linux') THEN Assign(T.Triple,'aarch64-linux-gnu'); T.Arch:=ArchAArch64; T.OS:=OSLinux; T.Calling:=ABISysV; T.PointerSize:=8; T.PointerAlign:=8; RETURN TRUE END;
    T.Arch:=ArchUnknown; T.OS:=OSUnknown; T.Calling:=ABIUnknown; T.PointerSize:=0; T.PointerAlign:=0; Assign(T.Triple,Name); RETURN FALSE
END Parse;
PROCEDURE Supported(T:Info):BOOLEAN;
BEGIN RETURN (T.Arch=ArchX8664) AND (T.OS=OSLinux) AND (T.Calling=ABISysV) END Supported;
END Target.
