import Runner.Build
import Runner.Enforce

/-!
# A job that breaks each obligation

`Runner.Build` proves that replay equals run, and what it needs is `Disciplined`: for a step the
runner does not mark always-run, inputs that agree on everything the key keeps give the same result.
That one hypothesis bundles three obligations — the step is deterministic, it reads no volatile
variable, and it does not depend on the content of a mounted cache volume — and the runner enforces
none of them. Here is a job that breaks each.

Everything computes: each `rfl` is the model running, and each `by decide` is Lean checking that two
concrete answers differ. (Where the Agda proved `¬ (x ≡ y)` with an absurd pattern `()`, the Lean
uses `decide` on `x ≠ y`, which evaluates both sides through the derived `DecidableEq` instances.)

Each Agda submodule (`module VolatileRead where`, with `module V = B vol execV; open V`) is a Lean
namespace, and the instantiated `Runner.Build` is applied explicitly: `build vol execV …`.
-/

namespace Runner.Counterexamples

open Runner Runner.Build

/-- Name 0 stands for GITHUB_RUN_ID: its value differs between runs, and the key deliberately leaves
it out. -/
def runId : Name := 0

def vol : Volatile := fun n => if n = runId then true else false

/-- Looking a name up in an environment, or a path up in the mounts; absent is 0. -/
def valueOf (n : Name) : List (Name × Content) → Content
  | [] => 0
  | b :: bs => if n = b.1 then b.2 else valueOf n bs

/-- The job's base container. -/
def start : State := .base 0

/-- The variables the job sets on its base container. The run id is one of those, as
`withVolatileVariable` makes it. -/
def jobEnv (runIdValue : Content) : Env := [(runId, runIdValue)]

/-! ## 1. A volatile read the runner did not notice

`readsRunSpecific` looks for the variable's name in the script text. A script that gets the value
another way — sourcing a file, calling a program that reads the environment, `env | grep` —
consults it without naming it, so the step is not marked. This is that step. -/

namespace VolatileRead

/-- The step logs what it read from the run id, changes nothing and exports nothing. -/
def execV (i : Input) (_ : Trial) : Output := ⟨valueOf runId i.env, 0, [], 0⟩

/-- One step, in two jobs: the first job's run id is 7, the second's is 9. `reads` is empty, so the
runner marks neither. -/
def theStep : Step := ⟨1, 0, [], [], false⟩

def warm : Cache := (build vol execV (always .off) 1 ⟨start, jobEnv 7, 0, [], 0, []⟩ [theStep]).cache

def replayed : List Output := (build vol execV (always .off) 2 ⟨start, jobEnv 9, 0, warm, 0, []⟩ [theStep]).outs

def ran : List Output := uncached vol execV (always .off) 2 0 start (jobEnv 9) [] [theStep]

/-- The second job is handed the first's answer, and never runs the step. -/
theorem replayed_logs_7 : replayed = [⟨7, 0, [], 0⟩] := rfl

theorem ran_logs_9 : ran = [⟨9, 0, [], 0⟩] := rfl

theorem nothing_ran :
    (build vol execV (always .off) 2 ⟨start, jobEnv 9, 0, warm, 0, []⟩ [theStep]).ran = 0 := rfl

/-- So P1 fails, and nothing in the engine is at fault: the key kept everything it promised to keep.
The obligation is the runner's, and it is the obligation to decide `Step.reads` correctly. -/
theorem unsound : replayed ≠ ran := by decide

end VolatileRead

/-! ## 2. The same step, marked

With the read declared, `mark` gives `everyRun`, the job's nonce goes into the script, the key is
one no other job can have recorded, and the step runs. -/

namespace Marked

def execV (i : Input) (_ : Trial) : Output := ⟨valueOf runId i.env, 0, [], 0⟩

def theStep : Step := ⟨1, 0, [], [runId], false⟩

def warm : Cache := (build vol execV (always .off) 1 ⟨start, jobEnv 7, 0, [], 0, []⟩ [theStep]).cache

theorem it_ran :
    (build vol execV (always .off) 2 ⟨start, jobEnv 9, 0, warm, 0, []⟩ [theStep]).ran = 1 := rfl

theorem sound :
    (build vol execV (always .off) 2 ⟨start, jobEnv 9, 0, warm, 0, []⟩ [theStep]).outs
      = uncached vol execV (always .off) 2 0 start (jobEnv 9) [] [theStep] := rfl

end Marked

/-! ## 3. A flaky step

A step that is not marked and is not a function of its inputs. The runner has no way to tell, and
the cache has no reason to doubt it. -/

namespace Flaky

/-- The result differs between jobs although every input the key keeps is the same: a test that
passes once and fails once. (The log is the trial; the exit code is 0 in job 1 and 1 in job 2.) -/
def execF (_ : Input) (t : Trial) : Output := ⟨t, 0, [], t - 1⟩

def test : Step := ⟨1, 0, [], [], false⟩

def warm : Cache := (build vol execF (always .off) 1 ⟨start, [], 0, [], 0, []⟩ [test]).cache

/-- Job 1 passed, so job 2 "passes" too, without running the test. A runner that replays steps
cannot observe flakiness in the steps it replays: it is not that we have not measured it
(docs/RELATED.md), it is that this design hides it by construction, and `Disciplined` is where it
hides. The rule that a failure is not replayed (#69) does not reach this: what was recorded is a
pass. -/
theorem replay_hides_it :
    (build vol execF (always .off) 2 ⟨start, [], 0, warm, 0, []⟩ [test]).outs = [⟨1, 0, [], 0⟩] := rfl

theorem running_shows_it : uncached vol execF (always .off) 2 0 start [] [] [test] = [⟨2, 0, [], 1⟩] := rfl

theorem unsound :
    (build vol execF (always .off) 2 ⟨start, [], 0, warm, 0, []⟩ [test]).outs
      ≠ uncached vol execF (always .off) 2 0 start [] [] [test] := by decide

end Flaky

/-! ## 3b. A flaky failure (#69)

The other way round: the step failed in job 1 for a reason that has passed — a network blip, a
runner out of memory — and passes when run again. The engine records failures too, so the cache
holds job 1's. Before #69 the runner replayed it, and every re-run failed the same way until an
input changed; now a recorded failure is a miss (`Build.replayable`), so the step runs, and P1
holds of this job. -/

namespace FlakyFailure

/-- Fails in job 1, passes after. -/
def execX (_ : Input) (t : Trial) : Output := ⟨0, 0, [], if t = 1 then 1 else 0⟩

def test : Step := ⟨1, 0, [], [], false⟩

def warm : Cache := (build vol execX (always .off) 1 ⟨start, [], 0, [], 0, []⟩ [test]).cache

/-- The failure is in the cache, under the key job 2 asks: this is what the runner replayed. -/
theorem the_failure_is_recorded :
    look (K vol (inputFor 2 start [] 0 test (mark vol test))) warm = some ⟨0, 0, [], 1⟩ := rfl

/-- Job 2 runs the step instead, and it passes. -/
theorem it_runs_again : (build vol execX (always .off) 2 ⟨start, [], 0, warm, 0, []⟩ [test]).ran = 1 := rfl

theorem and_passes :
    (build vol execX (always .off) 2 ⟨start, [], 0, warm, 0, []⟩ [test]).outs = [⟨0, 0, [], 0⟩] := rfl

theorem sound :
    (build vol execX (always .off) 2 ⟨start, [], 0, warm, 0, []⟩ [test]).outs
      = uncached vol execX (always .off) 2 0 start [] [] [test] := rfl

/-- And job 3 replays job 2's pass: the rerun was recorded, so the failure costs one run, not one
per job. (The runner records the rerun under a stamped key instead, so there it costs a run in every
job until the failure is pruned; see `Build.replayable`.) -/
theorem then_replays_the_pass :
    (build vol execX (always .off) 3
      ⟨start, [], 0, (build vol execX (always .off) 2 ⟨start, [], 0, warm, 0, []⟩ [test]).cache, 0, []⟩
      [test]).ran = 0 := rfl

end FlakyFailure

/-! ## 4. A step that reads a cache volume

A mount's content is excluded from an exec's key by design, which is what lets the package caches be
shared without making every step miss (experiment 6). The price is that a step whose result depends
on what it found in one is not disciplined, and gets replayed when the volume has changed. -/

namespace MountedCache

/-- The step logs what it found at path 3, a cache volume. -/
def execM (i : Input) (_ : Trial) : Output := ⟨valueOf 3 i.mounts, 0, [], 0⟩

/-- The same step in two jobs. Between them something else filled the volume: another job's
`uv sync`, a `go mod download`, a pruning pass. -/
def first : Step := ⟨1, 0, [(3, 5)], [], false⟩

def second : Step := ⟨1, 0, [(3, 9)], [], false⟩

def warm : Cache := (build vol execM (always .off) 1 ⟨start, [], 0, [], 0, []⟩ [first]).cache

/-- The key is the same, so the step is replayed with the old volume's answer. -/
theorem unsound :
    (build vol execM (always .off) 2 ⟨start, [], 0, warm, 0, []⟩ [second]).outs
      ≠ uncached vol execM (always .off) 2 0 start [] [] [second] := by decide

end MountedCache

/-! ## 5. The same step twice in one job

This is the case an earlier version of this model got wrong, and it is worth keeping as the
correction. The job's nonce is per job, not per step, so two marked steps in one job carry the
*same* marker; it looked as though only the step number in the script text kept them apart. It is
not: each step starts from the container the previous one left, so the second occurrence asks a key
with a deeper parent, and the first's entry cannot answer it. -/

namespace SameStepTwice

def execM (i : Input) (_ : Trial) : Output := ⟨valueOf 3 i.mounts, 0, [], 0⟩

/-- Identical but for the volume's content, and numbered the same, which the runner never emits —
so the script text cannot be what separates them. -/
def readsFive : Step := ⟨1, 0, [(3, 5)], [runId], false⟩

def readsSix : Step := ⟨1, 0, [(3, 6)], [runId], false⟩

def afterFirst : Progress := build vol execM (always .off) 1 ⟨start, [], 0, [], 0, []⟩ [readsFive]

/-- The second occurrence does not find the first's entry. -/
theorem misses :
    look (K vol (inputAt 1 afterFirst readsSix (mark vol readsSix))) afterFirst.cache = none := rfl

/-- Because the chain grew: it is one deeper than where the first step started. -/
theorem deeper : depth afterFirst.state = depth start + 1 := rfl

/-- So both run, and the job reports what running reports. -/
theorem both_ran :
    (build vol execM (always .off) 1 ⟨start, [], 0, [], 0, []⟩ [readsFive, readsSix]).ran = 2 := rfl

theorem sound :
    (build vol execM (always .off) 1 ⟨start, [], 0, [], 0, []⟩ [readsFive, readsSix]).outs
      = uncached vol execM (always .off) 1 0 start [] [] [readsFive, readsSix] := rfl

end SameStepTwice

/-! ## 6. Output keys, and what makes them fall flat

A marked step is a wall: nothing after it can be replayed, because what it hands on is identified by
its own recipe. Output keys replace that with the container before it plus what it produced, by
digest — so the wall comes down exactly when the step produces the same bytes as last time. These
four numbers are experiment 7.6 in miniature. -/

namespace OutputKeys

/-- A deploy (text 1) that leaves the same bytes behind every job; a deploy (text 2) whose output
carries something new every time, which is what a timestamp or a random delimiter in a file command
does; and everything else, which is stable. -/
def execD (i : Input) (t : Trial) : Output :=
  match i.script with
  | .stamped _ (.body 2 _) => ⟨0, t, [], 0⟩
  | _ => ⟨0, 42, [], 0⟩

def deploy : Step := ⟨1, 0, [], [runId], false⟩

def noisyDeploy : Step := ⟨2, 0, [], [runId], false⟩

def check : Step := ⟨5, 1, [], [], false⟩

/-- Job 1 runs both steps and records them. -/
def warm : Cache := (build vol execD (always .on) 1 ⟨start, [], 0, [], 0, []⟩ [deploy, check]).cache

theorem cold_job_runs_both :
    (build vol execD (always .on) 1 ⟨start, [], 0, [], 0, []⟩ [deploy, check]).ran = 2 := rfl

/-- Job 2, with output keys: the deploy runs again, as it must, and the check after it is replayed
anyway. That is early cutoff. -/
theorem cutoff_replays_the_check :
    (build vol execD (always .on) 2 ⟨start, [], 0, warm, 0, []⟩ [deploy, check]).ran = 1 := rfl

/-- Without output keys, the same job runs both: the deploy's new key is a new container, and the
check cannot be found under it. This is also what a fallback costs, since a fallback is `off` for
that one step. -/
theorem without_keys_runs_both :
    (build vol execD (always .off) 2 ⟨start, [], 0, warm, 0, []⟩ [deploy, check]).ran = 2 := rfl

/-- And output keys buy nothing when the always-run step's output is never the same twice: the
digest is the key, so a new digest is a new container. `outputs_ignored` in dagger/output_keys.zig
exists for exactly this reason. -/
def noisy : Cache :=
  (build vol execD (always .on) 1 ⟨start, [], 0, [], 0, []⟩ [noisyDeploy, check]).cache

theorem noise_defeats_cutoff :
    (build vol execD (always .on) 2 ⟨start, [], 0, noisy, 0, []⟩ [noisyDeploy, check]).ran = 2 := rfl

end OutputKeys

/-! ## 7. A replayed step still exports its variables

`$GITHUB_ENV` is how a setup step tells the next one where the toolchain is, and the runner reads
those file commands out of the step's result — including a *replayed* result, which is why this
works at all. If a replay exported nothing, the next step's container would differ and nothing after
it could be replayed either. -/

namespace Exported

/-- A setup step (text 1) that exports a variable; everything else exports nothing and logs what it
was told. -/
def execE (i : Input) (_ : Trial) : Output :=
  match i.script with
  | .body 1 _ => ⟨0, 42, [(7, 99)], 0⟩
  | _ => ⟨valueOf 7 i.env, 42, [], 0⟩

def setup : Step := ⟨1, 0, [], [], false⟩

def use : Step := ⟨2, 1, [], [], false⟩

def job : List Step := [setup, use]

def warm : Cache := (build vol execE (always .off) 1 ⟨start, [], 0, [], 0, []⟩ job).cache

/-- Job 1 runs both, and the second step saw what the first exported. -/
theorem first_job :
    (build vol execE (always .off) 1 ⟨start, [], 0, [], 0, []⟩ job).outs
      = [⟨99, 42, [], 0⟩, ⟨0, 42, [(7, 99)], 0⟩] := rfl

/-- Job 2 replays both, and the replayed setup step still contributes its variable — so the second
step's key is the one that was recorded, and it is replayed too. -/
theorem second_job_runs_nothing :
    (build vol execE (always .off) 2 ⟨start, [], 0, warm, 0, []⟩ job).ran = 0 := rfl

theorem same_answers :
    (build vol execE (always .off) 2 ⟨start, [], 0, warm, 0, []⟩ job).outs
      = uncached vol execE (always .off) 2 0 start [] [] job := rfl

end Exported

/-! ## 8. The same step, with the hole closed

Counterexample 1 is the blind spot: a step that reads the run id without naming it is replayed and
reports a stale value. `Runner.Enforce` closes it by giving an unmarked step only what its key
keeps. Here is that counterexample's own `exec`, unchanged, against the same two jobs: it can no
longer tell them apart, because it is handed the same thing in both. -/

namespace Enforced

open Runner.Enforce

def execV (i : Input) (_ : Trial) : Output := ⟨valueOf runId i.env, 0, [], 0⟩

def theStep : Step := ⟨1, 0, [], [], false⟩

/-- Run ids 7 and 9, and one input. -/
theorem same_input : inputPlain vol start (jobEnv 7) 0 theStep = inputPlain vol start (jobEnv 9) 0 theStep :=
  rfl

/-- So the step that distinguished them cannot: there is nothing left to distinguish. -/
theorem cannot_tell_them_apart :
    execV (inputPlain vol start (jobEnv 7) 0 theStep) 1 = execV (inputPlain vol start (jobEnv 9) 0 theStep) 2 :=
  rfl

/-- And what it reads is the sentinel rather than another run's value: absent here, a constant in
the runner, which is the same thing to every theorem and more visible in a log. -/
theorem reads_nothing_of_the_run : execV (inputPlain vol start (jobEnv 7) 0 theStep) 1 = ⟨0, 0, [], 0⟩ :=
  rfl

end Enforced

/-! ## 9. The event payload, read from a file (#68)

Counterexample 1 by another path. The runner withheld the volatile variables but wrote the event
payload in full to every step's `$GITHUB_EVENT_PATH`, and the payload is in no key
(`Build.event_invisible`). A script that read a `workflow_dispatch` input out of that file without
naming the variable or the file — through `jq` in a helper script, say — was not marked, and was
replayed with an earlier run's payload. This is that runner: `Runner.Build` hands the step the real
payload whether it is marked or not. -/

namespace EventRead

/-- The step logs what it found in the payload file. -/
def execP (i : Input) (_ : Trial) : Output := ⟨i.event, 0, [], 0⟩

/-- Unmarked: its script names neither the variable nor the file. -/
def theStep : Step := ⟨1, 0, [], [], false⟩

/-- Job 1's payload is 7, job 2's is 9. -/
def warm : Cache := (build vol execP (always .off) 1 ⟨start, [], 7, [], 0, []⟩ [theStep]).cache

def replayed : List Output := (build vol execP (always .off) 2 ⟨start, [], 9, warm, 0, []⟩ [theStep]).outs

def ran : List Output := uncached vol execP (always .off) 2 9 start [] [] [theStep]

theorem replayed_logs_7 : replayed = [⟨7, 0, [], 0⟩] := rfl

theorem ran_logs_9 : ran = [⟨9, 0, [], 0⟩] := rfl

/-- The second run is handed the first's payload. -/
theorem unsound : replayed ≠ ran := by decide

end EventRead

/-! ## 10. The payload, named

A script that names `GITHUB_EVENT_PATH` or the file is marked (`readsRunSpecific`, `Step.readsEvent`),
and runs every time with the real payload. -/

namespace EventMarked

def execP (i : Input) (_ : Trial) : Output := ⟨i.event, 0, [], 0⟩

def theStep : Step := ⟨1, 0, [], [], true⟩

def warm : Cache := (build vol execP (always .off) 1 ⟨start, [], 7, [], 0, []⟩ [theStep]).cache

theorem it_ran : (build vol execP (always .off) 2 ⟨start, [], 9, warm, 0, []⟩ [theStep]).ran = 1 := rfl

theorem sees_this_runs_payload :
    (build vol execP (always .off) 2 ⟨start, [], 9, warm, 0, []⟩ [theStep]).outs = [⟨9, 0, [], 0⟩] := rfl

end EventMarked

/-! ## 11. The payload, withheld

What the runner does since #68: counterexample 9's own `exec`, unchanged, run as the enforcing runner
runs it (`Enforce.enforced`). The unmarked step finds `withheld_event` in both runs, so the replay is
what running gives. -/

namespace EventEnforced

open Runner.Enforce

def execP (i : Input) (_ : Trial) : Output := ⟨i.event, 0, [], 0⟩

def theStep : Step := ⟨1, 0, [], [], false⟩

def warm : Cache :=
  (build vol (enforced vol execP) (always .off) 1 ⟨start, [], 7, [], 0, []⟩ [theStep]).cache

theorem nothing_ran :
    (build vol (enforced vol execP) (always .off) 2 ⟨start, [], 9, warm, 0, []⟩ [theStep]).ran = 0 := rfl

theorem sound :
    (build vol (enforced vol execP) (always .off) 2 ⟨start, [], 9, warm, 0, []⟩ [theStep]).outs
      = uncached vol (enforced vol execP) (always .off) 2 9 start [] [] [theStep] := rfl

/-- What it logs is the withheld constant, in both runs, rather than either run's payload. -/
theorem reads_the_withheld_payload :
    (build vol (enforced vol execP) (always .off) 2 ⟨start, [], 9, warm, 0, []⟩ [theStep]).outs
      = [⟨withheldEvent, 0, [], 0⟩] := rfl

end EventEnforced

end Runner.Counterexamples
