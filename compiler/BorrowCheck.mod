IMPLEMENTATION MODULE BorrowCheck;

IMPORT AST, Semantics, Signatures, Types, Methods, Diagnostics;
FROM AST IMPORT NodeId,Node,NodeKind;
FROM Types IMPORT TypeId,Type,TypeKind;
FROM HStrings IMPORT Text,Assign,Append,Equal;
FROM Diagnostics IMPORT Severity;
FROM ErrorCodes IMPORT EBorrowAlias,EEscapingBorrow,EUnsafePointerAccess;
FROM Source IMPORT FileName,LineText;

CONST MaxBorrowRoots=64; MaxLocalNames=2048;
TYPE
    Storage=RECORD Root:Text; Offset,Size:CARDINAL; Exact:BOOLEAN END;
    StorageArray=ARRAY [0..MaxBorrowRoots-1] OF Storage;
VAR File:Text;
    Locals:ARRAY [0..MaxLocalNames-1] OF Text; LocalCount:CARDINAL;
    Borrowed:ARRAY [0..MaxLocalNames-1] OF Text; BorrowedCount:CARDINAL;

PROCEDURE ErrorAt(N:Node; Code:CARDINAL; Message:ARRAY OF CHAR);
VAR L:Text;
BEGIN LineText(N.Line,L); Diagnostics.CodedContext(Error,Code,File,N.Line,N.Column,Message,L) END ErrorAt;

PROCEDURE RootName(Id:NodeId; VAR Out:Text):BOOLEAN;
VAR N:Node;
BEGIN
    Out[0]:=0C; IF Id=0 THEN RETURN FALSE END; N:=AST.Get(Id);
    CASE N.Kind OF
    | NName:Assign(Out,N.Text); RETURN TRUE
    | NSelect,NIndex:RETURN RootName(N.A,Out)
    | NDeref:RETURN FALSE
    ELSE RETURN FALSE
    END
END RootName;

PROCEDURE StorageOf(Id:NodeId; VAR S:Storage):BOOLEAN;
VAR N,BaseNode:Node; T:Type; Ty,BaseTy:TypeId; Base:Storage; Off:LONGINT;
BEGIN
    S.Root[0]:=0C; S.Offset:=0; S.Size:=0; S.Exact:=FALSE;
    IF Id=0 THEN RETURN FALSE END; N:=AST.Get(Id);
    CASE N.Kind OF
    | NName:
        Assign(S.Root,N.Text); Ty:=Semantics.TypeOf(Id);
        IF Ty#0 THEN T:=Types.Get(Ty); S.Size:=T.Size; S.Exact:=S.Size#0 END;
        RETURN TRUE
    | NSelect:
        IF NOT StorageOf(N.A,Base) THEN RETURN FALSE END;
        Ty:=Semantics.TypeOf(Id); BaseTy:=Semantics.TypeOf(N.A); BaseNode:=AST.Get(N.A);
        (* A module is a namespace rather than storage.  Give each exported
           variable its own qualified root so Module.A and Module.B do not
           falsely alias merely because both selections start at Module. *)
        IF (BaseTy=0) AND (BaseNode.Kind=NName) THEN
            Assign(S.Root,Base.Root); Append(S.Root,'.'); Append(S.Root,N.Text);
            S.Offset:=0; S.Size:=0; S.Exact:=FALSE;
            IF Ty#0 THEN T:=Types.Get(Ty); S.Size:=T.Size; S.Exact:=S.Size#0 END;
            RETURN TRUE
        END;
        S:=Base; Off:=N.IntValue;
        IF (Off<0) OR NOT Base.Exact OR (Ty=0) THEN S.Exact:=FALSE; RETURN TRUE END;
        T:=Types.Get(Ty);
        IF (T.Size=0) OR (VAL(CARDINAL,Off)>MAX(CARDINAL)-Base.Offset) THEN S.Exact:=FALSE; RETURN TRUE END;
        S.Offset:=Base.Offset+VAL(CARDINAL,Off); S.Size:=T.Size; S.Exact:=TRUE; RETURN TRUE
    | NIndex:
        (* A dynamic index may designate any element.  Keep the root so two
           indexed VAR arguments remain conservatively exclusive. *)
        IF StorageOf(N.A,Base) THEN S:=Base; S.Exact:=FALSE; RETURN TRUE END;
        RETURN FALSE
    | NDeref:
        RETURN FALSE
    ELSE
        RETURN FALSE
    END
END StorageOf;

PROCEDURE StorageAliases(A,B:Storage):BOOLEAN;
VAR Delta:CARDINAL;
BEGIN
    IF NOT Equal(A.Root,B.Root) THEN RETURN FALSE END;
    IF NOT A.Exact OR NOT B.Exact OR (A.Size=0) OR (B.Size=0) THEN RETURN TRUE END;
    IF A.Offset<=B.Offset THEN
        Delta:=B.Offset-A.Offset; RETURN Delta<A.Size
    END;
    Delta:=A.Offset-B.Offset; RETURN Delta<B.Size
END StorageAliases;

PROCEDURE AddLocal(Name:ARRAY OF CHAR);
BEGIN IF LocalCount<MaxLocalNames THEN Assign(Locals[LocalCount],Name); INC(LocalCount) END END AddLocal;

PROCEDURE IsLocal(Name:ARRAY OF CHAR):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<LocalCount DO IF Equal(Locals[I],Name) THEN RETURN TRUE END; INC(I) END; RETURN FALSE END IsLocal;

PROCEDURE IsBorrowed(Name:ARRAY OF CHAR):BOOLEAN;
VAR I:CARDINAL;
BEGIN I:=0; WHILE I<BorrowedCount DO IF Equal(Borrowed[I],Name) THEN RETURN TRUE END; INC(I) END; RETURN FALSE END IsBorrowed;

PROCEDURE AddBorrowed(Name:ARRAY OF CHAR);
BEGIN
    IF IsBorrowed(Name) THEN RETURN END;
    IF BorrowedCount<MaxLocalNames THEN Assign(Borrowed[BorrowedCount],Name); INC(BorrowedCount) END
END AddBorrowed;

PROCEDURE RemoveBorrowed(Name:ARRAY OF CHAR);
VAR I,J:CARDINAL;
BEGIN
    I:=0;
    WHILE I<BorrowedCount DO
        IF Equal(Borrowed[I],Name) THEN
            J:=I; WHILE J+1<BorrowedCount DO Assign(Borrowed[J],Borrowed[J+1]); INC(J) END;
            DEC(BorrowedCount); Borrowed[BorrowedCount][0]:=0C; RETURN
        END;
        INC(I)
    END
END RemoveBorrowed;

PROCEDURE CollectProcedureLocals(N:Node);
VAR P:NodeId; X:Node;
BEGIN
    LocalCount:=0; BorrowedCount:=0; P:=N.A;
    WHILE P#0 DO X:=AST.Get(P); AddLocal(X.Text); P:=X.Next END;
    P:=N.D;
    WHILE P#0 DO X:=AST.Get(P); IF (X.Kind=NReceiver) OR (X.Kind=NVar) THEN AddLocal(X.Text) END; P:=X.Next END
END CollectProcedureLocals;


PROCEDURE CheckCall(Id:NodeId; UnsafeDepth:CARDINAL);
VAR N,Callee,Arg:Node; ProcTy,BaseTy:TypeId; T:Type; P:NodeId; Index,Offset,RootCount,I:CARDINAL; Roots:StorageArray; R:Storage; M:Methods.Method;
BEGIN
    N:=AST.Get(Id); ProcTy:=Semantics.TypeOf(N.A); Offset:=0; Callee:=AST.Get(N.A);
    IF Callee.Kind=NSelect THEN
        BaseTy:=Semantics.TypeOf(Callee.A);
        IF BaseTy#0 THEN T:=Types.Get(BaseTy); IF (T.Kind=TyRef) OR (T.Kind=TyPointer) THEN BaseTy:=T.Base END;
            IF Methods.Find(BaseTy,Callee.Text,M) THEN ProcTy:=M.ProcType; Offset:=1 END
        END
    END;
    RootCount:=0; Index:=Offset; P:=N.B;
    WHILE P#0 DO
        Arg:=AST.Get(P);
        IF (ProcTy#0) AND (Index<Signatures.ParameterCount(ProcTy)) AND Signatures.ParameterByRef(ProcTy,Index) THEN
            IF StorageOf(P,R) THEN
                I:=0; WHILE I<RootCount DO
                    IF StorageAliases(Roots[I],R) AND (UnsafeDepth=0) THEN
                        ErrorAt(Arg,EBorrowAlias,'overlapping storage is passed to more than one VAR parameter');
                        Diagnostics.Help('copy one value, split the operation, or use UNSAFE when intentional');
                        I:=RootCount
                    ELSE INC(I) END
                END;
                IF RootCount<MaxBorrowRoots THEN Roots[RootCount]:=R; INC(RootCount) END
            END
        END;
        Expr(P,UnsafeDepth); INC(Index); P:=Arg.Next
    END;
    Expr(N.A,UnsafeDepth)
END CheckCall;

PROCEDURE Expr(Id:NodeId; UnsafeDepth:CARDINAL);
VAR N:Node; T:Type; Ty:TypeId;
BEGIN
    IF Id=0 THEN RETURN END; N:=AST.Get(Id);
    CASE N.Kind OF
    | NCall:CheckCall(Id,UnsafeDepth)
    | NDeref:
        Ty:=Semantics.TypeOf(N.A); IF Ty#0 THEN T:=Types.Get(Ty); IF (T.Kind=TyPointer) AND (UnsafeDepth=0) THEN ErrorAt(N,EUnsafePointerAccess,'raw POINTER dereference requires an UNSAFE block') END END;
        Expr(N.A,UnsafeDepth)
    | NIndex:
        Ty:=Semantics.TypeOf(N.A); IF Ty#0 THEN T:=Types.Get(Ty); IF (T.Kind=TyPointer) AND (UnsafeDepth=0) THEN ErrorAt(N,EUnsafePointerAccess,'raw POINTER indexing requires an UNSAFE block') END END;
        Expr(N.A,UnsafeDepth); Expr(N.B,UnsafeDepth)
    ELSE
        Expr(N.A,UnsafeDepth); Expr(N.B,UnsafeDepth); Expr(N.C,UnsafeDepth); Expr(N.D,UnsafeDepth)
    END
END Expr;

PROCEDURE EscapesLocalAddress(Id:NodeId):BOOLEAN;
VAR N:Node; R:Text;
BEGIN
    IF Id=0 THEN RETURN FALSE END; N:=AST.Get(Id);
    IF N.Kind=NAddressOf THEN RETURN RootName(N.A,R) AND IsLocal(R) END;
    IF (N.Kind=NName) AND IsBorrowed(N.Text) THEN RETURN TRUE END;
    RETURN EscapesLocalAddress(N.A) OR EscapesLocalAddress(N.B) OR EscapesLocalAddress(N.C) OR EscapesLocalAddress(N.D) OR EscapesLocalAddress(N.Next)
END EscapesLocalAddress;

PROCEDURE Statement(Id:NodeId; UnsafeDepth:CARDINAL);
VAR N,A,First:Node; P:NodeId; R:Text;
BEGIN
    IF Id=0 THEN RETURN END; N:=AST.Get(Id);
    CASE N.Kind OF
    | NBlock:List(N.A,UnsafeDepth); IF N.B#0 THEN Statement(N.B,UnsafeDepth) END
    | NUnsafe:Statement(N.A,UnsafeDepth+1)
    | NReturn:
        IF (UnsafeDepth=0) AND EscapesLocalAddress(N.A) THEN
            ErrorAt(N,EEscapingBorrow,'address of a local value escapes its procedure');
            Diagnostics.Help('return a value or REF object instead; raw escaping addresses belong in UNSAFE code')
        END;
        Expr(N.A,UnsafeDepth)
    | NIf:Expr(N.A,UnsafeDepth); Statement(N.B,UnsafeDepth); Statement(N.C,UnsafeDepth)
    | NWhile:Expr(N.A,UnsafeDepth); Statement(N.B,UnsafeDepth)
    | NRepeat:Statement(N.A,UnsafeDepth); Expr(N.B,UnsafeDepth)
    | NFor:Expr(N.A,UnsafeDepth); Expr(N.B,UnsafeDepth); Expr(N.C,UnsafeDepth); Statement(N.D,UnsafeDepth)
    | NForIn:Expr(N.A,UnsafeDepth); Statement(N.D,UnsafeDepth)
    | NLoop:Statement(N.A,UnsafeDepth)
    | NCase:
        Expr(N.A,UnsafeDepth); P:=N.B; WHILE P#0 DO A:=AST.Get(P); Expr(A.A,UnsafeDepth); Statement(A.B,UnsafeDepth); P:=A.Next END; Statement(N.C,UnsafeDepth)
    | NParallel:
        IF N.A#0 THEN
            First:=AST.Get(N.A);
            IF First.Kind=NForIn THEN Statement(N.A,UnsafeDepth) ELSE List(N.A,UnsafeDepth) END
        END
    | NWith:Expr(N.A,UnsafeDepth); Statement(N.B,UnsafeDepth)
    | NDefer:Statement(N.A,UnsafeDepth)
    | NAssign:
        IF UnsafeDepth=0 THEN
            IF EscapesLocalAddress(N.B) THEN
                IF RootName(N.A,R) AND IsLocal(R) THEN AddBorrowed(R)
                ELSE
                    ErrorAt(N,EEscapingBorrow,'address of a local value escapes into non-local storage');
                    Diagnostics.Help('keep the address in a local temporary, use managed REF storage, or make the low-level escape explicit with UNSAFE')
                END
            ELSE
                (* A simple local address temporary stops borrowing when it is overwritten.
                   Do not clear a whole record root when assigning one of its fields. *)
                A:=AST.Get(N.A);
                IF A.Kind=NName THEN
                    IF RootName(N.A,R) AND IsLocal(R) THEN RemoveBorrowed(R) END
                END
            END
        END;
        Expr(N.A,UnsafeDepth); Expr(N.B,UnsafeDepth)
    ELSE Expr(Id,UnsafeDepth)
    END
END Statement;

PROCEDURE List(Id:NodeId; UnsafeDepth:CARDINAL);
VAR P:NodeId; N:Node;
BEGIN P:=Id; WHILE P#0 DO N:=AST.Get(P); Statement(P,UnsafeDepth); P:=N.Next END END List;

PROCEDURE CheckProcedure(Id:NodeId);
VAR N:Node;
BEGIN N:=AST.Get(Id); CollectProcedureLocals(N); Statement(N.C,0) END CheckProcedure;

PROCEDURE Check(Root:NodeId):BOOLEAN;
VAR R,N:Node; P:NodeId;
BEGIN
    FileName(File); R:=AST.Get(Root); P:=R.A;
    WHILE P#0 DO N:=AST.Get(P); IF (N.Kind=NProcedure) OR (N.Kind=NTask) THEN CheckProcedure(P) END; P:=N.Next END;
    LocalCount:=0; BorrowedCount:=0; Statement(R.B,0);
    RETURN NOT Diagnostics.HasErrors()
END Check;

END BorrowCheck.
