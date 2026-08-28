IMPLEMENTATION MODULE Generics;

IMPORT Types,Layout,Signatures;
FROM Types IMPORT TypeId,Type,TypeKind,NewType,MaxTypes;
FROM Diagnostics IMPORT SimpleCode,Severity;
FROM ErrorCodes IMPORT EGenericArity,EArenaTypes;

CONST MaxTemplates=4096; MaxTemplateParams=32768;
TYPE TemplateRec=RECORD Ty:TypeId; First,Count:CARDINAL END;

CONST MaxInstances=4096; MaxInstanceArgs=65536;
TYPE InstanceRec=RECORD Template,Result:TypeId; First,Count:CARDINAL END;

VAR Templates:ARRAY [0..MaxTemplates] OF TemplateRec;
    TemplateParams:ARRAY [0..MaxTemplateParams] OF TypeId;
    Instances:ARRAY [0..MaxInstances] OF InstanceRec;
    InstanceArgs:ARRAY [0..MaxInstanceArgs] OF TypeId;
    MemoOld,MemoNew:ARRAY [0..MaxTypes] OF TypeId;
    DepStack:ARRAY [0..MaxTypes] OF TypeId;
    NT,NP,NI,NIA,MemoCount,DepDepth:CARDINAL;

PROCEDURE Init;
BEGIN NT:=0; NP:=0; NI:=0; NIA:=0; MemoCount:=0; DepDepth:=0 END Init;

PROCEDURE FindTemplate(Ty:TypeId):CARDINAL;
VAR I:CARDINAL;
BEGIN I:=1; WHILE I<=NT DO IF Templates[I].Ty=Ty THEN RETURN I END; INC(I) END; RETURN 0 END FindTemplate;

PROCEDURE RegisterTemplate(Template:TypeId; VAR Params:ActualArray; Count:CARDINAL);
VAR I:CARDINAL;
BEGIN
    IF FindTemplate(Template)#0 THEN RETURN END;
    IF NT>=MaxTemplates THEN SimpleCode(Fatal,EArenaTypes,'generic template table exhausted'); RETURN END;
    IF NP+Count>MaxTemplateParams THEN SimpleCode(Fatal,EArenaTypes,'generic parameter table exhausted'); RETURN END;
    INC(NT); Templates[NT].Ty:=Template; Templates[NT].First:=NP+1; Templates[NT].Count:=Count;
    I:=0; WHILE I<Count DO INC(NP); TemplateParams[NP]:=Params[I]; INC(I) END
END RegisterTemplate;

PROCEDURE IsTemplate(Template:TypeId):BOOLEAN;
BEGIN RETURN FindTemplate(Template)#0 END IsTemplate;

PROCEDURE ParameterCount(Template:TypeId):CARDINAL;
VAR I:CARDINAL;
BEGIN I:=FindTemplate(Template); IF I=0 THEN RETURN 0 END; RETURN Templates[I].Count END ParameterCount;

PROCEDURE SameInstance(I:CARDINAL; Template:TypeId; VAR Actuals:ActualArray; Count:CARDINAL):BOOLEAN;
VAR J:CARDINAL;
BEGIN
    IF (Instances[I].Template#Template) OR (Instances[I].Count#Count) THEN RETURN FALSE END;
    J:=0; WHILE J<Count DO IF InstanceArgs[Instances[I].First+J]#Actuals[J] THEN RETURN FALSE END; INC(J) END;
    RETURN TRUE
END SameInstance;

PROCEDURE FindInstance(Template:TypeId; VAR Actuals:ActualArray; Count:CARDINAL):TypeId;
VAR I:CARDINAL;
BEGIN
    I:=1; WHILE I<=NI DO IF SameInstance(I,Template,Actuals,Count) THEN RETURN Instances[I].Result END; INC(I) END;
    RETURN 0
END FindInstance;

PROCEDURE FindInstanceByResult(Ty:TypeId):CARDINAL;
VAR I:CARDINAL;
BEGIN I:=1; WHILE I<=NI DO IF Instances[I].Result=Ty THEN RETURN I END; INC(I) END; RETURN 0 END FindInstanceByResult;

PROCEDURE RememberInstance(Template:TypeId; VAR Actuals:ActualArray; Count:CARDINAL; Result:TypeId);
VAR I:CARDINAL;
BEGIN
    IF NI>=MaxInstances THEN SimpleCode(Fatal,EArenaTypes,'generic instance table exhausted'); RETURN END;
    IF NIA+Count>MaxInstanceArgs THEN SimpleCode(Fatal,EArenaTypes,'generic instance argument table exhausted'); RETURN END;
    INC(NI); Instances[NI].Template:=Template; Instances[NI].Result:=Result; Instances[NI].First:=NIA+1; Instances[NI].Count:=Count;
    I:=0; WHILE I<Count DO INC(NIA); InstanceArgs[NIA]:=Actuals[I]; INC(I) END
END RememberInstance;

PROCEDURE AlignUp(N,A:CARDINAL):CARDINAL;
BEGIN IF A<=1 THEN RETURN N END; RETURN ((N+A-1) DIV A)*A END AlignUp;

PROCEDURE ParamReplacement(Ty:TypeId; TemplateIndex:CARDINAL; VAR Actuals:ActualArray):TypeId;
VAR I:CARDINAL;
BEGIN
    I:=0; WHILE I<Templates[TemplateIndex].Count DO IF TemplateParams[Templates[TemplateIndex].First+I]=Ty THEN RETURN Actuals[I] END; INC(I) END; RETURN 0
END ParamReplacement;

PROCEDURE IsTemplateParam(Ty:TypeId; TemplateIndex:CARDINAL):BOOLEAN;
VAR I:CARDINAL;
BEGIN
    I:=0; WHILE I<Templates[TemplateIndex].Count DO IF TemplateParams[Templates[TemplateIndex].First+I]=Ty THEN RETURN TRUE END; INC(I) END; RETURN FALSE
END IsTemplateParam;

PROCEDURE DependsOnParam(Ty:TypeId; TemplateIndex:CARDINAL):BOOLEAN;
VAR T:Type; I:CARDINAL; F:Layout.Field; Yes:BOOLEAN;
BEGIN
    IF Ty=0 THEN RETURN FALSE END;
    IF IsTemplateParam(Ty,TemplateIndex) THEN RETURN TRUE END;
    I:=0; WHILE I<DepDepth DO IF DepStack[I]=Ty THEN RETURN FALSE END; INC(I) END;
    IF DepDepth>MaxTypes THEN SimpleCode(Fatal,EArenaTypes,'generic dependency stack exhausted'); RETURN FALSE END;
    DepStack[DepDepth]:=Ty; INC(DepDepth);
    T:=Types.Get(Ty); Yes:=FALSE;
    CASE T.Kind OF
    | TyPointer,TyRef,TySlice,TySet,TyAtomic,TyRange,TyDistinct,TyArray:
        Yes:=DependsOnParam(T.Base,TemplateIndex)
    | TyProcedure:
        Yes:=DependsOnParam(T.Result,TemplateIndex); I:=0;
        WHILE (I<Signatures.ParameterCount(Ty)) AND NOT Yes DO Yes:=DependsOnParam(Signatures.ParameterType(Ty,I),TemplateIndex); INC(I) END
    | TyRecord,TyProtected:
        Yes:=DependsOnParam(T.Base,TemplateIndex); I:=1;
        WHILE (I<=Layout.Count()) AND NOT Yes DO F:=Layout.Get(I); IF F.Owner=Ty THEN Yes:=DependsOnParam(F.TypeId,TemplateIndex) END; INC(I) END
    ELSE
    END;
    DEC(DepDepth); RETURN Yes
END DependsOnParam;

PROCEDURE MemoFind(Ty:TypeId; Base:CARDINAL):TypeId;
VAR I:CARDINAL;
BEGIN I:=MemoCount; WHILE I>Base DO IF MemoOld[I]=Ty THEN RETURN MemoNew[I] END; DEC(I) END; RETURN 0 END MemoFind;

PROCEDURE MemoAdd(OldTy,NewTy:TypeId);
BEGIN
    IF MemoCount>=MaxTypes THEN SimpleCode(Fatal,EArenaTypes,'generic substitution table exhausted'); RETURN END;
    INC(MemoCount); MemoOld[MemoCount]:=OldTy; MemoNew[MemoCount]:=NewTy
END MemoAdd;

PROCEDURE Substitute(Ty:TypeId; TemplateIndex:CARDINAL; VAR Actuals:ActualArray; MemoBase:CARDINAL):TypeId;
VAR R,B,NewB:TypeId; T,U,BT,NBT:Type; I,J,K,Origin:CARDINAL; F:Layout.Field; Added:Layout.FieldId;
    Size,Align,Offset,Count,UnionAlign,UnionBase,ArmEnd,MaxEnd,MaxArm:CARDINAL; Nested:ActualArray;
BEGIN
    IF Ty=0 THEN RETURN 0 END;
    R:=ParamReplacement(Ty,TemplateIndex,Actuals); IF R#0 THEN RETURN R END;
    IF NOT DependsOnParam(Ty,TemplateIndex) THEN RETURN Ty END;
    R:=MemoFind(Ty,MemoBase); IF R#0 THEN RETURN R END;

    (* A generic instance inside another template keeps its own nominal origin.
       Rebuild the argument list, then go through Instantiate so Node[INTEGER]
       means the same type no matter which outer generic happened to mention it. *)
    Origin:=FindInstanceByResult(Ty);
    IF Origin#0 THEN
        I:=0; WHILE I<Instances[Origin].Count DO Nested[I]:=Substitute(InstanceArgs[Instances[Origin].First+I],TemplateIndex,Actuals,MemoBase); INC(I) END;
        RETURN Instantiate(Instances[Origin].Template,Nested,Instances[Origin].Count)
    END;

    T:=Types.Get(Ty);
    CASE T.Kind OF
    | TyPointer,TyRef,TySlice,TySet,TyAtomic,TyRange,TyDistinct,TyArray:
        B:=T.Base; R:=NewType(T.Kind); MemoAdd(Ty,R); U:=T; NewB:=Substitute(B,TemplateIndex,Actuals,MemoBase); U.Base:=NewB;
        IF T.Kind=TyArray THEN
            IF B#0 THEN BT:=Types.Get(B) ELSE BT:=T END; NBT:=Types.Get(NewB);
            IF BT.Size>0 THEN Count:=T.Size DIV BT.Size ELSE Count:=0 END; U.Size:=Count*NBT.Size; U.Align:=NBT.Align
        END;
        Types.Put(R,U); RETURN R
    | TyProcedure:
        R:=NewType(TyProcedure); MemoAdd(Ty,R); U:=T; U.Result:=Substitute(T.Result,TemplateIndex,Actuals,MemoBase); U.Size:=8; U.Align:=8; Types.Put(R,U);
        Signatures.BeginProcedure(R); Signatures.SetVariadic(R,Signatures.IsVariadic(Ty)); I:=0;
        WHILE I<Signatures.ParameterCount(Ty) DO
            NewB:=Substitute(Signatures.ParameterType(Ty,I),TemplateIndex,Actuals,MemoBase);
            Signatures.AddParameter(R,NewB,Signatures.ParameterByRef(Ty,I)); INC(I)
        END;
        RETURN R
    | TyRecord,TyProtected:
        R:=NewType(T.Kind); MemoAdd(Ty,R); U:=T; U.Base:=Substitute(T.Base,TemplateIndex,Actuals,MemoBase); Size:=0; Align:=1;
        IF U.Base#0 THEN NBT:=Types.Get(U.Base); Size:=NBT.Size; Align:=NBT.Align END;
        (* Common fields are laid out first. Variant-arm fields are rebuilt at
           one shared union base, otherwise a generic tagged record would grow
           every arm sequentially and silently lose its representation. *)
        I:=1; WHILE I<=Layout.Count() DO
            F:=Layout.Get(I);
            IF (F.Owner=Ty) AND (F.VariantArm=0) THEN
                NewB:=Substitute(F.TypeId,TemplateIndex,Actuals,MemoBase); NBT:=Types.Get(NewB); IF NBT.Align>Align THEN Align:=NBT.Align END;
                Size:=AlignUp(Size,NBT.Align); Offset:=Size; Added:=Layout.AddField(R,F.Name,NewB,Offset,NBT.Size,NBT.Align,F.Flags); IF Added=0 THEN RETURN 0 END; INC(Size,NBT.Size)
            END;
            INC(I)
        END;
        UnionAlign:=1; MaxArm:=0; I:=1; WHILE I<=Layout.Count() DO
            F:=Layout.Get(I);
            IF (F.Owner=Ty) AND (F.VariantArm>0) THEN
                NewB:=Substitute(F.TypeId,TemplateIndex,Actuals,MemoBase); NBT:=Types.Get(NewB);
                IF NBT.Align>UnionAlign THEN UnionAlign:=NBT.Align END; IF F.VariantArm>MaxArm THEN MaxArm:=F.VariantArm END
            END;
            INC(I)
        END;
        IF MaxArm>0 THEN
            IF UnionAlign>Align THEN Align:=UnionAlign END; UnionBase:=AlignUp(Size,UnionAlign); MaxEnd:=UnionBase; J:=1;
            WHILE J<=MaxArm DO
                Offset:=UnionBase; I:=1;
                WHILE I<=Layout.Count() DO
                    F:=Layout.Get(I);
                    IF (F.Owner=Ty) AND (F.VariantArm=J) THEN
                        NewB:=Substitute(F.TypeId,TemplateIndex,Actuals,MemoBase); NBT:=Types.Get(NewB); Offset:=AlignUp(Offset,NBT.Align);
                        Added:=Layout.AddVariantField(R,F.Name,NewB,Offset,NBT.Size,NBT.Align,J,F.TagName,F.Flags); IF Added=0 THEN RETURN 0 END;
                        K:=0; WHILE K<F.VariantTagCount DO Layout.AddVariantTag(Added,Layout.VariantTag(F.Id,K)); INC(K) END;
                        INC(Offset,NBT.Size)
                    END;
                    INC(I)
                END;
                ArmEnd:=Offset; IF ArmEnd>MaxEnd THEN MaxEnd:=ArmEnd END; INC(J)
            END;
            Size:=MaxEnd
        END;
        U.Size:=AlignUp(Size,Align); U.Align:=Align; Types.Put(R,U); RETURN R
    ELSE RETURN Ty
    END
END Substitute;

PROCEDURE Instantiate(Template:TypeId; VAR Actuals:ActualArray; Count:CARDINAL):TypeId;
VAR I,J,MemoBase:CARDINAL; Same:BOOLEAN; R:TypeId;
BEGIN
    I:=FindTemplate(Template); IF I=0 THEN SimpleCode(Error,EGenericArity,'type is not a generic template'); RETURN 0 END;
    IF Count#Templates[I].Count THEN SimpleCode(Error,EGenericArity,'wrong number of generic type arguments'); RETURN 0 END;
    Same:=TRUE; J:=0; WHILE J<Count DO IF Actuals[J]#TemplateParams[Templates[I].First+J] THEN Same:=FALSE END; INC(J) END;
    IF Same THEN RETURN Template END;
    R:=FindInstance(Template,Actuals,Count); IF R#0 THEN RETURN R END;
    MemoBase:=MemoCount; R:=Substitute(Template,I,Actuals,MemoBase); MemoCount:=MemoBase;
    IF R#0 THEN RememberInstance(Template,Actuals,Count,R) END; RETURN R
END Instantiate;

END Generics.
