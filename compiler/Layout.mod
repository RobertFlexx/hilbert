IMPLEMENTATION MODULE Layout;
FROM HStrings IMPORT Assign, Equal;
IMPORT Types;
FROM Types IMPORT TypeId, Type;
FROM Diagnostics IMPORT SimpleCode, Severity;
FROM ErrorCodes IMPORT EArenaLayout;

VAR Fields: ARRAY [0..MaxFields] OF Field; Used: CARDINAL;
    VariantTags: ARRAY [0..MaxVariantTags-1] OF LONGINT; VariantTagsUsed:CARDINAL;

PROCEDURE Init;
BEGIN Used:=0; VariantTagsUsed:=0 END Init;

PROCEDURE AddField(Owner: TypeId; Name: ARRAY OF CHAR; FieldType: TypeId; Offset, Size, Align: CARDINAL; Flags: BITSET): FieldId;
VAR I:FieldId;
BEGIN
    IF Used>=MaxFields THEN SimpleCode(Fatal,EArenaLayout,'record field table exhausted'); RETURN 0 END;
    INC(Used); I:=Used; Fields[I].Id:=I; Fields[I].Owner:=Owner; Fields[I].TypeId:=FieldType; Assign(Fields[I].Name,Name);
    Fields[I].Offset:=Offset; Fields[I].Size:=Size; Fields[I].Align:=Align; Fields[I].VariantArm:=0;
    Fields[I].FirstVariantTag:=0; Fields[I].VariantTagCount:=0; Fields[I].TagName[0]:=0C; Fields[I].Flags:=Flags; RETURN I
END AddField;

PROCEDURE AddVariantField(Owner: TypeId; Name: ARRAY OF CHAR; FieldType: TypeId; Offset, Size, Align, Arm: CARDINAL; TagName: ARRAY OF CHAR; Flags: BITSET): FieldId;
VAR I:FieldId;
BEGIN
    I:=AddField(Owner,Name,FieldType,Offset,Size,Align,Flags); IF I=0 THEN RETURN 0 END;
    Fields[I].VariantArm:=Arm; Assign(Fields[I].TagName,TagName); RETURN I
END AddVariantField;

PROCEDURE AddVariantTag(Field:FieldId; Value:LONGINT);
BEGIN
    IF (Field=0) OR (Field>Used) THEN RETURN END;
    IF VariantTagsUsed>=MaxVariantTags THEN SimpleCode(Fatal,EArenaLayout,'variant tag table exhausted'); RETURN END;
    IF Fields[Field].VariantTagCount=0 THEN Fields[Field].FirstVariantTag:=VariantTagsUsed END;
    VariantTags[VariantTagsUsed]:=Value; INC(VariantTagsUsed); INC(Fields[Field].VariantTagCount)
END AddVariantTag;

PROCEDURE VariantTag(Field:FieldId; Index:CARDINAL):LONGINT;
BEGIN
    IF (Field=0) OR (Field>Used) OR (Index>=Fields[Field].VariantTagCount) THEN RETURN 0 END;
    RETURN VariantTags[Fields[Field].FirstVariantTag+Index]
END VariantTag;

PROCEDURE FindDirect(Owner:TypeId; Name:ARRAY OF CHAR; VAR Out:Field):BOOLEAN;
VAR I:FieldId;
BEGIN
    I:=Used;
    WHILE I>0 DO
        IF (Fields[I].Owner=Owner) AND Equal(Fields[I].Name,Name) THEN Out:=Fields[I]; RETURN TRUE END;
        DEC(I)
    END;
    RETURN FALSE
END FindDirect;

PROCEDURE FindField(Owner: TypeId; Name: ARRAY OF CHAR; VAR Out: Field): BOOLEAN;
VAR T:Type;
BEGIN
    WHILE Owner#0 DO
        IF FindDirect(Owner,Name,Out) THEN RETURN TRUE END;
        T:=Types.Get(Owner); Owner:=T.Base
    END;
    RETURN FALSE
END FindField;

PROCEDURE Count():CARDINAL;
BEGIN RETURN Used END Count;
PROCEDURE Get(Id:FieldId):Field;
BEGIN RETURN Fields[Id] END Get;
END Layout.
