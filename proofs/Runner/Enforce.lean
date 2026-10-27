import Runner.Build

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

The event payload is the same case by another path (#68). The runner withheld the volatile
variables but wrote the payload in full to every step's `$GITHUB_EVENT_PATH`, so a script that read
it from a file was replayed with an earlier run's (`Counterexamples.EventRead`). Now an unmarked
step finds `withheld_event` there, the sentinel as a JSON string: `withheldEvent` here.

The last section composes this with `Runner.Build`: the job run with every unmarked step given only
what its key keeps satisfies P1 under determinism and mount-blindness alone
(`replay_eq_run_enforced`).

The Agda module's parameter `vol` is a section variable.
-/

namespace Runner.Enforce

open Runner Runner.Prelude Runner.Build

/-- What an unmarked step finds at `$GITHUB_EVENT_PATH`: `withheld_event` in dagger.zig. Which
constant it is does not matter to any theorem, only that it is the same in every run. -/
def withheldEvent : Content := 0

section
variable (vol : Volatile)

/-- What an unmarked step is given: the bindings its key keeps. -/
def withheld : Env → Env := stable vol

/-- An input with everything outside the key that varies between runs replaced: the variables
withheld, and the payload replaced by `withheldEvent`. (The mounts are outside the key too, but they
do not vary between runs by the runner's doing; what is in them is mount-blindness's question.) -/
def withhold (i : Input) : Input := { i with env := withheld vol i.env, event := withheldEvent }

/-- The input of an unmarked step under enforcement. The marked ones are unchanged: they get the
real values, the payload included, and their keys carry the job's nonce, so they are never
replayed. -/
def inputPlain (s : State) (e : Env) (ev : Content) (st : Step) : Input :=
  withhold vol ⟨s, .body st.text st.num, e, ev, st.mounts⟩

def keyPlain (s : State) (e : Env) (ev : Content) (st : Step) : Key :=
  keyOf vol (inputPlain vol s e ev st)

/-! ## What enforcement establishes -/

/-- The environment an unmarked step is given is already filtered, so filtering it again — which is
what the key does — changes nothing. -/
theorem key_keeps_everything (s : State) (e : Env) (ev : Content) (st : Step) :
    (keyPlain vol s e ev st).kEnv = (inputPlain vol s e ev st).env :=
  show stable vol (stable vol e) = stable vol e from filter_idempotent (fun b : Binding => !vol b.1) e

/-- **The input is a function of the key.** Two jobs whose unmarked step has the same key gave it
the same input — the same container, the same script, the same environment, the same payload file,
the same mounts — whatever their payloads were. Nothing about the run is left for the step to
notice. -/
theorem input_determined_by_key (s : State) (e e' : Env) (ev ev' : Content) (st : Step)
    (k : keyPlain vol s e ev st = keyPlain vol s e' ev' st) :
    inputPlain vol s e ev st = inputPlain vol s e' ev' st :=
  congrArg (fun x => Input.mk s (.body st.text st.num) x withheldEvent st.mounts)
    ((key_keeps_everything vol s e ev st).symm.trans
      ((congrArg Key.kEnv k).trans (key_keeps_everything vol s e' ev' st)))

/-- So **the volatile clause of `Disciplined` is discharged**: for an unmarked step, equal keys give
equal results as soon as the step is deterministic. Nothing has to be assumed about what it reads
from the environment or the payload file, because there is nothing there that varies.

What remains to assume is determinism, and that a step does not depend on the content of a mounted
cache volume — which is the same `Step.mounts` on both sides here, and so is counterexample 4's
territory rather than this one's. -/
theorem volatile_clause_discharged (exec : Input → Trial → Output)
    (deterministic : ∀ (i : Input) (t t' : Trial), exec i t = exec i t')
    (s : State) (e e' : Env) (ev ev' : Content) (st : Step) (t t' : Trial)
    (k : keyPlain vol s e ev st = keyPlain vol s e' ev' st) :
    exec (inputPlain vol s e ev st) t = exec (inputPlain vol s e' ev' st) t' := by
  rw [input_determined_by_key vol s e e' ev ev' st k]
  exact deterministic _ t t'

/-- And the hole is closed at its source: a step that reads a volatile value is handed the same
thing in every run, whatever it reads and however it reaches it. This is the statement
counterexample 1 violates today. -/
theorem nothing_volatile_survives (n : Name) (c : Content) (e : Env) (ev : Content) (s : State)
    (st : Step) (v : vol n = true) : inputPlain vol s ((n, c) :: e) ev st = inputPlain vol s e ev st := by
  simp [inputPlain, withhold, withheld, stable, v]

/-- The same for the payload (#68): whatever the event, an unmarked step is handed the same input,
with `withheldEvent` where the payload was. `Counterexamples.EventRead` is what this rules out. -/
theorem no_payload_survives (s : State) (e : Env) (ev ev' : Content) (st : Step) :
    inputPlain vol s e ev st = inputPlain vol s e ev' st :=
  rfl

/-! ## P1 under enforcement

The runner, with `RUNNER_ENFORCE_VOLATILE` on, gives a step whose script carries no nonce the
withheld input, and a marked one the real input. In the model a step is marked exactly when its
script is stamped, so that is a change to what `exec` is handed, and `Runner.Build` can be run with
it unchanged. -/

/-- What a step is handed under enforcement: withheld if unmarked, the real input if marked. -/
def given (i : Input) : Input :=
  match i.script with
  | .body _ _ => withhold vol i
  | .stamped _ _ => i

/-- The step as the enforcing runner runs it. -/
def enforced (exec : Input → Trial → Output) : Input → Trial → Output :=
  fun i t => exec (given vol i) t

/-- An unmarked step of the job is handed `inputPlain`, what the theorems above are about. -/
theorem given_plain (t : Trial) (s : State) (e : Env) (ev : Content) (st : Step) :
    given vol (inputFor t s e ev st .plain) = inputPlain vol s e ev st :=
  rfl

end

/-- The step gives the same result every time it is handed the same input — if its script carries
no nonce. Marked steps may be as flaky as they like: they are never replayed. -/
def Deterministic (exec : Input → Trial → Output) : Prop :=
  ∀ (i : Input) (t t' : Trial), Unstamped i.script → exec i t = exec i t'

/-- The step's result does not depend on what is in its mounted cache volumes — again only for a
step whose script carries no nonce. This is the obligation counterexample 4 breaks, and the one the
runner still assumes rather than enforces. -/
def MountBlind (exec : Input → Trial → Output) : Prop :=
  ∀ (i : Input) (m : Mounts) (t : Trial), Unstamped i.script → exec { i with mounts := m } t = exec i t

/-- **Enforcement discharges the volatile clause of `Disciplined`.** A deterministic, mount-blind
step, run as the enforcing runner runs it, is disciplined: nothing about volatile variables or the
event payload is assumed, because an unmarked step is handed none. -/
theorem enforced_disciplined (vol : Volatile) (exec : Input → Trial → Output)
    (det : Deterministic exec) (mb : MountBlind exec) : Disciplined vol (enforced vol exec) := by
  intro ⟨ip, isc, ie, iev, im⟩ ⟨jp, jsc, je, jev, jm⟩ t t' hk hu
  simp only [K, keyOf, Key.mk.injEq] at hk
  obtain ⟨hp, hs, he⟩ := hk
  subst hp hs
  cases isc with
  | stamped _ _ => exact hu.elim
  | body b n =>
    show exec ⟨ip, .body b n, stable vol ie, withheldEvent, im⟩ t
      = exec ⟨ip, .body b n, stable vol je, withheldEvent, jm⟩ t'
    rw [he]
    exact (mb ⟨ip, .body b n, stable vol je, withheldEvent, jm⟩ im t trivial).trans
      (det _ t t' trivial)

/-- **P1 under enforcement.** The job run with the step cache, every unmarked step handed only what
its key keeps, produces what the same job produces with the step cache off — for any deterministic,
mount-blind step. This is `replay_eq_run` with `Disciplined` replaced by those two obligations:
the third, that a step reads no volatile value, is not a hypothesis any more.

The comparison is with `uncached` for the same enforced step, the job run without the cache but with
the withholding; with `RUNNER_STEP_CACHE=false` the runner withholds nothing, so a step that prints
a run-specific value it did not name prints the real one there. -/
theorem replay_eq_run_enforced (vol : Volatile) (exec : Input → Trial → Output)
    (det : Deterministic exec) (mb : MountBlind exec) (md : Mode) (t : Trial) (n : Nat)
    (p : Progress) (job : List Step) (nums : Numbered n job)
    (co : Coherent vol (enforced vol exec) p.cache) (ah : Ahead t n p.cache) :
    (build vol (enforced vol exec) md t p job).outs
      = uncached vol (enforced vol exec) md t p.event p.state p.env p.outs job :=
  replay_eq_run vol (enforced vol exec) (enforced_disciplined vol exec det mb) md t n p job nums co ah

end Runner.Enforce
