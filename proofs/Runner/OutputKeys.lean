import Runner.Build

/-!
# Output keys (`RUNNER_OUTPUT_KEYS`), and the property they exist for

A marked step cannot be replayed — that is the point of marking it — and without help neither can
anything after it, because the container it hands on is identified by its own recipe, nonce and
all. `outputKeyed` replaces that container with the one before the step plus what the step
produced, copied in by content digest. So what the next step starts from records *what was
produced* rather than *who produced it*.

In Build Systems à la Carte's taxonomy the step cache is a verifying trace and this is a
constructive one, and what it buys is early cutoff: a step whose result is unchanged stops forcing
its dependents to run.

Only a marked step that succeeded is output-keyed (`execScript` asks `out.code == 0`), so early
cutoff is about successes: `cutoff` and `cutoff_needs_only_the_digest` ask for it, and
`failure_is_a_wall` is the other case.

As in `Runner.Build`, the Agda module's parameters `vol` and `exec` are section variables. The
Agda's `All P xs` is written `∀ x ∈ xs, P x`.
-/

namespace Runner.OutputKeys

open Runner Runner.Build

section
variable (vol : Volatile) (exec : Input → Trial → Output)

/-! ## Containers that name a job -/

/-- The container's identity mentions this job's nonce, so no other job can have built it: either a
marked step's exec left it, or something that did is somewhere below it in the chain.

The Agda's second constructor is `below`; Lean reserves that name for the structural-recursion
helper it generates for every inductive type, so here it is `beneath`. -/
inductive Nonced (t : Trial) : State → Prop where
  | marked {s : State} {b : Body} {n : Nat} {e : Env} : Nonced t (.afterExec s (.stamped t (.body b n)) e)
  | beneath {s : State} {sc : Script} {e : Env} : Nonced t s → Nonced t (.afterExec s sc e)
  | copied {s : State} {c : Content} : Nonced t s → Nonced t (.afterCopy s c)

/-- A cache written by other jobs: no entry's key starts from a container that mentions this job's
nonce. Such a container is one no other job could have built, so no other job could have recorded a
key starting from it. -/
def Clean (t : Trial) (c : Cache) : Prop := ∀ {k : Key} {o : Output}, (k, o) ∈ c → ¬ Nonced t k.kParent

/-- Whatever the mark, a step's key starts from the container it was given. (The Agda proofs split
on the mark at each use, as `parent-nonced`; here it is one lemma.) -/
theorem parent_inputFor (t : Trial) (s : State) (e : Env) (ev : Content) (st : Step) (m : Mark) :
    (K vol (inputFor t s e ev st m)).kParent = s := by
  cases m <;> rfl

/-- A step that starts from such a container misses, marked or not. -/
theorem nonced_misses {t : Trial} {c : Cache} (s : State) (e : Env) (ev : Content) (st : Step)
    (m : Mark) (nc : Nonced t s) (cl : Clean t c) : look (K vol (inputFor t s e ev st m)) c = none :=
  look_miss _ _ (fun _ mem => cl mem (by rw [parent_inputFor]; exact nc))

/-! ## Without output keys, a marked step is a wall -/

/-- The container a marked step hands on names the job. This is equally what a *fallback* costs:
`outputKeyed` returning null for one step is the `off` behaviour for that step, and this is the
price of it. -/
theorem marked_is_nonced (t : Trial) (s : State) (e : Env) (ev : Content) (st : Step) (o : Output) :
    Nonced t (nextState vol .off t s e ev st .everyRun o) :=
  .marked

/-- And a marked step that failed is a wall with output keys on too: it is not output-keyed, so the
container it hands on is its own, which names the job. -/
theorem failure_is_a_wall (t : Trial) (s : State) (e : Env) (ev : Content) (st : Step) (o : Output)
    (fail : o.code ≠ 0) : Nonced t (nextState vol .on t s e ev st .everyRun o) := by
  simp only [nextState, fail, ite_false]
  exact .marked

/-- And nothing downstream shakes it off, in either mode. Output keys do not clean a container that
is already named by the job; they stop a marked step from naming one in the first place. -/
theorem nonced_stays (ks : Keys) (t : Trial) (s : State) (e : Env) (ev : Content) (st : Step)
    (m : Mark) (o : Output) (nc : Nonced t s) : Nonced t (nextState vol ks t s e ev st m o) := by
  cases ks <;> cases m
  · exact .beneath nc
  · exact .beneath nc
  · exact .beneath nc
  · simp only [nextState]
    split
    · exact .copied nc
    · exact .beneath nc

/-- The keys a job asks for, in order, from a given container and environment, with the job's
event payload `ev`. -/
def keysFrom (md : Mode) (t : Trial) (ev : Content) : State → Env → List Step → List Key
  | _, _, [] => []
  | s, e, st :: sts =>
    K vol (inputFor t s e ev st (mark vol st)) ::
      keysFrom md t ev
        (nextState vol (md st.num) t s e ev st (mark vol st) (exec (inputFor t s e ev st (mark vol st)) t))
        (nextEnv e (exec (inputFor t s e ev st (mark vol st)) t)) sts

/-- Every key asked from a container that names the job starts from one too. -/
theorem keys_stay_nonced (md : Mode) (t : Trial) (ev : Content) :
    ∀ (s : State) (e : Env) (job : List Step), Nonced t s →
      ∀ k ∈ keysFrom vol exec md t ev s e job, Nonced t k.kParent
  | _, _, [], _ => fun _ h => nomatch h
  | s, e, st :: sts, nc => by
    intro k hk
    simp only [keysFrom, List.mem_cons] at hk
    rcases hk with rfl | hk
    · rw [parent_inputFor]; exact nc
    · exact keys_stay_nonced md t ev _ _ sts (nonced_stays vol _ t s e ev st _ _ nc) k hk

/-- E1. With output keys off — or falling back on this one step — a marked step makes every step
after it run: each one asks a key that no other job's cache can hold, whatever the marked step
produced and whatever the later steps are. This is the cost output keys were built to remove, and
the reason SPEC.md §6 says "every step after them then runs too". -/
theorem no_cutoff_without_keys (md : Mode) (t : Trial) (c : Cache) (s : State) (e : Env)
    (ev : Content) (st : Step) (rest : List Step) (cl : Clean t c) :
    ∀ k ∈ keysFrom vol exec md t ev
        (nextState vol .off t s e ev st .everyRun (exec (inputFor t s e ev st .everyRun) t))
        (nextEnv e (exec (inputFor t s e ev st .everyRun) t)) rest,
      look k c = none := by
  intro k hk
  have nc := keys_stay_nonced vol exec md t ev _ _ rest
    (marked_is_nonced vol t s e ev st (exec (inputFor t s e ev st .everyRun) t)) k hk
  exact look_miss _ _ (fun _ mem => cl mem nc)

/-! ## With output keys, the same bytes mean the same keys -/

/-- Which steps the runner will not mark. -/
def AllPlain (sts : List Step) : Prop := ∀ st ∈ sts, mark vol st = .plain

/-- An unmarked step's key says nothing about which job is running: the nonce is the only
job-specific thing in one, and an unmarked step has none.

It needs `Disciplined` all the same, and that is new: what a step exports through `$GITHUB_ENV` is
in the next step's container, so if an unmarked step produced different variables in two jobs, the
keys after it would part company. Early cutoff therefore rests on the same hypothesis P1 does. -/
theorem keys_job_independent (d : Disciplined vol exec) (t t' : Trial) (ev : Content) :
    ∀ (s : State) (e : Env) (sts : List Step), AllPlain vol sts →
      keysFrom vol exec (always .on) t ev s e sts = keysFrom vol exec (always .on) t' ev s e sts
  | _, _, [], _ => rfl
  | s, e, st :: sts, pls => by
    have pl : mark vol st = .plain := pls st (List.mem_cons_self ..)
    have hd : exec (inputFor t s e ev st .plain) t = exec (inputFor t' s e ev st .plain) t' :=
      d _ _ t t' rfl trivial
    simp only [keysFrom, pl]
    rw [hd, keys_job_independent d t t' ev _ _ sts (fun x hx => pls x (List.mem_cons_of_mem _ hx))]
    rfl

/-- E2. **Early cutoff.** Two jobs that run the same steps from the same container, whose marked step
succeeded and produced the same bytes, ask exactly the same keys for every step after it — so
whatever the first job recorded, the second finds, and the marked step having run again costs
nothing downstream.

Soundness of those replays is not a new question: `replay_eq_run` is proved for every mode, with no
extra hypothesis. -/
theorem cutoff (d : Disciplined vol exec) (t t' : Trial) (s : State) (e : Env) (ev : Content)
    (st : Step) (rest : List Step) (plains : AllPlain vol rest)
    (same : exec (inputFor t s e ev st .everyRun) t = exec (inputFor t' s e ev st .everyRun) t')
    (ok : (exec (inputFor t s e ev st .everyRun) t).code = 0) :
    keysFrom vol exec (always .on) t ev
        (nextState vol .on t s e ev st .everyRun (exec (inputFor t s e ev st .everyRun) t))
        (nextEnv e (exec (inputFor t s e ev st .everyRun) t)) rest
      = keysFrom vol exec (always .on) t' ev
        (nextState vol .on t' s e ev st .everyRun (exec (inputFor t' s e ev st .everyRun) t'))
        (nextEnv e (exec (inputFor t' s e ev st .everyRun) t')) rest := by
  rw [same] at ok ⊢
  simp only [nextState, ok, ite_true]
  exact keys_job_independent vol exec d t t' ev _ _ rest plains

/-- The digest is what the next container is keyed on, so equal *bytes* are enough even when the
step's log and exported variables differ — which is the point: a deploy that prints a new timestamp
still leaves the same files. Both runs must have succeeded, since a failure is not output-keyed. -/
theorem cutoff_needs_only_the_digest (t t' : Trial) (s : State) (e : Env) (ev : Content) (st : Step)
    (ok : (exec (inputFor t s e ev st .everyRun) t).code = 0)
    (ok' : (exec (inputFor t' s e ev st .everyRun) t').code = 0)
    (dig : (exec (inputFor t s e ev st .everyRun) t).digest
      = (exec (inputFor t' s e ev st .everyRun) t').digest) :
    nextState vol .on t s e ev st .everyRun (exec (inputFor t s e ev st .everyRun) t)
      = nextState vol .on t' s e ev st .everyRun (exec (inputFor t' s e ev st .everyRun) t') := by
  simp only [nextState, ok, ok', ite_true]
  exact congrArg (State.afterCopy s) dig

/-- And it is not a blanket excuse. Different bytes are a different container, so a marked step
whose output changed still forces the steps after it: output keys buy early cutoff, not
unconditional reuse. -/
theorem different_bytes_different_container (s : State) (d d' : Content) (ne : d ≠ d') :
    State.afterCopy s d ≠ State.afterCopy s d' :=
  fun eq => ne (afterCopy_injective₂ eq)

end

end Runner.OutputKeys
