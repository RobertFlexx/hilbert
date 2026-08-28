# unsafe stuff and borrowing

safe hilbert tries to make raw operations look raw. `REF` is managed, `POINTER TO` and `ADDRESS` are not. raw pointer dereference and indexing need `UNSAFE`, and an address does not quietly become a managed reference because both happen to fit in a register. `NIL` is the ordinary null exception to that rule.

## `VAR`

`VAR` gives the callee exclusive access for that call. the borrow checker rejects obvious aliases:

```text
Swap(X, X);
```

fields and indexes from the same root are handled conservatively. that can reject an awkward call now and then, which is preferable to teaching procedures that two supposedly exclusive arguments might secretly be the same storage.

safe procedures cannot return an address into their own stack either:

```text
PROCEDURE Bad(): ADDRESS;
VAR X: INTEGER;
BEGIN
    RETURN ADR(X)
END Bad;
```

managed sharing uses `REF`. raw pointers are there when raw is actually what you mean.

## indexes and ranges

arrays and slices are checked unless the compiler proves a particular check cannot fail. range checks happen when values cross the places where the narrower type matters. raw pointer indexes do not have a hidden length, so there is nothing honest for the compiler to check there.

## assertions

`PRE` and `ASSERT` take `BOOLEAN` expressions and lower to runtime assertions in the current backend. `POST` is reserved in the 1.0 language rather than pretending a result contract works when it does not yet.
