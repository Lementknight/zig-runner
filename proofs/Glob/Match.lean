/-!
# minimatch's `matchOne`, as `runner/src/glob.zig` has it

A path and a pattern, both split at `/` into segments (`/a/b` is `["", "a", "b"]`), are matched
segment by segment. `**` (`Part.globstar`) matches any run of segments, but never `.` or `..`;
any other pattern segment matches one path segment, by whatever `seg` says. That is a parameter:
the theorems here hold for every segment matcher, so for all of minimatch's (`*`, `?`, classes,
escapes) at once.

With `prefixOk` set (glob.zig's `partial`), the path only has to match a prefix of the pattern: could something below this
path match? The walk asks that of each directory, and skips what it says no to, so the walk is only
right if that answer is never wrong. `partial_of_match` is that theorem.
-/

namespace Glob

/-- One segment of a compiled pattern (`Part` in glob.zig, `literal` and `magic` alike being `seg`). -/
inductive Part (α : Type) where
  | globstar
  | seg (a : α)
  deriving Repr, DecidableEq

/-- `.` and `..`, which `**` never swallows. -/
def isDot (s : String) : Bool := s == "." || s == ".."

variable {α : Type} (seg : α → String → Bool)

/-- `**` followed by more pattern (`rest` matches what follows): it swallows segments, none of
them `.` or `..`, until `rest` matches what is left. Run out of path, and only a partial match (`prefixOk`) is
still possible. -/
def swallow (prefixOk : Bool) (rest : List String → Bool) : List String → Bool
  | [] => prefixOk
  | g :: gs => rest (g :: gs) || (!isDot g && swallow prefixOk rest gs)

/-- glob.zig's `matchOne(file, pat, partial)`, the pattern first. The cases follow its loop:
- both used up: a match;
- the pattern used up with one segment left, which is empty (`/a/` against `/a`): a match;
- the path used up first: a match only if `prefixOk`;
- `**` last: the rest of the path, if none of it is `.` or `..`;
- `**` before more: `swallow`;
- any other segment: it must match, and the rest after it. -/
def matchOne (prefixOk : Bool) : List (Part α) → List String → Bool
  | [], [] => true
  | [], [f] => f == ""
  | [], _ :: _ :: _ => false
  | _ :: _, [] => prefixOk
  | [.globstar], f :: fs => (f :: fs).all (fun s => !isDot s)
  | .globstar :: p :: ps, f :: fs => swallow prefixOk (matchOne prefixOk (p :: ps)) (f :: fs)
  | .seg a :: ps, f :: fs => seg a f && matchOne prefixOk ps fs

/-- `swallow` succeeds exactly when it can skip some segments, none a dot, and `rest` matches
what follows them; or it skips them all and `prefixOk` is set. -/
theorem swallow_true {prefixOk : Bool} {rest : List String → Bool} :
    ∀ {xs : List String}, swallow prefixOk rest xs = true →
      (∃ pre suf, xs = pre ++ suf ∧ suf ≠ [] ∧ pre.all (fun s => !isDot s) = true ∧ rest suf = true) ∨
      (prefixOk = true ∧ xs.all (fun s => !isDot s) = true)
  | [], h => Or.inr ⟨h, rfl⟩
  | g :: gs, h => by
    simp only [swallow, Bool.or_eq_true, Bool.and_eq_true, Bool.not_eq_true'] at h
    rcases h with h | ⟨hg, h⟩
    · exact Or.inl ⟨[], g :: gs, rfl, by simp, rfl, h⟩
    · rcases swallow_true h with ⟨pre, suf, hxs, hne, hpre, hr⟩ | ⟨hp, hall⟩
      · refine Or.inl ⟨g :: pre, suf, by simp [hxs], hne, ?_, hr⟩
        simp [hg, hpre]
      · exact Or.inr ⟨hp, by simp [hg, hall]⟩

/-- The converse direction for the partial case: `rest` matching after a prefix free of dots. -/
theorem swallow_of_rest {rest : List String → Bool} :
    ∀ (pre : List String) {suf : List String}, suf ≠ [] →
      pre.all (fun s => !isDot s) = true → rest suf = true → swallow true rest (pre ++ suf) = true
  | [], suf, hne, _, hr => by
    cases suf with
    | nil => exact absurd rfl hne
    | cons g gs => simp [swallow, hr]
  | p :: ps, suf, hne, hpre, hr => by
    simp only [List.all_cons, Bool.and_eq_true, Bool.not_eq_true'] at hpre
    simp [swallow, hpre.1, swallow_of_rest ps hne hpre.2 hr]

/-- `swallow true` succeeds on a path free of dots, `rest` or not: the path may run out first. -/
theorem swallow_of_all {rest : List String → Bool} :
    ∀ {xs : List String}, xs.all (fun s => !isDot s) = true → swallow true rest xs = true
  | [], _ => rfl
  | g :: gs, h => by
    simp only [List.all_cons, Bool.and_eq_true, Bool.not_eq_true'] at h
    simp [swallow, h.1, swallow_of_all h.2]

/-- **Partial matching is never wrong to say no.** If a path below `d` (`d ++ r`, `r` not empty)
matches the pattern, then `d` partially matches it. So the walk, which does not descend where
there is no partial match, misses nothing. -/
theorem partial_of_match :
    ∀ (pat : List (Part α)) (d r : List String), r ≠ [] →
      matchOne seg false pat (d ++ r) = true → matchOne seg true pat d = true
  | [], d, r, hr, h => by
    -- Only `[""]` matches the empty pattern, and it has no proper prefix but `[]`.
    match d, r, hr, h with
    | [], _, _, _ => rfl
    | [_], _ :: _, _, h => simp [matchOne] at h
    | _ :: _ :: _, _ :: _, _, h => simp [matchOne] at h
  | _ :: _, [], _, _, _ => by simp [matchOne]
  | [.globstar], f :: fs, r, _, h => by
    simp only [List.cons_append, matchOne, List.all_cons, List.all_append, Bool.and_eq_true] at h ⊢
    exact ⟨h.1, h.2.1⟩
  | .globstar :: p :: ps, f :: fs, r, hr, h => by
    have h' : swallow false (matchOne seg false (p :: ps)) ((f :: fs) ++ r) = true := h
    show swallow true (matchOne seg true (p :: ps)) (f :: fs) = true
    rcases swallow_true h' with ⟨pre, suf, hxs, _, hpre, hrest⟩ | ⟨hp, _⟩
    · -- `**` swallowed `pre`; the rest of the pattern matched `suf`. Either `pre` covers all of
      -- `d`, or `suf` starts inside `d` and the rest partially matches what is left of `d`.
      rcases List.append_eq_append_iff.mp hxs with ⟨mid, hpre', _⟩ | ⟨mid, hd, hsuf⟩
      · -- `pre = d ++ mid`: all of `d` was swallowed, none of it a dot.
        rw [hpre', List.all_append, Bool.and_eq_true] at hpre
        exact swallow_of_all hpre.1
      · -- `d = pre ++ mid`, `suf = mid ++ r`.
        rw [hd]
        cases mid with
        | nil =>
          rw [List.append_nil] at hd ⊢
          exact swallow_of_all (hd ▸ hpre)
        | cons m ms =>
          have hsub := partial_of_match (p :: ps) (m :: ms) r hr (hsuf ▸ hrest)
          exact swallow_of_rest pre (by simp) hpre hsub
    · exact absurd hp (by decide)
  | .seg a :: ps, f :: fs, r, hr, h => by
    simp only [List.cons_append, matchOne, Bool.and_eq_true] at h ⊢
    exact ⟨h.1, partial_of_match ps fs r hr h.2⟩

end Glob
