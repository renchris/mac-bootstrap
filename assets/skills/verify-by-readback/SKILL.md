---
name: verify-by-readback
description: Verify work by an independent read-back — parse the file, run the program, read the resulting state — never by grepping for a string you just wrote. Use before claiming any task is done, and after writing configuration, generating a file, changing a setting, or installing anything.
---

<!-- mac-bootstrap: installed skill · replaced on update · copy this directory under another name before editing it -->

# Verify by independent read-back

A check that uses the same code path as the change can only ever confirm that the code path
ran. It cannot see a defect that lives in that code path — which is where defects live.

## The rule

**Read the end state back through a different path than the one that wrote it.**

| You wrote it by | Read it back by |
|---|---|
| writing JSON with a library | parsing it with a different parser, and checking the value |
| copying a file | comparing bytes, or parsing the copy as the document it claims to be |
| generating a script | executing it and checking what it did |
| setting a preference | asking the application, not reading the file you wrote |
| creating a symlink | resolving it, and confirming the target exists |
| adding a row | querying it back with a fresh connection |

## The anti-pattern, stated plainly

Grepping for a string you just wrote proves the string is in the file. It does not prove the
file parses, that the program loads it, that the value took effect, or that the thing you
wrote is the thing that is read at run time. It passes just as happily over a file that has
been truncated, is invalid, is at the wrong path, or is shadowed by another.

The same goes for trusting an exit code. Plenty of tools exit 0 on an unrecognised argument,
so a bare return code often proves nothing in either direction. Check the effect.

## A negative control is what makes a positive result mean something

Before trusting a check, prove it can say **no**:

- break the thing deliberately and confirm the check fails
- point the check at an empty or absent input and confirm it reports unknown, not success
- feed it a decoy that looks right and confirm it is rejected

A verifier that has only ever been observed saying yes has not been tested, whatever it says.
Most false confidence comes from checks that structurally cannot fail.

## When to run it

- after any install, generation or configuration step
- before reporting a task complete — verification is part of the task, not a courtesy
- again after any rebase, merge or environment change, because a result recalled from
  earlier in the session is not a result

If a read-back is genuinely impossible, say the claim is unverified and say why. An honest
"unproven" is worth more than a confident "done" that nobody checked.
