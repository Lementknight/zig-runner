import Runner.Model

/-!
# P5, enforcement over guessing

The property behind declared inputs (`ZIG_RUNNER_INPUTS`, experiment 5, shelved on
`feat/declared-inputs-v2`).

The mechanism is not in the shipped runner, so this module does not extend `Runner.Build`; it models
the shape of the choice instead, which is the part worth keeping. A step can be given a narrower key
in two ways:

* **enforced** — build its container from the declared files only, so what it was not given, it
  cannot read;
* **guessed** — hand it the whole workspace and key it on the guess, which is what inferring a
  step's inputs without tracing them amounts to.

The two are not variations on a theme. Enforcement discharges the obligation by construction: a
declared step's result *is* a function of its declaration, with no hypothesis about the step at all,
which is more than `Disciplined` can say for an ordinary step. Guessing is unsound, and `Guessing`
below is a job where it hands back an answer running would not have given.

What that costs is not modelled here, and it is what sank the mechanism: experiment 5 measured +28%
on flask and +85% on go-task. Riker and Rattle (docs/RELATED.md) take the third way, tracing what a
command actually read.
-/

namespace Runner.Declared

open Runner

/-! ## Workspaces and declarations -/

abbrev Path := Nat

abbrev Ws := List (Path × Content)

/-- Is the path declared? The Agda's `_∈?_`. -/
def mem? (p : Path) : List Path → Bool
  | [] => false
  | q :: qs => if p = q then true else mem? p qs

@[inherit_doc] scoped infix:50 " ∈? " => mem?

theorem mem?_cong {p q : Path} (decl : List Path) (h : p = q) : (p ∈? decl) = (q ∈? decl) := by
  rw [h]

theorem true_ne_false : true ≠ false := Bool.noConfusion

/-- The workspace a declared step is given: its declaration, and nothing else. In the prototype this
was a filter of the git tree, which Dagger keys on content (experiment 5, §9.2), so an unchanged
declaration is an unchanged key. -/
def view (decl : List Path) : Ws → Ws := List.filter (fun e => e.1 ∈? decl)

def find (p : Path) : Ws → Option Content
  | [] => none
  | e :: ws => if p = e.1 then some e.2 else find p ws

/-! ## Enforcement -/

/-- **P5.** A path the step did not declare is not in what it is given. So a step that needs it
fails — a missing file, not a stale one — instead of replaying a result computed from something it
could not see. Experiment 5 hit this twice: flit reads `LICENSE.txt` and the version out of `src`,
and both declarations failed loudly. -/
theorem undeclared_absent (p : Path) (decl : List Path) :
    ∀ (ws : Ws), (p ∈? decl) = false → find p (view decl ws) = none
  | [], _ => rfl
  | e :: ws, absent => by
    cases he : e.1 ∈? decl with
    | false =>
      simp only [view, List.filter_cons, he]
      exact undeclared_absent p decl ws absent
    | true =>
      simp only [view, List.filter_cons, he, ite_true, find]
      by_cases eq' : p = e.1
      · -- The step did not declare p, and this entry is declared, so they are different files.
        -- Otherwise p would be declared after all.
        exact absurd (((mem?_cong decl eq').trans he).symm.trans absent) true_ne_false
      · simp only [eq', ite_false]
        exact undeclared_absent p decl ws absent

/-- A change to a file the step did not declare leaves what it is given alone, so its key is
unchanged and it is replayed. This is P3 for a declared step, and unlike P3 for an ordinary one it
holds for *every* file outside the declaration rather than for a fixed list of excluded variables. -/
theorem undeclared_change_invisible (decl : List Path) (p : Path) (c : Content) (ws : Ws)
    (absent : (p ∈? decl) = false) : view decl ((p, c) :: ws) = view decl ws := by
  simp [view, absent]

/-- And a change to one it did declare is visible, so the step runs. P2. -/
theorem declared_change_visible (decl : List Path) (p : Path) (c c' : Content) (ws : Ws)
    (present : (p ∈? decl) = true) (ne : c ≠ c') :
    view decl ((p, c) :: ws) ≠ view decl ((p, c') :: ws) := by
  intro eq
  simp only [view, List.filter_cons, present, ite_true, List.cons.injEq, Prod.mk.injEq] at eq
  exact ne eq.1.2

/-- The positive half of P5: **a declared step's result is a function of its declaration**. Nothing
is assumed about the step — it may read whatever it likes, in whatever order, and it still cannot
depend on a file it was not given, because the dependence goes through `view`.

`behaviour` here is any function from a workspace to a result: what the step does, unconstrained. -/
theorem enforced_depends_only_on_the_declaration {R : Type} (behaviour : Ws → R)
    (decl : List Path) (ws ws' : Ws) (same : view decl ws = view decl ws') :
    behaviour (view decl ws) = behaviour (view decl ws') :=
  congrArg behaviour same

/-! ## Guessing

The other way: key the step on a guessed set of inputs, but run it in the whole workspace. Then the
key cannot tell two workspaces apart while the step can, and a missed input is a wrong replay rather
than a failure. -/

namespace Guessing

/-- The guess: the step is assumed to read only path 1. -/
def guess : List Path := [1]

/-- What it really reads: path 9, a file nobody listed. (`uv sync` reading `src`, a script sourcing
another script, a test reading a fixture.) -/
def run (ws : Ws) : Content :=
  match find 9 ws with
  | some c => c
  | none => 0

def before : Ws := [(1, 5), (9, 7)]

def after : Ws := [(1, 5), (9, 8)]

/-- The guessed key is the same in both... -/
theorem same_key : view guess before = view guess after := rfl

/-- ...so the second job is replayed from the first, and gets 7 where running would have given 8. -/
def replayed : Content := run before

def ran : Content := run after

theorem unsound : replayed ≠ ran := by decide

/-- Enforced instead, the same step sees no path 9 at all, so it fails rather than answering from a
file it was not given. -/
theorem enforced_sees_nothing : find 9 (view guess after) = none := rfl

end Guessing

end Runner.Declared
