# Domain language

The words Jumbini's code uses, and what each one means here. A term earns a place
in this file when it names a decision rather than a mechanism — if you could work
out what it does from its type, it does not need an entry.

## The dog

**Brain** — `DogBrain`, the pure state machine that decides what the dog does. It
imports `Foundation` and `CoreGraphics` and nothing else. It never knows why a
signal arrived, only that one did.

**Effect** — `DogEffect`, one thing the scene should do as a result of a decision:
play an animation, move to a point, drop a ball. Deliberately signal-agnostic, so
by the time effects come back nothing in them says *why*. That is what keeps
user-facing text out of the brain.

**Scene** — `PetScene`, the only layer that turns effects into pixels, and the
only one that still knows a signal's name.

**Mood** — the three persistent switches from the dog's right-click menu:
activity level, the stay-lying-down hold, and whether he follows the cursor. Kept
deliberately apart from `JumbiniSettings`, whose panel rebuilds the whole struct
from its checkboxes and would reset anything else stored there.

## Tidy

**Pass** — one run of Tidy over the chosen folder. A pass either completes, is
halted at a file boundary because the user came back, or fails. Failing aborts
the whole run, so the files after the failure were never considered.

**Notice** — `TidyNotice`, what Tidy tells the user after a pass: completed,
halted, undone, or failed. Rendered in the status-item popover. Idle passes must
not interrupt, so a notice is text rather than an alert.

**Blocking error** — the reason Tidy currently cannot run at all, as opposed to
the reason one pass stopped. It persists in `TidyCoordinator.State` and shows in
red in the Settings panel until it is resolved. A notice fades; a blocking error
stays.

**Failure text** — `TidyFailureText`, the one module that turns any Tidy error
into the sentence a user reads. Both surfaces above go through it, so one failure
cannot be described two ways at once. Its switches are exhaustive per error type
on purpose: the `as?` chain it replaced had no exhaustiveness, which is how four
`TidyExecutionError` cases went without any wording at all and reached users as
`The operation couldn't be completed. (Jumbini.TidyExecutionError error 3.)`.

**Preview gate** — the rule that a newly chosen folder must have its plan reviewed
once before Tidy will move anything in it.
