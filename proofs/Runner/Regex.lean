import Runner.Prelude

/-!
# Why the regex matcher terminates, and what it costs to leave the reason out

`runner/src/regex.zig` is a backtracking matcher, and backtracking does not terminate for free: a
loop whose body matches the empty string repeats at the same position for ever. The engine stops
that with two instructions — `mark` records where an iteration began, `progress` leaves the loop
when the iteration consumed nothing — and this module is the argument that those two are enough.

The theorem is a bound, not just finiteness: **the iterations a loop takes, plus the position it
started from, cannot exceed the input** (`iterations r + pos ≤ n`), because every iteration that
continues strictly advances. Starting at zero that is `iterations r ≤ n`. The `stall` construction
at the bottom is the other half: drop the strict advance and chains of every length exist, which is
the bug the differential test found twice.

The arithmetic it needs is core's (`Nat.add_le_add_left`, `Nat.le_trans`, and `Runner.Prelude`'s
names for them), with `omega` for the rearrangements that Agda's left-recursive `+` made
definitional and Lean's right-recursive one does not.

`Run` and `Stalling` are `Type`-valued families, as the Agda's are `Set`-valued, so that
`iterations` can count them; their bound fields are propositions.
-/

namespace Runner.Regex

open Runner.Prelude

/-! ## A run of the loop

One value of `Run n pos` is one complete execution of a loop over an input of `n` bytes, starting
at `pos`. `stop` is `progress` leaving the loop (or the body failing); `step` is an iteration that
continued, and it carries the two facts the engine's instructions establish:

* `pos + 1 ≤ pos'` — the iteration consumed at least one byte. This is exactly what `progress`
  checks against the position `mark` recorded: equal means stop, so continuing means greater.
* `pos' ≤ n` — a position stays inside the input, since every instruction that advances it first
  checks `pos < input.len`. -/

inductive Run (n : Nat) : Nat → Type where
  | stop {pos : Nat} : Run n pos
  | step {pos pos' : Nat} : pos + 1 ≤ pos' → pos' ≤ n → Run n pos' → Run n pos

def iterations {n pos : Nat} : Run n pos → Nat
  | .stop => 0
  | .step _ _ rest => iterations rest + 1

/-! ## The bound

`iterations r + pos ≤ n`: the iterations already taken, plus where they started, cannot exceed the
input. So a loop starting at 0 runs at most `n` times, and the engine's step budget is a safety net
rather than the thing that makes it stop. -/

theorem bounded {n pos : Nat} (p : pos ≤ n) : (r : Run n pos) → iterations r + pos ≤ n
  | .stop => by simpa [iterations] using p
  | .step (pos' := pos') adv inside rest => by
    -- The tail's bound is about `pos'`; `pos' ≥ pos + 1` carries it back to `pos`.
    have tail : iterations rest + pos' ≤ n := bounded inside rest
    have shift : iterations rest + (pos + 1) ≤ iterations rest + pos' :=
      plus_mono (iterations rest) adv
    -- `iterations rest + (pos + 1)` is `(iterations rest + 1) + pos`, which is the goal's shape.
    have goal : iterations rest + (pos + 1) ≤ n := Nat.le_trans shift tail
    show iterations rest + 1 + pos ≤ n
    omega

/-- A loop over the whole input runs at most `n` times. -/
theorem bounded_from_zero {n : Nat} (r : Run n 0) : iterations r ≤ n :=
  bounded (Nat.zero_le n) r

/-! ## Backwards, inside lookbehind

Since regex.zig matches .NET's way, a lookbehind's body is matched right to left (`back` in the
compiler), loops included: the same `mark` and `progress`, but every instruction moves the position
down, so an iteration that continues has moved strictly *left* (`pos' + 1 ≤ pos`), and a position
never goes below 0. The mirror image of `Run`, with the mirror image of its bound: the iterations
taken cannot exceed the position the loop started from. -/

inductive RunBack : Nat → Type where
  | stop {pos : Nat} : RunBack pos
  | step {pos pos' : Nat} : pos' + 1 ≤ pos → RunBack pos' → RunBack pos

def iterationsBack {pos : Nat} : RunBack pos → Nat
  | .stop => 0
  | .step _ rest => iterationsBack rest + 1

/-- A loop matched backwards from `pos` runs at most `pos` times. -/
theorem bounded_back {pos : Nat} : (r : RunBack pos) → iterationsBack r ≤ pos
  | .stop => Nat.zero_le _
  | .step adv rest => by
    have tail := bounded_back rest
    show iterationsBack rest + 1 ≤ pos
    omega

/-! ## Why the guard is load-bearing

The same chain without the strict advance — an iteration allowed to consume nothing — has values of
every length at a single position. `stall pos p k` is `k` iterations that never move, so no bound
like `bounded` can hold for it: the iteration count is free of both `n` and `pos`.

This is not hypothetical. `runner/src/regex.zig` shipped twice without this guard in one of its two
places, and the differential test against Python and Perl found both:

* no guard on a star: `(x*?)+` reached the step budget on 38 inputs Python answers.
* no guard on a *bounded* repeat: `(\s{0,2}|…){0,2}` ran an empty iteration and then a non-empty
  one, capturing the wrong text, because the references stop at the empty iteration.

So `Stalling` is the shape of the bug and `Run` is the shape of the fix. -/

inductive Stalling (n : Nat) : Nat → Type where
  | stop {pos : Nat} : Stalling n pos
  | step {pos pos' : Nat} : pos ≤ pos' → pos' ≤ n → Stalling n pos' → Stalling n pos

def stallIterations {n pos : Nat} : Stalling n pos → Nat
  | .stop => 0
  | .step _ _ rest => stallIterations rest + 1

/-- `k` iterations, none of which moves: a loop at one position, as long as you like. -/
def stall {n : Nat} (pos : Nat) (p : pos ≤ n) : Nat → Stalling n pos
  | 0 => .stop
  | k + 1 => .step (Nat.le_refl pos) p (stall pos p k)

theorem stall_length {n : Nat} (pos : Nat) (p : pos ≤ n) :
    ∀ k : Nat, stallIterations (stall pos p k) = k
  | 0 => rfl
  | k + 1 => congrArg (· + 1) (stall_length pos p k)

/-- So no function of `n` bounds a stalling loop: for any candidate bound `b`, there is a run longer
than it. Instantiated at `pos = 0`, where `Run` gives `iterations r ≤ n`. (The Agda's `Σ` over the
`Set` of runs is a `Subtype` here, so the run itself is data, as it is there.) -/
def unbounded {n : Nat} (b : Nat) : { s : Stalling n 0 // stallIterations s = b + 1 } :=
  ⟨stall 0 (Nat.zero_le n) (b + 1), stall_length 0 (Nat.zero_le n) (b + 1)⟩

end Runner.Regex
