import Runner.Model

/-!
# The algorithm, and what it does and does not guarantee

Parameters: which variable names are run-specific (`volatile_env` in dagger.zig), and what a step
does. `exec` takes the trial as well as the input, so a step is not forced to be a function of its
inputs: a flaky test is a perfectly good inhabitant of this type, and the properties that need it
not to be have to say so.

The Agda module is parameterised (`module Runner.Build (vol : Volatile) (exec : …)`); here the two
are section variables, so every definition that uses them takes them as its first explicit
arguments (`build vol exec md t p job`). Where the Agda returned a `Set` that is only ever used as a
proposition (`Honest`, `Coherent`, `Ahead`, `Disciplined`, `Warm`, the `Σ` in `look-found`, the `⊎`
in `step-runs-at-most-once`), the Lean returns a `Prop`, with `∃` and `∨` for `Σ` and `⊎`.

Since the Agda port the model has three things more, each from a fix to the runner: the event
payload as an input outside the key (`Input.event`, `Progress.event`, #68), an exit code in every
output with the rule that a recorded failure is a miss (`replayable`, #69), and a failed marked step
not being output-keyed (`nextState`).
-/

namespace Runner.Build

open Runner Runner.Prelude

section
variable (vol : Volatile) (exec : Input → Trial → Output)

def K : Input → Key := keyOf vol

/-! ## The scheduler and the rebuilder -/

/-- Whether the runner must not let this step be replayed: it consults a name whose value differs
between runs while the key does not, or the event payload. `readsRunSpecific` in dagger.zig, which
also marks steps that use secrets or can mint OIDC tokens; those are the same case, since what they
produce depends on something no key holds. -/
inductive Mark where
  | plain
  | everyRun
  deriving DecidableEq, Repr

def mark (st : Step) : Mark :=
  match st.reads.any vol || st.readsEvent with
  | true => .everyRun
  | false => .plain

/-- The input a step is run on: the container it starts from, its script, the container's
variables, the event payload, and what is mounted. Marking it costs a script that no other job can
have produced, because the job's nonce is written into the script text and the script text is part
of the key. -/
def inputFor (t : Trial) (s : State) (e : Env) (ev : Content) (st : Step) : Mark → Input
  | .plain => ⟨s, .body st.text st.num, e, ev, st.mounts⟩
  | .everyRun => ⟨s, .stamped t (.body st.text st.num), e, ev, st.mounts⟩

/-- `RUNNER_OUTPUT_KEYS`. -/
inductive Keys where
  | off
  | on
  deriving DecidableEq, Repr

/-- Per step, not per job: `outputKeyed` falls back to the step's own container whenever anything
goes wrong (a query without a field the runner needs, a session that went away), and that is the
`off` behaviour for that one step. Two of the trial's 189 jobs did exactly this. So the mode is a
function of the step, and every theorem below holds for any such function. -/
abbrev Mode := Nat → Keys

def always (k : Keys) : Mode := fun _ => k

/-- The container the next step starts from.

Normally it is the one this exec left, whose identity is this exec's recipe — nonce and all, which
is why a marked step makes every step after it new. With output keys on, a marked step that
*succeeded* instead hands on the container it started from with what it produced copied in by digest
(`outputKeyed`), so what the next step starts from says what was produced and not who produced it.
A marked step that failed is not output-keyed (`execScript` asks `out.code == 0`): it hands on its
own container, as with output keys off. -/
def nextState : Keys → Trial → State → Env → Content → Step → Mark → Output → State
  | .off, t, s, e, ev, st, m, _ => stateOf (K vol (inputFor t s e ev st m))
  | .on, t, s, e, ev, st, .plain, _ => stateOf (K vol (inputFor t s e ev st .plain))
  | .on, t, s, e, ev, st, .everyRun, o =>
    if o.code = 0 then .afterCopy s o.digest else stateOf (K vol (inputFor t s e ev st .everyRun))

/-- Where a job has got to. `event` is the job's event payload, the same for every step of it. -/
structure Progress where
  state : State
  env : Env
  event : Content
  cache : Cache
  ran : Nat
  outs : List Output

/-- The input the step at the head of the job runs on. -/
def inputAt (t : Trial) (p : Progress) (st : Step) (m : Mark) : Input :=
  inputFor t p.state p.env p.event st m

/-- **A recorded failure is a miss** (#69). The engine records failed execs too, and replaying one
would fail every re-run the same way until an input changed, though the step may have failed for a
reason that has passed. So `execScript` discards a cache answer that is a failure from an earlier
run and runs the step again. Every hit in the model is from an earlier run (`Ahead`), so the rule
is: a hit counts only if it succeeded.

The runner runs the step again *stamped* with the run's nonce, so its result is recorded under a new
key and it hands on a new container. Here it runs again under its own mark, as any miss does, and is
recorded under the key it missed on. The two differ in which keys later steps ask and later jobs
find — misses and hits, not answers: either way the step's result is what running it gives, and the
model's version is the one `uncached` can be compared with step for step. -/
def replayable : Option Output → Option Output
  | some o => if o.code = 0 then some o else none
  | none => none

theorem replayable_some {r : Option Output} {o : Output} (h : replayable r = some o) :
    r = some o ∧ o.code = 0 := by
  cases r with
  | none => exact nomatch h
  | some o' =>
    by_cases hc : o'.code = 0
    · simp only [replayable, hc, ite_true, Option.some.injEq] at h
      subst h; exact ⟨rfl, hc⟩
    · simp only [replayable, hc, ite_false, reduceCtorEq] at h

/-- What the step contributes: the recorded output on a hit, a run on a miss. -/
def produced (t : Trial) (p : Progress) (st : Step) (m : Mark) : Option Output → Output
  | some o => o
  | none => exec (inputAt t p st m) t

/-- A miss records what it ran, under the key it ran with. -/
def addEntry (t : Trial) (p : Progress) (st : Step) (m : Mark) : Option Output → Cache
  | some _ => p.cache
  | none => (K vol (inputAt t p st m), exec (inputAt t p st m) t) :: p.cache

def ranAfter (p : Progress) : Option Output → Nat
  | some _ => p.ran
  | none => p.ran + 1

/-- The variables the next step sees: what the step exported, on top of what the container already
had. A replayed step exports what it exported when it ran, because the runner reads the file
commands out of the cached result. -/
def nextEnv (e : Env) (o : Output) : Env := o.sets ++ e

/-- The rebuilder, in Build Systems à la Carte's sense: a verifying trace. A hit replays the
recorded output; a miss runs the step and records it. Everything the rest of the job sees of this
step — the container it hands on and the output it contributes — goes through `produced`, which is
what makes replay transparent when `produced` is right. -/
def advance (md : Mode) (t : Trial) (p : Progress) (st : Step) (m : Mark) (r : Option Output) :
    Progress :=
  ⟨nextState vol (md st.num) t p.state p.env p.event st m (produced exec t p st m r),
   nextEnv p.env (produced exec t p st m r),
   p.event,
   addEntry vol exec t p st m r,
   ranAfter p r,
   produced exec t p st m r :: p.outs⟩

/-- One step: look the key up, and replay what is found if it is `replayable`. -/
def stepOnce (md : Mode) (t : Trial) (p : Progress) (st : Step) : Progress :=
  advance vol exec md t p st (mark vol st)
    (replayable (look (K vol (inputAt t p st (mark vol st))) p.cache))

/-- The scheduler: a job's steps, in order. GitHub Actions gives no choice here, which is why the
interesting questions are all about the rebuilder. -/
def build (md : Mode) (t : Trial) : Progress → List Step → Progress
  | p, [] => p
  | p, st :: sts => build md t (stepOnce vol exec md t p st) sts

/-- The same job with the step cache off: every step runs. The outputs come back in reverse, as
`Progress.outs` collects them. The event payload `ev` is the job's, the same for every step. -/
def uncached (md : Mode) (t : Trial) (ev : Content) : State → Env → List Output → List Step → List Output
  | _, _, acc, [] => acc
  | s, e, acc, st :: sts =>
    uncached md t ev
      (nextState vol (md st.num) t s e ev st (mark vol st) (exec (inputFor t s e ev st (mark vol st)) t))
      (nextEnv e (exec (inputFor t s e ev st (mark vol st)) t))
      (exec (inputFor t s e ev st (mark vol st)) t :: acc) sts

theorem uncached_cong (md : Mode) (t : Trial) (ev : Content) {s s' : State} {e e' : Env}
    {acc acc' : List Output} (sts : List Step) (hs : s = s') (he : e = e') (hacc : acc = acc') :
    uncached vol exec md t ev s e acc sts = uncached vol exec md t ev s' e' acc' sts := by
  subst hs he hacc; rfl

/-! ## P2 and P3: what the key keeps, and what it forgets

MEASURE.md asks for one generated case per input kind. Here they are as theorems instead: for the
inputs the key keeps, a change makes a different key; for the ones it forgets, no change can. -/

/-- P2, script text. -/
theorem text_matters {s : State} {e : Env} {ev : Content} {m : Mounts} {b b' : Body} {n : Nat}
    (ne : b ≠ b') : K vol ⟨s, .body b n, e, ev, m⟩ ≠ K vol ⟨s, .body b' n, e, ev, m⟩ :=
  fun k => ne (body_injective₁ (congrArg Key.kScript k))

/-- And the step's position, which the script text carries whether the workflow author wanted it to
or not. -/
theorem position_matters {s : State} {e : Env} {ev : Content} {m : Mounts} {b : Body} {n n' : Nat}
    (ne : n ≠ n') : K vol ⟨s, .body b n, e, ev, m⟩ ≠ K vol ⟨s, .body b n', e, ev, m⟩ :=
  fun k => ne (body_injective₂ (congrArg Key.kScript k))

/-- P2, the container the step starts from. This is the one that carries the checkout: a new commit
gives a new workspace, so every step after the checkout has a new parent, which is why the commit
itself can be volatile. -/
theorem parent_matters {s s' : State} {sc : Script} {e : Env} {ev : Content} {m : Mounts}
    (ne : s ≠ s') : K vol ⟨s, sc, e, ev, m⟩ ≠ K vol ⟨s', sc, e, ev, m⟩ :=
  fun k => ne (congrArg Key.kParent k)

/-- P2, a binding the key keeps. -/
theorem stable_env_matters {s : State} {sc : Script} {e e' : Env} {ev : Content} {m : Mounts}
    (ne : stable vol e ≠ stable vol e') : K vol ⟨s, sc, e, ev, m⟩ ≠ K vol ⟨s, sc, e', ev, m⟩ :=
  fun k => ne (congrArg Key.kEnv k)

/-- P3, mounted cache volumes. Nothing about a mount reaches the key: this is BuildKit excluding
mounts from an exec's cache key, and it is the reason the package caches can be shared without
making every step miss. -/
theorem mounts_invisible {s : State} {sc : Script} {e : Env} {ev : Content} {m m' : Mounts} :
    K vol ⟨s, sc, e, ev, m⟩ = K vol ⟨s, sc, e, ev, m'⟩ :=
  rfl

/-- P3, a volatile binding. Changing the run id or the actor leaves the key untouched, so steps
that do not consult them are replayed. -/
theorem volatile_invisible (n : Name) (c c' : Content) {e : Env} {s : State} {sc : Script}
    {ev : Content} {m m' : Mounts} (v : vol n = true) :
    K vol ⟨s, sc, (n, c) :: e, ev, m⟩ = K vol ⟨s, sc, (n, c') :: e, ev, m'⟩ := by
  simp [K, keyOf, stable, v]

/-- P3, the event payload (#68). It is in no key, so two runs of a workflow with different payloads
ask the same keys, and a step that reads the payload without being marked is replayed with an
earlier run's: `Counterexamples.EventRead`. -/
theorem event_invisible {s : State} {sc : Script} {e : Env} {ev ev' : Content} {m : Mounts} :
    K vol ⟨s, sc, e, ev, m⟩ = K vol ⟨s, sc, e, ev', m⟩ :=
  rfl

/-! ## Why two steps of one job never collide

Not because of the step number in the script, though that is in the key too (`position_matters`).
Because each step starts from the container the last one left, so the chain only grows, and the
parent is in the key. -/

def depth : State → Nat
  | .base _ => 0
  | .afterExec s _ _ => depth s + 1
  | .afterCopy s _ => depth s + 1

theorem depth_advances (ks : Keys) (t : Trial) (s : State) (e : Env) (ev : Content) (st : Step)
    (m : Mark) (o : Output) : depth (nextState vol ks t s e ev st m o) = depth s + 1 := by
  cases ks <;> cases m <;> try rfl
  simp only [nextState]
  split <;> rfl

/-- So a key asked from a deeper container is a different key, whatever the script, the
environment or the mounts. -/
theorem deeper_keys_differ {i j : Input} (nd : depth i.parent ≠ depth j.parent) : K vol i ≠ K vol j :=
  fun eq => nd (congrArg (fun k => depth k.kParent) eq)

/-! ## What a cache has to be for a replay to stand in for a run -/

/-- An entry is honest when some run of some input with that key really produced it. This is all
the engine can promise: it recorded what it saw. -/
def Honest (k : Key) (o : Output) : Prop := ∃ (i : Input) (t : Trial), K vol i = k ∧ exec i t = o

def Coherent (c : Cache) : Prop := ∀ {k : Key} {o : Output}, (k, o) ∈ c → Honest vol exec k o

theorem coherent_cons {k : Key} {o : Output} {c : Cache} (h : Honest vol exec k o)
    (co : Coherent vol exec c) : Coherent vol exec ((k, o) :: c) := by
  intro k' o' mem
  cases mem with
  | head => exact h
  | tail _ m => exact co m

/-- Nothing in the cache was recorded by this job for a step numbered `n` or later.

Two mechanisms keep this true, and the model needs both. Across jobs it is the nonce: a marked
step's key names the job (`run_nonce` is the run, the attempt and the job), so no other job can have
left an entry under it. Within a job it is the step's position, which the script text carries, so
the entry a step leaves cannot be found by any later step. -/
def Ahead (t : Trial) (n : Nat) (c : Cache) : Prop :=
  ∀ {k : Key} {o : Output}, (k, o) ∈ c →
    ∀ (b : Body) (i : Nat), k.kScript = .stamped t (.body b i) → ¬ n ≤ i

theorem ahead_loosen {t : Trial} {n : Nat} {c : Cache} (ah : Ahead t n c) : Ahead t (n + 1) c :=
  fun mem b i eq le => ah mem b i eq (le_loosen le)

theorem ahead_cons {t : Trial} {n : Nat} {k : Key} {o : Output} {c : Cache}
    (new : ∀ (b : Body) (i : Nat), k.kScript = .stamped t (.body b i) → ¬ (n + 1 ≤ i))
    (ah : Ahead t (n + 1) c) : Ahead t (n + 1) ((k, o) :: c) := by
  intro k' o' mem
  cases mem with
  | head => exact new
  | tail _ m => exact ah m

/-- The hypothesis the step cache rests on, for the steps that are not marked: inputs that agree on
everything the key keeps give the same result, whatever job they are part of. It bundles three
separate obligations — the step is deterministic, it does not consult a volatile variable (or the
event payload), and it does not depend on the content of a mounted cache volume — and the runner
enforces none of them. `Runner.Counterexamples` breaks each one. `Runner.Enforce` discharges the
second by construction (`Enforce.enforced_disciplined`). -/
def Disciplined : Prop :=
  ∀ (i j : Input) (t t' : Trial), K vol i = K vol j → Unstamped i.script → exec i t = exec j t'

/-- Determinism is not a separate assumption: it is part of `Disciplined`, which is the honest way
to record that the step cache cannot be sound for a flaky step that is not marked always-run. -/
theorem disciplined_deterministic (d : Disciplined vol exec) (i : Input) (t t' : Trial)
    (u : Unstamped i.script) : exec i t = exec i t' :=
  d i i t t' rfl u

/-! ## What a hit must hand back -/

/-- A hit on this step holds what running the step now would produce. This is P1 for one step, and
it is the thing that has to hold every time a step is replayed. -/
def Replays (t : Trial) (c : Cache) (s : State) (e : Env) (ev : Content) (st : Step) (m : Mark) :
    Prop :=
  ∀ o : Output, look (K vol (inputFor t s e ev st m)) c = some o → exec (inputFor t s e ev st m) t = o

/-- A marked step cannot hit at all: its key names this job and its own position. -/
theorem marked_misses {t : Trial} {c : Cache} (s : State) (e : Env) (ev : Content) (st : Step)
    (ah : Ahead t st.num c) : look (K vol (inputFor t s e ev st .everyRun)) c = none :=
  look_miss _ _ (fun _ mem => ah mem st.text st.num rfl (Nat.le_refl _))

/-- An unmarked step's hit is honest, and honest is enough once the step is disciplined. The two
cases are the whole design: either the result depends only on what the key keeps, or the step is
marked and does not get replayed. -/
theorem unmarked_replays (d : Disciplined vol exec) {t : Trial} {c : Cache} (s : State) (e : Env)
    (ev : Content) (st : Step) (co : Coherent vol exec c) : Replays vol exec t c s e ev st .plain := by
  intro o eq
  obtain ⟨j, t', kj, ej⟩ := co (look_sound _ _ eq)
  exact (d _ j _ t' kj.symm trivial).trans ej

/-! ## A replayed result is a success (#69) -/

/-- **A step that was not run contributed a success.** Whatever the cache holds — failures included,
recorded by this job's earlier runs or by any other job — a step the runner did not run hands on a
result whose exit code is 0. Before #69 a flaky failure was replayed on every re-run. -/
theorem replayed_succeeds (md : Mode) (t : Trial) (p : Progress) (st : Step)
    (h : (stepOnce vol exec md t p st).ran = p.ran) :
    ∃ o, (stepOnce vol exec md t p st).outs = o :: p.outs ∧ o.code = 0 := by
  revert h
  simp only [stepOnce, advance]
  cases hr : replayable (look (K vol (inputAt t p st (mark vol st))) p.cache) with
  | none => intro h; exact absurd h (Nat.succ_ne_self _)
  | some o => intro _; exact ⟨o, rfl, (replayable_some hr).2⟩

/-- And the other side of the rule: a step whose key the cache answers with a failure runs. -/
theorem recorded_failure_runs (md : Mode) (t : Trial) (p : Progress) (st : Step) {o : Output}
    (h : look (K vol (inputAt t p st (mark vol st))) p.cache = some o) (fail : o.code ≠ 0) :
    (stepOnce vol exec md t p st).ran = p.ran + 1 := by
  simp only [stepOnce, advance, h, replayable, fail, ite_false, ranAfter]

/-! ## P1: replay equals run -/

/-- One step. Whether it hit or missed, what it contributes is what running it contributes; the
cache stays coherent, and still holds nothing for the steps that come after. -/
theorem step_ok (d : Disciplined vol exec) (t : Trial) (p : Progress) (st : Step) (m : Mark)
    (r : Option Output) (heq : replayable (look (K vol (inputAt t p st m)) p.cache) = r)
    (co : Coherent vol exec p.cache) (ah : Ahead t st.num p.cache) :
    produced exec t p st m r = exec (inputAt t p st m) t ∧
      Coherent vol exec (addEntry vol exec t p st m r) ∧
      Ahead t (st.num + 1) (addEntry vol exec t p st m r) := by
  cases r with
  | some o =>
    have hit := (replayable_some heq).1
    cases m
    · exact ⟨(unmarked_replays vol exec d p.state p.env p.event st co o hit).symm, co, ahead_loosen ah⟩
    · exact absurd ((marked_misses vol p.state p.env p.event st ah).symm.trans hit) (fun h => nomatch h)
  | none =>
    refine ⟨rfl, coherent_cons vol exec ⟨_, t, rfl, rfl⟩ co, ahead_cons ?_ (ahead_loosen ah)⟩
    intro b i h le
    cases m <;>
    simp only [K, keyOf, inputAt, inputFor, Script.stamped.injEq, Script.body.injEq,
      reduceCtorEq] at h <;> omega

/-- The job's steps are numbered from `n` upwards, as the runner numbers them and as
`containerScript` writes into each script. -/
def Numbered : Nat → List Step → Prop
  | _, [] => True
  | n, st :: sts => st.num = n ∧ Numbered (n + 1) sts

/-- **P1, replay equals run.** A job run against a cache from other jobs produces what the same job
produces with the step cache off — every step of it — provided the steps the runner does not mark
are disciplined. It holds for any mode: output keys on, off, or falling back on whichever steps
they like, since what the rest of the job sees of a step goes through `produced` either way. It
holds with exit codes in the outputs and failures in the cache: a failure the cache answers with is
a miss, and a miss is a run.

What the proof needs beyond `Disciplined` is only bookkeeping the implementation already does:
entries are honest, and the job's steps are numbered. There is no hypothesis left over about mounted
content, because the numbering discharges it inside a job and `Disciplined` covers it across jobs. -/
theorem replay_eq_run (d : Disciplined vol exec) (md : Mode) (t : Trial) :
    ∀ (n : Nat) (p : Progress) (job : List Step), Numbered n job →
      Coherent vol exec p.cache → Ahead t n p.cache →
      (build vol exec md t p job).outs = uncached vol exec md t p.event p.state p.env p.outs job
  | _, _, [], _, _, _ => rfl
  | n, p, st :: sts, ⟨num, nums⟩, co, ah => by
    obtain ⟨out_eq, co', ah'⟩ :=
      step_ok vol exec d t p st (mark vol st) _ rfl co (by rw [num]; exact ah)
    have ih := replay_eq_run d md t (n + 1) (stepOnce vol exec md t p st) sts nums co'
      (by rw [← num]; exact ah')
    refine ih.trans (uncached_cong vol exec md t p.event sts ?_ ?_ ?_)
    · exact congrArg (nextState vol (md st.num) t p.state p.env p.event st (mark vol st)) out_eq
    · exact congrArg (nextEnv p.env) out_eq
    · exact congrArg (· :: p.outs) out_eq

/-- **A replay's log is the run's** (#71). Under P1's hypotheses, the logs a job shows, replayed
steps' included, are the logs it shows with the step cache off. This is a corollary of
`replay_eq_run` because `Output.log` is the log as one thing, which is what the runner records and
replays since a step's stderr goes to its stdout (`exec 2>&1`); `Runner.Logs` is why that
qualification is needed. -/
theorem replay_logs_eq_run (d : Disciplined vol exec) (md : Mode) (t : Trial) (n : Nat) (p : Progress)
    (job : List Step) (nums : Numbered n job) (co : Coherent vol exec p.cache) (ah : Ahead t n p.cache) :
    (build vol exec md t p job).outs.map Output.log
      = (uncached vol exec md t p.event p.state p.env p.outs job).map Output.log := by
  rw [replay_eq_run vol exec d md t n p job nums co ah]

/-! ## P6: minimality -/

/-- Every step of the job hits, on an entry that succeeded. -/
def Warm (md : Mode) (t : Trial) : Progress → List Step → Prop
  | _, [] => True
  | p, st :: sts =>
    ∃ o, replayable (look (K vol (inputAt t p st (mark vol st))) p.cache) = some o ∧
      Warm md t (stepOnce vol exec md t p st) sts

theorem hit_keeps_ran (md : Mode) (t : Trial) (p : Progress) (st : Step) {o : Output}
    (h : replayable (look (K vol (inputAt t p st (mark vol st))) p.cache) = some o) :
    (stepOnce vol exec md t p st).ran = p.ran := by
  simp only [stepOnce, advance, h, ranAfter]

/-- P6, the half that matters for the claim "N of M steps replayed from the cache": a job whose
every step hits runs nothing at all. -/
theorem warm_runs_nothing (md : Mode) (t : Trial) :
    ∀ (p : Progress) (job : List Step), Warm vol exec md t p job →
      (build vol exec md t p job).ran = p.ran
  | _, [], _ => rfl
  | p, st :: sts, ⟨_, hit, w⟩ =>
    (warm_runs_nothing md t (stepOnce vol exec md t p st) sts w).trans
      (hit_keeps_ran vol exec md t p st hit)

/-- P6, the other half: a step whose key the cache holds does not run — provided what the cache
holds for that key succeeded, since a failure is run again (#69). `look_found` is what connects "it
was recorded" to "it is replayed", which is the step the log line `N of M steps replayed from the
cache` reports. -/
theorem recorded_not_run (md : Mode) (t : Trial) (p : Progress) (st : Step) {o : Output}
    (mem : (K vol (inputAt t p st (mark vol st)), o) ∈ p.cache)
    (ok : ∀ o', (K vol (inputAt t p st (mark vol st)), o') ∈ p.cache → o'.code = 0) :
    (stepOnce vol exec md t p st).ran = p.ran := by
  obtain ⟨o', eq⟩ := look_found _ _ mem
  have hc := ok o' (look_sound _ _ eq)
  exact hit_keeps_ran vol exec md t p st (o := o') (by simp [eq, replayable, hc])

/-- And a step runs at most once: `ran` either stays or goes up by one. -/
theorem step_runs_at_most_once (md : Mode) (t : Trial) (p : Progress) (st : Step) :
    (stepOnce vol exec md t p st).ran = p.ran ∨ (stepOnce vol exec md t p st).ran = p.ran + 1 := by
  simp only [stepOnce, advance]
  cases replayable (look (K vol (inputAt t p st (mark vol st))) p.cache) with
  | some _ => exact Or.inl rfl
  | none => exact Or.inr rfl

/-! ## Garbage collection, and a cache other jobs are writing to -/

/-- Pruning the store can only cause misses, never wrong results (STUDY.md §7.4 says so; this is
why). Both hypotheses of P1 survive dropping entries, so P1 holds of whatever is left. -/
theorem coherent_subset {c c' : Cache} (sub : Subset c' c) (co : Coherent vol exec c) :
    Coherent vol exec c' :=
  fun mem => co (sub mem)

theorem ahead_subset {t : Trial} {n : Nat} {c c' : Cache} (sub : Subset c' c) (ah : Ahead t n c) :
    Ahead t n c' :=
  fun mem => ah (sub mem)

/-- Entries written by other jobs. A job's nonce is the run, the attempt and the job, so no other
job can have written an entry under this job's nonce — which is what makes one cache shared by a
pool of runners safe, and what P1 needs of it. The entries other jobs leave for *unmarked* steps
are the ones this job means to hit. -/
def Elsewhere (t : Trial) (c : Cache) : Prop :=
  ∀ {k : Key} {o : Output}, (k, o) ∈ c →
    ∀ (b : Body) (i : Nat) (t' : Trial), k.kScript = .stamped t' (.body b i) → t' ≠ t

theorem elsewhere_ahead {t : Trial} {c : Cache} (el : Elsewhere t c) (n : Nat) : Ahead t n c :=
  fun mem b i eq _ => el mem b i _ eq rfl

end

end Runner.Build
