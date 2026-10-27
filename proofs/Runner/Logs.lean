import Runner.Prelude

/-!
# A replayed log, and why it is one stream (#71)

`Output.log` in `Runner.Model` is a step's log as one thing, and `Build.replay_logs_eq_run` says a
replay shows the log the run did. That is only honest if what the engine records *is* the log as it
was shown. A process has two output streams, and the engine records them apart — an exec's stdout
and its stderr, each in the order written, with nothing to say how the two interleaved. A live step's
log is the interleaving; a replay has only the two halves.

Before #71 `replayRecorded` printed the recorded stdout and then the recorded stderr, so a step that
wrote to both was replayed in a different order (`TwoStreams`): masks, `::stop-commands::` and
problem matchers, which depend on the order, could then apply differently. Since #71 a step's
script begins `exec 2>&1`, so everything the step writes goes to one stream, which the engine
records whole, in order, and the replay prints it as it is (`replay_merged`). The log the step
shows live is the same either way (`live_merged`): the runner showed both streams in one log
already.

Not modelled: blank lines and the runner's own markers, which `replayRecorded` also handles (markers
carry a per-job secret, so marker text a step prints is its output, live and in a replay).
-/

namespace Runner.Logs

/-- Which stream a line was written to. -/
inductive Stream where
  | out
  | err
  deriving DecidableEq, Repr

/-- A line of output: its stream and its text (a number, as every atom in the model). -/
abbrev Line := Stream × Nat

/-- The log a live step shows: every line, in the order written. -/
def live (ls : List Line) : List Nat := ls.map (·.2)

/-- What the engine records of one stream: its lines, in order, and nothing of the other's. -/
def recorded (s : Stream) (ls : List Line) : List Nat := (ls.filter (fun l => decide (l.1 = s))).map (·.2)

/-- `replayRecorded`: the recorded stdout, then the recorded stderr. -/
def replay (ls : List Line) : List Nat := recorded .out ls ++ recorded .err ls

/-- `exec 2>&1`: the step's stderr is its stdout, so every line is written to one stream. -/
def merged (ls : List Line) : List Line := ls.map (fun l => (.out, l.2))

/-- What a step writes to stdout alone is replayed as it ran. -/
theorem replay_of_stdout : ∀ ls : List Line, (∀ l ∈ ls, l.1 = .out) → replay ls = live ls
  | [], _ => rfl
  | (s, x) :: ls, h => by
    have hs : s = .out := h (s, x) (List.mem_cons_self ..)
    have ih := replay_of_stdout ls (fun l hl => h l (List.mem_cons_of_mem _ hl))
    subst hs
    simp only [replay, recorded, live, List.filter_cons, decide_true, ite_true, List.map_cons,
      List.cons_append] at ih ⊢
    simp only [reduceCtorEq, decide_false, Bool.false_eq_true, ite_false] at ih ⊢
    exact congrArg (x :: ·) ih

/-- **Since #71 a replay's log is the run's**, whatever the step wrote to which stream. -/
theorem replay_merged (ls : List Line) : replay (merged ls) = live ls := by
  rw [replay_of_stdout (merged ls) (fun l hl => by
    simp only [merged, List.mem_map] at hl
    obtain ⟨_, _, rfl⟩ := hl
    rfl)]
  simp [live, merged, Function.comp_def]

/-- And merging the streams does not change the log a live step shows. -/
theorem live_merged (ls : List Line) : live (merged ls) = live ls := by
  simp [live, merged, Function.comp_def]

/-! **Before #71**: a step that wrote a line to stdout, one to stderr, then one to stdout again. -/

namespace TwoStreams

def written : List Line := [(.out, 1), (.err, 2), (.out, 3)]

theorem live_log : live written = [1, 2, 3] := rfl

theorem replayed_log : replay written = [1, 3, 2] := rfl

/-- The replay showed the lines in another order than the run. -/
theorem reordered : replay written ≠ live written := by decide

/-- With `exec 2>&1` the same step is replayed as it ran. -/
theorem fixed : replay (merged written) = live written := rfl

end TwoStreams

end Runner.Logs
