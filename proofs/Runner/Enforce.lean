import Runner.Model

/-!
# Closing the enforcement gap for volatile variables

P1 (`replay_eq_run` in `Runner.Build`) holds under one hypothesis, `Disciplined`, which bundles
three obligations on a step the runner does not mark always-run: it is deterministic, it does not
consult a volatile variable, and it does not depend on the content of a mounted cache volume. The
runner enforces none of them. It *detects* the second, syntactically, by looking for the variable's
name in the script text — and counterexample 1 is a step that reads the value without ever spelling
the name, which the live suite confirms is replayed with a stale answer.

Detection cannot be made sound: a script can reach the value through a file it sources, a program
that reads the environment, or a name it builds from pieces. So do what P5 does for files and
`Runner.Declared` proves about them — **give the step only what its key keeps**. An unmarked step is
handed the stable environment and nothing else. Then its input is a function of its key, and the
volatile clause of `Disciplined` is not an assumption any more.

The implementation will set a constant, visible sentinel rather than unset the variables: a
constant satisfies every theorem here (what matters is that it does not vary between runs), it
keeps `$GITHUB_SHA` non-empty for a script under `set -u`, and a step whose output contains it has
announced that it read a value it did not declare — which turns a silent blind spot into a line in
a log.

The Agda module's parameter `vol` is a section variable.
-/

namespace Runner.Enforce

open Runner Runner.Prelude

section
variable (vol : Volatile)

/-- What an unmarked step is given: the bindings its key keeps. -/
def withheld : Env → Env := stable vol

/-- The input of an unmarked step under enforcement. The marked ones are unchanged: they get the
real values, and their keys carry the job's nonce, so they are never replayed. -/
def inputPlain (s : State) (e : Env) (st : Step) : Input :=
  ⟨s, .body st.text st.num, withheld vol e, st.mounts⟩

def keyPlain (s : State) (e : Env) (st : Step) : Key := keyOf vol (inputPlain vol s e st)

/-! ## What enforcement establishes -/

/-- The environment an unmarked step is given is already filtered, so filtering it again — which is
what the key does — changes nothing. -/
theorem key_keeps_everything (s : State) (e : Env) (st : Step) :
    (keyPlain vol s e st).kEnv = (inputPlain vol s e st).env :=
  show stable vol (stable vol e) = stable vol e from filter_idempotent (fun b : Binding => !vol b.1) e

/-- **The input is a function of the key.** Two jobs whose unmarked step has the same key gave it
the same input — the same container, the same script, the same environment, the same mounts.
Nothing about the run is left for the step to notice. -/
theorem input_determined_by_key (s : State) (e e' : Env) (st : Step)
    (k : keyPlain vol s e st = keyPlain vol s e' st) : inputPlain vol s e st = inputPlain vol s e' st :=
  congrArg (fun x => Input.mk s (.body st.text st.num) x st.mounts)
    ((key_keeps_everything vol s e st).symm.trans
      ((congrArg Key.kEnv k).trans (key_keeps_everything vol s e' st)))

/-- So **the volatile clause of `Disciplined` is discharged**: for an unmarked step, equal keys give
equal results as soon as the step is deterministic. Nothing has to be assumed about what it reads
from the environment, because there is nothing in the environment that varies.

What remains to assume is determinism, and that a step does not depend on the content of a mounted
cache volume — which is the same `Step.mounts` on both sides here, and so is counterexample 4's
territory rather than this one's. -/
theorem volatile_clause_discharged (exec : Input → Trial → Output)
    (deterministic : ∀ (i : Input) (t t' : Trial), exec i t = exec i t')
    (s : State) (e e' : Env) (st : Step) (t t' : Trial)
    (k : keyPlain vol s e st = keyPlain vol s e' st) :
    exec (inputPlain vol s e st) t = exec (inputPlain vol s e' st) t' := by
  rw [input_determined_by_key vol s e e' st k]
  exact deterministic _ t t'

/-- And the hole is closed at its source: a step that reads a volatile value is handed the same
thing in every run, whatever it reads and however it reaches it. This is the statement
counterexample 1 violates today. -/
theorem nothing_volatile_survives (n : Name) (c : Content) (e : Env) (s : State) (st : Step)
    (v : vol n = true) : inputPlain vol s ((n, c) :: e) st = inputPlain vol s e st := by
  simp [inputPlain, withheld, stable, v]

end

end Runner.Enforce
