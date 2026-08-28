/*
 * ==========================================================================
 * Hilbert 1.0 grammar for ANTLR 4
 * ==========================================================================
 *
 * Machine-readable counterpart of docs/GRAMMAR.ebnf, modeling the reference
 * implementation in compiler/Lexer.mod and compiler/Parser.mod.
 *
 *   - Rule names mirror the EBNF productions (camelCase).
 *   - Keywords are reserved tokens and cannot be used as identifiers.
 *   - Reserved-for-future spellings are declared as keyword tokens below so
 *     they are unavailable as identifiers exactly like the reference
 *     compiler; they appear in no parser rule:
 *     POST INVARIANT PROTECTED PRIVATE EXCEPTION RAISE EXCEPT
 *     GENERIC WHERE IS ABSTRACT WITH.
 *
 * Static semantics enforced after parsing (not encoded here): END-name
 * matching for modules, divisions and procedures; opaque types only in
 * definition modules; division WHEN conditions restricted to the documented
 * whitelist; assignment targets and bare statement expressions must be
 * designators or calls; duplicate names and labels; type checking.
 *
 * Entry rule: compilationUnit.
 */

grammar Hilbert;

// ---------------------------------------------------------------------------
// Compilation units
// ---------------------------------------------------------------------------

compilationUnit
    : implementationModule EOF
    | definitionModule EOF
    ;

implementationModule
    : MODULE identifier SEMI
      moduleHeader*
      (declaration | division)*
      (BEGIN statementSequence)?
      END identifier DOT
    ;

definitionModule
    : DEFINITION MODULE identifier SEMI
      moduleHeader*
      definitionDeclaration*
      END identifier DOT
    ;

// Module headers may appear only before declarations and divisions.

moduleHeader
    : importStatement
    | fromImport
    | exportStatement
    ;

importStatement : IMPORT importItem (COMMA importItem)* SEMI ;
importItem      : (identifier ASSIGN)? qualifiedName ;
fromImport      : FROM qualifiedName IMPORT identifier (COMMA identifier)* SEMI ;
exportStatement : EXPORT identifier (COMMA identifier)* SEMI ;

// ---------------------------------------------------------------------------
// Divisions: named implementation partitions inside one module.
// Declarations only; no BEGIN body. The WHEN condition parses as the
// documented DivisionCondition subset; the checker rejects conditions
// outside the whitelist (TARGET, ARCH queries, HOSTED, FREESTANDING,
// DEBUG, RELEASE, SIZE, TRUE, FALSE, AND, OR, NOT).
// ---------------------------------------------------------------------------

division
    : DIVISION identifier (WHEN divisionCondition)? SEMI
      moduleHeader*
      declaration*
      END identifier SEMI
    ;

divisionCondition : divisionOr ;
divisionOr        : divisionOr OR divisionAnd | divisionAnd ;
divisionAnd       : divisionAnd AND divisionUnary | divisionUnary ;
divisionUnary     : NOT divisionUnary | divisionPrimary ;

// HOSTED, FREESTANDING, DEBUG, RELEASE, SIZE, TARGET and ARCH are ordinary
// identifiers, so any identifier (optionally called with one string literal)
// is admitted here and validated later.

divisionPrimary
    : identifier (LPAREN stringLiteral RPAREN)?
    | TRUE
    | FALSE
    | LPAREN divisionCondition RPAREN
    ;

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

declaration
    : constSection
    | typeSection
    | subtypeSection
    | varSection
    | procedureDeclaration
    | taskDeclaration
    | foreignDeclaration
    ;

definitionDeclaration
    : constSection
    | definitionTypeSection
    | subtypeSection
    | varSection
    | procedureHeading          // definition modules declare signatures only
    | foreignDeclaration
    ;

constSection  : CONST constItem* ;
constItem     : identifier EQ expression SEMI ;

typeSection   : TYPE typeDefinition* ;
typeDefinition: identifier genericParams? EQ type SEMI ;

// Definition modules may omit "= type" to declare an opaque type.

definitionTypeSection   : TYPE definitionTypeDefinition* ;
definitionTypeDefinition: identifier genericParams? (EQ type)? SEMI ;

subtypeSection   : SUBTYPE subtypeDefinition* ;
subtypeDefinition: identifier EQ type SEMI ;

varSection : VAR varItem* ;
varItem    : identifier (COMMA identifier)* COLON type (ASSIGN expression)? SEMI ;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type
    : DISTINCT type
    | POINTER TO type
    | REF type
    | SLICE OF type
    | SET OF type
    | ARRAY expression OF type
    | ATOMIC LBRACKET type RBRACKET
    | procedureType
    | recordType
    | enumType
    | qualifiedName typeArguments? (RANGE expression DOTDOT expression)?
    ;

procedureType : PROCEDURE formalParams? (COLON type)? ;

recordType    : RECORD (LPAREN type RPAREN)? field* variantPart? END ;
field         : identifier (COMMA identifier)* COLON type SEMI ;

variantPart   : CASE identifier COLON type OF variantArm (BAR variantArm)* END ;
variantArm    : labelList COLON field* ;
labelList     : expression (COMMA expression)* ;

enumType      : LPAREN (identifier (COMMA identifier)*)? RPAREN ;
typeArguments : LBRACKET type (COMMA type)* RBRACKET ;
genericParams : LBRACKET identifier (COMMA identifier)* RBRACKET ;

// ---------------------------------------------------------------------------
// Procedures and tasks
// ---------------------------------------------------------------------------

procedureDeclaration
    : procedureHeading
      precondition*
      localSection*
      BEGIN statementSequence
      END identifier? SEMI
    ;

procedureHeading
    : PROCEDURE receiver? identifier genericParams? formalParams? (COLON type)? SEMI
    ;

receiver      : LPAREN VAR? identifier COLON type RPAREN ;
precondition  : PRE expression SEMI ;
localSection  : constSection | typeSection | subtypeSection | varSection ;

formalParams  : LPAREN (formalGroup (SEMI formalGroup)*)? RPAREN ;
formalGroup   : VAR? identifier (COMMA identifier)* COLON type ;

taskDeclaration
    : TASK identifier SEMI
      localSection*
      BEGIN statementSequence
      END identifier? SEMI
    ;

foreignDeclaration
    // FOREIGN "abi" LIBRARY "name";
    : FOREIGN STRING_LITERAL LIBRARY STRING_LITERAL SEMI
    // FOREIGN "abi" PROCEDURE Name(params): Type [VARARGS] [EXTERNAL NAME "sym"];
    | FOREIGN STRING_LITERAL PROCEDURE identifier formalParams? (COLON type)?
      VARARGS? (EXTERNAL NAME STRING_LITERAL)? SEMI
    ;

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

// At most one semicolon may follow the last statement; empty statements do
// not exist between separators.

statementSequence
    : (statement (SEMI statement)* SEMI?)?
    ;

statement
    : assignmentOrCallStatement
    | ifStatement
    | caseStatement
    | whileStatement
    | repeatStatement
    | forStatement
    | forInStatement
    | loopStatement
    | returnStatement
    | exitStatement
    | assertStatement
    | unsafeStatement
    | deferStatement
    | parallelStatement
    | blockStatement
    ;

// Any expression is admitted syntactically; the checker requires a bare
// expression to be a call statement and ":=" to have a designator target.
// START and AWAIT prefix expressions, so "START Worker;" flows through here.

assignmentOrCallStatement : expression (ASSIGN expression)? ;

ifStatement
    : IF expression THEN statementSequence
      (ELSIF expression THEN statementSequence)*
      (ELSE statementSequence)?
      END
    ;

caseStatement
    : CASE expression OF caseArm (BAR caseArm)* (ELSE statementSequence)? END
    ;

caseArm       : labelList COLON statementSequence ;

whileStatement : WHILE expression DO statementSequence END ;
repeatStatement: REPEAT statementSequence UNTIL expression ;
forStatement   : FOR identifier ASSIGN expression TO expression
                 (BY expression)? DO statementSequence END ;
forInStatement : FOR identifier IN expression DO statementSequence END ;
loopStatement  : LOOP statementSequence END ;
returnStatement: RETURN expression? ;
exitStatement  : EXIT ;
assertStatement: ASSERT expression ;
unsafeStatement: UNSAFE BEGIN statementSequence END ;
deferStatement : DEFER statement ;
blockStatement : BEGIN statementSequence END ;

parallelStatement: PARALLEL BEGIN parallelBranch (AND parallelBranch)* END ;

// Every branch is one zero-argument call of a designator; keeping branches
// this small makes the branch delimiter AND unambiguous with boolean AND.

parallelBranch : designator (LPAREN RPAREN)? ;

designator
    : identifier (DOT identifier | indexSuffix | CARET)*
    ;

qualifiedName : identifier (DOT identifier)* ;
identifier    : IDENTIFIER ;

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------
// Precedence from loosest to tightest: OR XOR, AND, relations, adding,
// multiplying, unary sign and NOT, postfixes, primaries. All binary levels
// associate left.

expression : orExpression ;

orExpression
    : orExpression op=(OR | XOR) andExpression
    | andExpression
    ;

andExpression
    : andExpression AND relationExpression
    | relationExpression
    ;

relationExpression
    : relationExpression relationalOperator addExpression
    | addExpression
    ;

relationalOperator : EQ | NEQ | LT | LE | GT | GE | IN ;

addExpression
    : addExpression op=(PLUS | MINUS) multiplyExpression
    | multiplyExpression
    ;

multiplyExpression
    : multiplyExpression op=(STAR | SLASH | DIV | MOD | SHL | SHR) unaryExpression
    | unaryExpression
    ;

unaryExpression
    : (PLUS | MINUS | NOT) unaryExpression
    | postfixExpression
    ;

postfixExpression
    : primaryExpression postfixSuffix*
    ;

postfixSuffix
    : actualParameters
    | DOT identifier
    | indexSuffix
    | CARET
    ;

indexSuffix      : LBRACKET expression (COMMA expression)* RBRACKET ;
actualParameters : LPAREN (expression (COMMA expression)*)? RPAREN ;

primaryExpression
    : identifier
    | integerLiteral
    | realLiteral
    | stringLiteral
    | characterLiteral
    | TRUE
    | FALSE
    | NIL
    | LPAREN expression RPAREN
    | setLiteral
    | SIZEOF LPAREN type RPAREN
    | ALIGNOF LPAREN type RPAREN
    | NEW LPAREN type RPAREN
    | ADR LPAREN expression RPAREN
    | START postfixExpression        // spawn task; yields a handle
    | AWAIT postfixExpression        // join task handle
    ;

setLiteral       : LBRACE (expression (COMMA expression)*)? RBRACE ;
integerLiteral   : INTEGER_LITERAL ;
realLiteral      : REAL_LITERAL ;
stringLiteral    : STRING_LITERAL ;
characterLiteral : CHARACTER_LITERAL ;

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------

// Keywords (active syntax)

MODULE      : 'MODULE' ;
DEFINITION  : 'DEFINITION' ;
IMPORT      : 'IMPORT' ;
FROM        : 'FROM' ;
EXPORT      : 'EXPORT' ;
CONST       : 'CONST' ;
TYPE        : 'TYPE' ;
SUBTYPE     : 'SUBTYPE' ;
VAR         : 'VAR' ;
PROCEDURE   : 'PROCEDURE' ;
BEGIN       : 'BEGIN' ;
END         : 'END' ;
RETURN      : 'RETURN' ;
IF          : 'IF' ;
THEN        : 'THEN' ;
ELSIF       : 'ELSIF' ;
ELSE        : 'ELSE' ;
CASE        : 'CASE' ;
OF          : 'OF' ;
WHILE       : 'WHILE' ;
DO          : 'DO' ;
FOR         : 'FOR' ;
TO          : 'TO' ;
BY          : 'BY' ;
IN          : 'IN' ;
LOOP        : 'LOOP' ;
EXIT        : 'EXIT' ;
REPEAT      : 'REPEAT' ;
UNTIL       : 'UNTIL' ;
RECORD      : 'RECORD' ;
ARRAY       : 'ARRAY' ;
SLICE       : 'SLICE' ;
SET         : 'SET' ;
POINTER     : 'POINTER' ;
REF         : 'REF' ;
DISTINCT    : 'DISTINCT' ;
RANGE       : 'RANGE' ;
TRUE        : 'TRUE' ;
FALSE       : 'FALSE' ;
NIL         : 'NIL' ;
AND         : 'AND' ;
OR          : 'OR' ;
XOR         : 'XOR' ;
NOT         : 'NOT' ;
DIV         : 'DIV' ;
MOD         : 'MOD' ;
SHL         : 'SHL' ;
SHR         : 'SHR' ;
PRE         : 'PRE' ;
ASSERT      : 'ASSERT' ;
TASK        : 'TASK' ;
START       : 'START' ;
AWAIT       : 'AWAIT' ;
PARALLEL    : 'PARALLEL' ;
ATOMIC      : 'ATOMIC' ;
UNSAFE      : 'UNSAFE' ;
FOREIGN     : 'FOREIGN' ;
EXTERNAL    : 'EXTERNAL' ;
NAME        : 'NAME' ;
LIBRARY     : 'LIBRARY' ;
VARARGS     : 'VARARGS' ;
NEW         : 'NEW' ;
DEFER       : 'DEFER' ;
SIZEOF      : 'SIZEOF' ;
ALIGNOF     : 'ALIGNOF' ;
ADR         : 'ADR' ;
DIVISION    : 'DIVISION' ;
WHEN        : 'WHEN' ;

// Reserved words: recognized by the lexer but valid in no production.
// Using one produces a front-end diagnostic naming it as reserved for a
// later language revision.

POST        : 'POST' ;
INVARIANT   : 'INVARIANT' ;
PROTECTED   : 'PROTECTED' ;
PRIVATE     : 'PRIVATE' ;
EXCEPTION   : 'EXCEPTION' ;
RAISE       : 'RAISE' ;
EXCEPT      : 'EXCEPT' ;
GENERIC     : 'GENERIC' ;
WHERE       : 'WHERE' ;
IS          : 'IS' ;
ABSTRACT    : 'ABSTRACT' ;
WITH        : 'WITH' ;

// Punctuation and operators

SEMI        : ';' ;
COMMA       : ',' ;
COLON       : ':' ;
DOT         : '.' ;
DOTDOT      : '..' ;
LPAREN      : '(' ;
RPAREN      : ')' ;
LBRACKET    : '[' ;
RBRACKET    : ']' ;
LBRACE      : '{' ;
RBRACE      : '}' ;
BAR         : '|' ;
CARET       : '^' ;
ASSIGN      : ':=' ;
EQ          : '=' ;
NEQ         : '#' ;
LT          : '<' ;
LE          : '<=' ;
GT          : '>' ;
GE          : '>=' ;
PLUS        : '+' ;
MINUS       : '-' ;
STAR        : '*' ;
SLASH       : '/' ;
ARROW       : '->' ;   // token stream only; reserved future syntax
FAT_ARROW   : '=>' ;   // token stream only; reserved future syntax

// Literals.
// Underscores are allowed only between digits. A real literal needs digits
// on both sides of the dot and at least one exponent digit.

REAL_LITERAL
    : DECIMAL_DIGITS '.' DECIMAL_DIGITS ([eE] ([+\-])? DECIMAL_DIGITS)?
    ;

INTEGER_LITERAL
    : '0' [xX] HEX_DIGITS
    | '0' [bB] BINARY_DIGITS
    | '0' [oO] OCTAL_DIGITS
    | DECIMAL_DIGITS
    ;

fragment DECIMAL_DIGITS : DIGIT (SEP? DIGIT)* ;
fragment HEX_DIGITS     : HEXDIGIT (SEP? HEXDIGIT)* ;
fragment BINARY_DIGITS  : BIT (SEP? BIT)* ;
fragment OCTAL_DIGITS   : OCTALDIGIT (SEP? OCTALDIGIT)* ;

// Underscore separator between digits of a numeric literal.

fragment SEP            : '_' ;

// Strings cannot span lines. Character literals hold exactly one Unicode
// scalar value. Recognized escapes: \n \r \t \e \" \' \\ and \uXXXX.

STRING_LITERAL : '"' ( ESCAPE | RAW_STRING_CHARACTER )* '"' ;
CHARACTER_LITERAL
    : '\'' ( ESCAPE | RAW_CHAR_CHARACTER ) '\''
    ;

fragment RAW_STRING_CHARACTER : ~["\\\r\n] ;
fragment RAW_CHAR_CHARACTER   : ~['\\\r\n] ;

fragment ESCAPE
    : '\\' ([nrte] | '"' | '\'' | '\\' | UNICODE_ESCAPE)
    ;

fragment UNICODE_ESCAPE : 'u' HEXDIGIT HEXDIGIT HEXDIGIT HEXDIGIT ;

fragment LETTER     : [A-Za-z_] ;
fragment DIGIT      : [0-9] ;
fragment BIT        : [01] ;
fragment HEXDIGIT   : [0-9A-Fa-f] ;
fragment OCTALDIGIT : [0-7] ;

IDENTIFIER : LETTER (LETTER | DIGIT)* ;

// Whitespace and comments

WS : [ \t\r\n\u000B\u000C]+ -> skip ;

LINE_COMMENT : '//' ~[\r\n]* -> skip ;

// Block comments nest, e.g. "(* outer (* inner *) still comment *)".

BLOCK_COMMENT : '(*' (BLOCK_COMMENT | .)*? '*)' -> skip ;
