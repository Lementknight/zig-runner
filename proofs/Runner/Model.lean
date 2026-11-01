import Runner.Prelude

/-!
# The vocabulary

This runner as a build system in the sense of Build Systems à la Carte, with a scheduler (a job's
steps run in order, as GitHub Actions specifies) and a rebuilder (Dagger reuses an exec whose key it
has already seen). `Runner.Build` is the algorithm and its theorems; `Runner.OutputKeys` is the
constructive-trace mechanism built on top of it.

Every modelling choice below is a claim about the real system, and the code that backs it up is
named:

* A container's identity *is* the recipe that built it. Dagger's container id is a lazy
  description, and two containers built the same way have the same cache key, which is what `State`
  models: the parts of the recipe a key depends on. This is why a step whose own key is new makes
  every step after it new too, and it is the whole reason output keys exist.

* A step's key keeps the container it starts from, the script text, and the non-volatile
  environment; it forgets the mounts and the volatile variables. That is what dagger.zig builds:
  `withExec` under `loadContainerFromID`, `withVolatileVariable` for the names in `volatile_env`,
  and `withMountedCache` for the package caches, whose content the engine keeps out of an exec's
  key: since Dagger v0.21.0 an exec is reused by DagQL's recipe digest, in which a `cacheVolume` is
  its key string, namespace, sharing and owner and never what it holds. The volume's identity is in
  the real key and not in `Key`; the README's `Key` row counts that as extra misses.

* "Always run" is not a flag the engine understands. The runner writes the job's nonce into the
  step's script, and the script is part of the key (`always_run`, threaded through
  `containerScript` in dagger/docker.zig). `stamped` models that, so the proofs are about the
  mechanism that exists rather than one we wish existed.

* `exec` takes a trial number, so a step need not be a function of its inputs alone. Nothing here
  forces a step to be deterministic; the properties that need determinism have to ask for it, which
  is how the flakiness question (docs/RELATED.md) shows up as a hypothesis rather than as an
  oversight.

The code named above is the Dagger backend's. The native backend (docs/native-backend.md) keeps
its own store, and `Runner.Native` is its refinement of this model: it spells `Key` out as the
bytes the store hashes, proves the spelling keeps exactly what `Key` keeps, and proves P1 for the
store as P2 specifies it.

The Agda module's decidable-equality functions (`_≟Script_`, `_≟State_`, `_≟Env_`, `_≟Key_`) are
derived `DecidableEq` instances here; `look` decides key equality with `if k = e.1`, and the
counterexamples compute through those instances with `decide` and `rfl`.
-/

namespace Runner

/-! ## Atoms

Variable names, script bodies, file contents and digests are things the system only ever compares
for equality, so numbers stand in for them. A digest is a number here, and the model never looks
inside one. -/

abbrev Name := Nat
abbrev Body := Nat
abbrev Content := Nat
abbrev Log := Nat
abbrev Trial := Nat

/-- A script is its text together with the step's position in the job, or that script with the
job's nonce written into it.

The position is in here because it is in the real script: `containerScript` and `stepScriptFc`
write `echo '<marker>begin <n>'` and the step's file-command paths, so two steps of a job never have
the same script text. That is a log marker doing load-bearing work for the cache, and
`Runner.Counterexamples` shows what goes wrong without it.

`stamped` is the always-run marker, a constructor rather than a flag because that is how the runner
implements it: a nonce written into the script text, which is part of the key.

Port note: the second paragraph is the Agda comment as it stands, and it disagrees with the README
and with counterexample 5 (`SameStepTwice`), which say the step number is *not* load-bearing for
correctness: two occurrences of a step are kept apart by the parent's depth (`depth_advances`).
What is true is narrower. The proof of P1 uses the numbering (`Numbered`, `Ahead`) as its
bookkeeping inside a job, and no counterexample shows a wrong answer without it. -/
inductive Script where
  | body (b : Body) (n : Nat)
  | stamped (t : Trial) (s : Script)
  deriving DecidableEq, Repr

theorem body_injective₁ {b b' : Body} {n n' : Nat} (h : Script.body b n = .body b' n') : b = b' :=
  (Script.body.inj h).1

theorem body_injective₂ {b b' : Body} {n n' : Nat} (h : Script.body b n = .body b' n') : n = n' :=
  (Script.body.inj h).2

theorem stamped_injective₁ {t t' : Trial} {s s' : Script} (h : Script.stamped t s = .stamped t' s') :
    t = t' :=
  (Script.stamped.inj h).1

theorem stamped_injective₂ {t t' : Trial} {s s' : Script} (h : Script.stamped t s = .stamped t' s') :
    s = s' :=
  (Script.stamped.inj h).2

/-- A script carries no nonce: the step was not marked always-run. -/
def Unstamped : Script → Prop
  | .body _ _ => True
  | .stamped _ _ => False

/-! ## Environments and mounts -/

abbrev Binding := Name × Content

abbrev Env := List Binding

/-- A mount is a path and the content mounted there: a cache volume for a package manager. Mount
content is in no key, by design; the mount's identity is in the engine's and not in `Key`, which
costs only misses (proofs/README.md, `Key` row). -/
abbrev Mounts := List (Name × Content)

/-! ## Containers

A container's cache identity: the job's base container, what an exec with a given recipe leaves,
or — this is the output-keys mechanism — a container with a stored output copied into it by the
output's content digest.

`afterCopy` is the one that matters. Its identity mentions what was produced and not who produced
it, so two jobs whose marked step produced the same bytes arrive at the same container, and the
steps after it can be replayed. That is a constructive trace in Build Systems à la Carte's sense. -/

inductive State where
  | base (b : Nat)
  | afterExec (s : State) (sc : Script) (e : Env)
  | afterCopy (s : State) (c : Content)
  deriving DecidableEq, Repr

theorem base_injective {b b' : Nat} (h : State.base b = .base b') : b = b' := State.base.inj h

theorem afterExec_injective₁ {s s' : State} {sc sc' : Script} {e e' : Env}
    (h : State.afterExec s sc e = .afterExec s' sc' e') : s = s' := (State.afterExec.inj h).1

theorem afterExec_injective₂ {s s' : State} {sc sc' : Script} {e e' : Env}
    (h : State.afterExec s sc e = .afterExec s' sc' e') : sc = sc' := (State.afterExec.inj h).2.1

theorem afterExec_injective₃ {s s' : State} {sc sc' : Script} {e e' : Env}
    (h : State.afterExec s sc e = .afterExec s' sc' e') : e = e' := (State.afterExec.inj h).2.2

theorem afterCopy_injective₁ {s s' : State} {c c' : Content}
    (h : State.afterCopy s c = .afterCopy s' c') : s = s' := (State.afterCopy.inj h).1

theorem afterCopy_injective₂ {s s' : State} {c c' : Content}
    (h : State.afterCopy s c = .afterCopy s' c') : c = c' := (State.afterCopy.inj h).2

/-! ## Steps, inputs, outputs -/

/-- A step as the workflow writes it. `reads` is the set of variable names the script really
consults; `readsRunSpecific` in dagger.zig is a syntactic over-approximation of it, which is sound
only when a script that consults a name also mentions it (see proofs/README.md, "What this does not
model").

There is no `env` here: the variables a step sees are the container's, which the job sets once and
earlier steps add to through `$GITHUB_ENV` (`Output.sets` below). A `run:` step's own `env:`
travels inside the script text, as `writeEnvCommand` puts it there, so it is part of `text`.

`readsEvent` says the script really consults the event payload (`Input.event`). The runner's
`readsRunSpecific` approximates it by looking for `GITHUB_EVENT_PATH` or the file's path in the
text (#68), as it approximates `reads` by looking for the names. -/
structure Step where
  text : Body
  num : Nat
  mounts : Mounts
  reads : List Name
  readsEvent : Bool
  deriving DecidableEq, Repr

/-- Everything a step's result could possibly depend on.

`event` is what the step finds at `$GITHUB_EVENT_PATH`: the event payload, which differs on every
run and, like the volatile variables, is in no key. The runner writes it into the step's container
from a variable of its own; it is a separate field here, beside `env`, because it reached steps by
a path of its own — the file — which withholding the variables did not close (#68). -/
structure Input where
  parent : State
  script : Script
  env : Env
  event : Content
  mounts : Mounts
  deriving DecidableEq, Repr

/-- What running a step produces: what it wrote, the content digest of what it changed in the
filesystem, and the variables it exported. The digest is `changes(from:).layer.digest` in
`outputKeyed`; it is a fact about the bytes, not about who produced them. `sets` is what the step
wrote to `$GITHUB_ENV` and `$GITHUB_PATH`, which the runner reads from the step's file commands and
adds to the next step's container — and which it therefore reads out of a *replayed* step's file
commands too, so a replay must export the same.

`code` is the step's exit code, 0 for success. The engine records failures as well
(`withExec(expect: ANY)`), so a cache entry can hold one; what the runner does with such an answer
is `Runner.Build.replayable`.

`log` is the step's log as a whole. Since #71 a step's script sends its stderr to its stdout
(`exec 2>&1`), so the recorded stdout *is* the log, in the order it was written, and a replay
prints it as it is; before, a replay printed stdout and then stderr, which no single atom can
express. `Runner.Logs` models the two streams and shows the difference. -/
structure Output where
  log : Log
  digest : Content
  sets : Env
  code : Nat
  deriving DecidableEq, Repr

/-! ## Keys

What the engine actually hashes. Modelling the hash as a projection rather than as a function into
digests is deliberate: collisions are a separate concern, and assuming them away silently would be
exactly the kind of hidden hypothesis this exercise is meant to surface. -/

structure Key where
  kParent : State
  kScript : Script
  kEnv : Env
  deriving DecidableEq, Repr

/-- The container an exec with this key leaves. A key and a container identity are the same
information, which is the point: that is why a new key for one step is a new container for every
step after it. -/
def stateOf (k : Key) : State := .afterExec k.kParent k.kScript k.kEnv

/-- Which names are run-specific: `volatile_env` in dagger.zig. -/
abbrev Volatile := Name → Bool

def stable (vol : Volatile) : Env → Env := List.filter (fun b => !vol b.1)

def keyOf (vol : Volatile) (i : Input) : Key := ⟨i.parent, i.script, stable vol i.env⟩

/-! ## The cache

An association list from keys to the outputs recorded for them. The engine's store is a
content-addressed graph with garbage collection; what matters to every property below is only that
a key maps to at most one output, and that the answer survives between jobs. -/

abbrev Cache := List (Key × Output)

def look (k : Key) : Cache → Option Output
  | [] => none
  | e :: c => if k = e.1 then some e.2 else look k c

/-- A hit names an entry that is really in the cache. -/
theorem look_sound (k : Key) : ∀ (c : Cache) {o : Output}, look k c = some o → (k, o) ∈ c
  | [], _, h => nomatch h
  | e :: c, o, h => by
    by_cases hk : k = e.1
    · simp only [look, hk, ite_true, Option.some.injEq] at h
      subst h; subst hk; exact List.Mem.head _
    · simp only [look, hk, ite_false] at h
      exact List.Mem.tail _ (look_sound k c h)

/-- A hit on an extended cache is a hit on the new entry or a hit on the old cache. Stated as a
lemma because the case split has to happen in the same shape as `look`'s own for the definition to
reduce. -/
theorem look_cons (k : Key) (e : Key × Output) (c : Cache) {o : Output}
    (h : look k (e :: c) = some o) : (k = e.1 ∧ o = e.2) ∨ look k c = some o := by
  by_cases hk : k = e.1
  · simp only [look, hk, ite_true, Option.some.injEq] at h
    exact Or.inl ⟨hk, h.symm⟩
  · simp only [look, hk, ite_false] at h
    exact Or.inr h

/-- An entry that is there can be found. (Not the same as `look_sound`: this is the direction that
says a recorded step is replayed, not that a replay was recorded.) -/
theorem look_found (k : Key) : ∀ (c : Cache) {o : Output}, (k, o) ∈ c → ∃ o', look k c = some o'
  | e :: c, _, m => by
    by_cases hk : k = e.1
    · exact ⟨e.2, by simp [look, hk]⟩
    · simp only [look, hk, ite_false]
      cases m with
      | head => exact absurd rfl hk
      | tail _ m => exact look_found k c m

/-- One cache holds only entries another holds: what garbage collection leaves behind, and what a
job sees of a cache other jobs are also writing to. -/
def Subset (c' c : Cache) : Prop := ∀ {k : Key} {o : Output}, (k, o) ∈ c' → (k, o) ∈ c

/-- A key no entry carries cannot be found. -/
theorem look_miss (k : Key) : ∀ (c : Cache), (∀ o, ¬ (k, o) ∈ c) → look k c = none
  | [], _ => rfl
  | e :: c, absent => by
    by_cases hk : k = e.1
    · exact absurd (by rw [hk]; exact List.Mem.head _) (absent e.2)
    · simp only [look, hk, ite_false]
      exact look_miss k c (fun o mem => absent o (List.Mem.tail _ mem))

end Runner
