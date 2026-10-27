import Glob.Match

/-!
# The walk: pruning loses nothing

glob.zig's `walk` goes depth-first from each search path, each directory's children in byte order,
and yields the files the patterns match. It does not look below a path that neither matches nor
partially matches any pattern (`keep`). Here that pruned walk is compared with the plain one, which
visits everything: they yield the same files in the same order, provided pruning only ever skips
paths with nothing to yield at or below them (`Prunable`). `pruned_eq_full` is that step.

`walk_eq_full` then shows the patterns give exactly such a `keep`: from `partial_of_match`, a path
that some file below it matches always partially matches. So the walk yields what the plain one
would, for any patterns and any tree.

Paths are lists of segments (`/w/a` is `["", "w", "a"]`), and a child's path is its parent's with
its name appended. The root `/` is left out of the model: the walk always keeps it (glob.zig's
`partialMatch` says yes to `/`), and it is a directory, never yielded. Symbolic links are not
followed here (the default); one is a leaf, yielded like a file, as GitHub's script does before
skipping any that is a directory.
-/

namespace Glob

/-- What the walk finds at a path: a leaf (a file, a link, anything but a directory), or a
directory with its children in the order the walk visits them (byte order of their names). A
missing path is simply absent. -/
inductive Tree where
  | leaf
  | dir (children : List (String × Tree))

section
variable (yield keep relevant : List String → Bool)

mutual
/-- The plain walk: every directory entered, each relevant child visited, matching leaves yielded. -/
def full (p : List String) : Tree → List (List String)
  | .leaf => if yield p then [p] else []
  | .dir cs => fullList p cs

def fullList (p : List String) : List (String × Tree) → List (List String)
  | [] => []
  | (n, t) :: cs => (if relevant (p ++ [n]) then full (p ++ [n]) t else []) ++ fullList p cs
end

mutual
/-- glob.zig's walk: a path that is not kept is not looked at, nor anything below it. -/
def pruned (p : List String) (t : Tree) : List (List String) :=
  if keep p then prunedNode p t else []

def prunedNode (p : List String) : Tree → List (List String)
  | .leaf => if yield p then [p] else []
  | .dir cs => prunedList p cs

def prunedList (p : List String) : List (String × Tree) → List (List String)
  | [] => []
  | (n, t) :: cs => (if relevant (p ++ [n]) then pruned (p ++ [n]) t else []) ++ prunedList p cs
end

/-- What pruning needs: a path not kept has nothing to yield, at it or anywhere below it. -/
def Prunable : Prop := ∀ p, keep p = false → ∀ r, yield (p ++ r) = false

mutual
theorem full_nil (p : List String) (h : ∀ r, yield (p ++ r) = false) :
    ∀ t, full yield relevant p t = []
  | .leaf => by simpa [full] using h []
  | .dir cs => by simpa [full] using fullList_nil p h cs

theorem fullList_nil (p : List String) (h : ∀ r, yield (p ++ r) = false) :
    ∀ cs, fullList yield relevant p cs = []
  | [] => by simp [fullList]
  | (n, t) :: cs => by
    have hc : ∀ r, yield ((p ++ [n]) ++ r) = false := fun r => by simpa using h (n :: r)
    simp [fullList, full_nil (p ++ [n]) hc t, fullList_nil p h cs]
end

variable {yield keep relevant}

mutual
/-- **Pruning loses nothing**: with a `Prunable` `keep`, the pruned walk yields exactly what the
plain one does, in the same order. -/
theorem pruned_eq_full (hk : Prunable yield keep) (p : List String) :
    ∀ t, pruned yield keep relevant p t = full yield relevant p t
  | t => by
    unfold pruned
    cases hp : keep p with
    | false => exact (full_nil yield relevant p (hk p hp) t).symm
    | true => exact prunedNode_eq_full hk p t

theorem prunedNode_eq_full (hk : Prunable yield keep) (p : List String) :
    ∀ t, prunedNode yield keep relevant p t = full yield relevant p t
  | .leaf => by simp [prunedNode, full]
  | .dir cs => by simpa [prunedNode, full] using prunedList_eq_full hk p cs

theorem prunedList_eq_full (hk : Prunable yield keep) (p : List String) :
    ∀ cs, prunedList yield keep relevant p cs = fullList yield relevant p cs
  | [] => by simp [prunedList, fullList]
  | (n, t) :: cs => by
    simp [prunedList, fullList, pruned_eq_full hk (p ++ [n]) t, prunedList_eq_full hk p cs]
end

end

/-! ## The patterns' `keep` is prunable -/

/-- What a pattern matches a path as (@actions/glob's MatchKind): as a directory, as a file. -/
structure Kind where
  dir : Bool
  file : Bool
  deriving Repr, DecidableEq

def Kind.none : Kind := ⟨false, false⟩

/-- A pattern, compiled: `!` (negate), its segments, a trailing `/` (directories only), and
whether a path is matched with a `/` appended (a pattern ending in `**`, not one of the implicit
`pattern/**` ones: minimatch matches `/foo/` to `/foo/**` but not `/foo`). -/
structure Pat (α : Type) where
  negate : Bool
  parts : List (Part α)
  dirOnly : Bool
  addSlash : Bool

variable {α : Type} (seg : α → String → Bool)

/-- `Pattern.match`: the path, with a `/` appended when the pattern asks (`""` as a last segment). -/
def Pat.match (p : Pat α) (path : List String) : Kind :=
  if matchOne seg false p.parts (if p.addSlash then path ++ [""] else path) then
    if p.dirOnly then ⟨true, false⟩ else ⟨true, true⟩
  else Kind.none

/-- `Pattern.partialMatch`, for a path other than `/`. -/
def Pat.partialMatch (p : Pat α) (path : List String) : Bool := matchOne seg true p.parts path

/-- `matchAll`: each pattern in turn adds what it matches, or a negated one takes it away. -/
def matchAll (pats : List (Pat α)) (path : List String) : Kind :=
  pats.foldl (fun acc p =>
    let m := p.match seg path
    if p.negate then ⟨acc.dir && !m.dir, acc.file && !m.file⟩
    else ⟨acc.dir || m.dir, acc.file || m.file⟩) Kind.none

/-- The walk's `keep`: a match, or a partial match by a pattern that is not negated. -/
def keepOf (pats : List (Pat α)) (path : List String) : Bool :=
  matchAll seg pats path != Kind.none || pats.any (fun p => !p.negate && p.partialMatch seg path)

/-- What the walk yields a leaf for: matched as a file. -/
def yieldOf (pats : List (Pat α)) (path : List String) : Bool := (matchAll seg pats path).file

/-- A path matched as a file was matched by some pattern that is not negated. -/
theorem matched_by_positive (pats : List (Pat α)) (path : List String) :
    yieldOf seg pats path = true →
      ∃ p ∈ pats, p.negate = false ∧ matchOne seg false p.parts
        (if p.addSlash then path ++ [""] else path) = true := by
  -- Through the fold: once the file bit is set, some positive pattern set it.
  suffices ∀ (ps : List (Pat α)) (acc : Kind),
      (ps.foldl (fun acc p =>
        let m := p.match seg path
        if p.negate then ⟨acc.dir && !m.dir, acc.file && !m.file⟩
        else ⟨acc.dir || m.dir, acc.file || m.file⟩) acc).file = true →
      acc.file = true ∨ ∃ p ∈ ps, p.negate = false ∧ matchOne seg false p.parts
        (if p.addSlash then path ++ [""] else path) = true by
    intro h
    rcases this pats Kind.none h with h0 | h1
    · exact absurd h0 (by decide)
    · exact h1
  intro ps
  induction ps with
  | nil => intro acc h; exact Or.inl h
  | cons q qs ih =>
    intro acc h
    rcases ih _ h with h' | ⟨p, hp, hn, hm⟩
    · cases hq : q.negate
      · simp [hq] at h'
        rcases h' with ha | hm
        · exact Or.inl ha
        · right
          refine ⟨q, List.mem_cons_self, hq, ?_⟩
          cases hmo : matchOne seg false q.parts (if q.addSlash then path ++ [""] else path)
          · simp [Pat.match, hmo, Kind.none] at hm
          · rfl
      · simp [hq] at h'
        exact Or.inl h'.1
    · exact Or.inr ⟨p, List.mem_cons_of_mem _ hp, hn, hm⟩

/-- **The patterns' `keep` is prunable**: a path below which (or at which) something is yielded is
kept. Below it, by `partial_of_match`; at it, because it matches. -/
theorem keepOf_prunable (pats : List (Pat α)) : Prunable (yieldOf seg pats) (keepOf seg pats) := by
  intro d hk r
  cases hy : yieldOf seg pats (d ++ r) with
  | false => rfl
  | true =>
    exfalso
    cases r with
    | nil =>
      -- Matched as a file, so matched: kept.
      simp only [List.append_nil, yieldOf] at hy
      simp only [keepOf, Bool.or_eq_false_iff, bne_eq_false_iff_eq] at hk
      rw [hk.1] at hy
      exact absurd hy (by decide)
    | cons x xs =>
      obtain ⟨p, hp, hn, hm⟩ := matched_by_positive seg pats _ hy
      have hpart : matchOne seg true p.parts d = true := by
        by_cases hs : p.addSlash
        · simp only [hs, ite_true, List.append_assoc] at hm
          exact partial_of_match seg p.parts d _ (by simp) hm
        · simp only [hs] at hm
          exact partial_of_match seg p.parts d _ (by simp) hm
      simp only [keepOf, Bool.or_eq_false_iff, List.any_eq_false] at hk
      have := hk.2 p hp
      simp [hn, Pat.partialMatch, hpart] at this

/-- **The walk yields what the plain walk does**, for any patterns and tree: every file the patterns
match, in depth-first order, children in byte order, and nothing else. -/
theorem walk_eq_full (pats : List (Pat α)) (relevant : List String → Bool) (p : List String) (t : Tree) :
    pruned (yieldOf seg pats) (keepOf seg pats) relevant p t = full (yieldOf seg pats) relevant p t :=
  pruned_eq_full (keepOf_prunable seg pats) p t

end Glob
