import Lean.Data.Json
import Glob

/-!
# `globoracle`: the Lean model, run

Reads hashFiles() cases (one JSON object per line, as `runner/tools/globleancorpus.zig gen` writes
them) and answers each with the files the model's walk yields: `Glob.pruned`, with the patterns'
`Glob.keepOf` and `Glob.yieldOf`, the definitions `Glob.walk_eq_full` is proved of. The patterns
are read as glob.zig reads them (`Pattern.init`, implicit descendants, search paths), for the
pattern language the generator keeps to: names, `*`, `?`, `**`, classes, `!`, a trailing `/`,
relative or absolute. `.github/scripts/glob-lean-diff.sh` compares the answers with glob.zig's.

    globoracle < cases.jsonl > answers.jsonl
-/

open Lean Glob

/-! ## Segments: minimatch's, for the generated patterns -/

inductive Tok where
  | char (c : Char)
  | any
  | star
  | cls (negated : Bool) (chars : List Char)

inductive Seg where
  | lit (s : String)
  | magic (toks : List Tok)

def tokOk : Tok → Char → Bool
  | .char c, d => c == d
  | .any, _ => true
  | .star, _ => true
  | .cls neg cs, d => cs.contains d != neg

def matchToks : List Tok → List Char → Bool
  | [], cs => cs.isEmpty
  | .star :: ts, [] => matchToks ts []
  | .star :: ts, c :: cs => matchToks ts (c :: cs) || matchToks (.star :: ts) cs
  | _ :: _, [] => false
  | t :: ts, c :: cs => tokOk t c && matchToks ts cs

/-- glob.zig's `matchPart`: a glob never matches an empty segment, `.` or `..`. -/
def segMatch : Seg → String → Bool
  | .lit s, f => s == f
  | .magic toks, f => f != "" && f != "." && f != ".." && matchToks toks f.toList

partial def compileToks : List Char → List Tok → Bool → List Tok × Bool
  | [], acc, magic => (acc.reverse, magic)
  | '*' :: cs, acc, _ => compileToks cs (match acc with | .star :: _ => acc | _ => .star :: acc) true
  | '?' :: cs, acc, _ => compileToks cs (.any :: acc) true
  | '[' :: cs, acc, magic =>
    let (neg, body) := match cs with
      | '!' :: r => (true, r) | '^' :: r => (true, r) | r => (false, r)
    match body.span (· != ']') with
    | (chars@(_ :: _), ']' :: rest) => compileToks rest (.cls neg chars :: acc) true
    | _ => compileToks cs (.char '[' :: acc) magic
  | c :: cs, acc, magic => compileToks cs (.char c :: acc) magic

/-- `compilePart`, without escapes (the generator writes none). -/
def compilePart (s : String) : Part Seg :=
  if s == "**" then .globstar else
  let (toks, magic) := compileToks s.toList [] false
  if magic then .seg (.magic toks) else .seg (.lit s)

partial def literalChars : List Char → List Char → Option (List Char)
  | [], acc => some acc.reverse
  | '*' :: _, _ => none
  | '?' :: _, _ => none
  | '[' :: cs, acc =>
    match cs.span (· != ']') with
    | ([c], ']' :: rest) => literalChars rest (c :: acc)
    | (_ :: _ :: _, ']' :: _) => none
    | _ => literalChars cs ('[' :: acc)
  | c :: cs, acc => literalChars cs (c :: acc)

/-- `literalOf`: the literal a segment stands for, or "" if it holds a glob. -/
def literalOf (s : String) : String :=
  match literalChars s.toList [] with
  | some cs => String.ofList cs
  | none => ""

/-! ## Paths, as @actions/glob handles them -/

def trimTrailing (p : String) : String :=
  if p.length > 1 && p.endsWith "/" then p.dropEnd 1 |>.toString else p

def segmentsOf (p : String) : List String :=
  let t := trimTrailing p
  if t.startsWith "/" then
    let rest := (t.drop 1).toString
    "/" :: (if rest.isEmpty then [] else rest.splitOn "/")
  else t.splitOn "/"

def joinSegments (segs : List String) : String :=
  segs.foldl (fun out s => if out.isEmpty then s else if out.endsWith "/" then out ++ s else out ++ "/" ++ s) ""

def dirname (p : String) : String :=
  let t := trimTrailing p
  match (t.toList.reverse.dropWhile (· != '/')) with
  | [] => "."
  | ['/'] => "/"
  | _ :: rest => String.ofList rest.reverse

/-- Whether anything at or below `path` can be inside `within` (glob.zig's `relevant`). -/
def relevant (path within : String) : Bool :=
  let p := trimTrailing path
  p == within || (p.startsWith (within ++ "/")) || p == "/" || within.startsWith (p ++ "/")

/-! ## Patterns -/

structure Pattern where
  negate : Bool
  segments : List String
  trailing : Bool
  searchPath : String
  implicit : Bool
  parts : List (Part Seg)

/-- `Pattern.init` for the generated patterns: `!`s, `.`/`..` refused, made absolute under `cwd`. -/
def Pattern.init (line cwd : String) (implicit : Bool) : Option Pattern := Id.run do
  let mut p := line.trimAscii.toString
  let mut negate := false
  while p.startsWith "!" do
    negate := !negate
    p := (p.drop 1).trimAscii.toString
  if p.isEmpty then return none
  for (s, i) in (segmentsOf p).zipIdx do
    let lit := literalOf s
    if (lit == "." && i != 0) || lit == ".." then return none
  if p == "." || p.startsWith "./" then p := cwd ++ (p.drop 1).toString
  else if !p.startsWith "/" then p := cwd ++ (if cwd.endsWith "/" then "" else "/") ++ p
  let segments := segmentsOf p
  let trailing := p.endsWith "/"
  p := trimTrailing p
  let search := segments.takeWhile (fun s => literalOf s != "") |>.map literalOf
  let parts := (p.splitOn "/").map compilePart |>.foldl (fun acc part =>
    match acc, part with
    | .globstar :: _, .globstar => acc
    | _, _ => part :: acc) [] |>.reverse
  return some { negate, segments, trailing, searchPath := joinSegments search, implicit, parts }

def Pattern.lastIsGlobstar (p : Pattern) : Bool := p.segments.getLast? == some "**"

/-- The model's pattern: what `Glob.matchAll` and `Glob.keepOf` take. -/
def Pattern.toPat (p : Pattern) : Pat Seg :=
  { negate := p.negate, parts := p.parts, dirOnly := p.trailing,
    addSlash := p.lastIsGlobstar && !p.implicit }

/-- Implicit descendants: `pattern/**` added after each pattern not ending in `**`. -/
def withDescendants (ps : List Pattern) : List Pattern :=
  ps.flatMap fun p =>
    if p.trailing || !p.lastIsGlobstar then
      let text := joinSegments (p.segments ++ ["**"])
      match Pattern.init ((if p.negate then "!" else "") ++ text) "/" true with
      | some d => [p, d]
      | none => [p]
    else [p]

/-- `searchPaths`: each including pattern's, leaving out those below another's. -/
def searchPaths (ps : List Pattern) : List String := Id.run do
  let candidates := ps.filter (!·.negate) |>.map (·.searchPath)
  let mut included : List String := []
  for p in ps do
    if p.negate || included.contains p.searchPath then continue
    let mut key := p.searchPath
    let mut parent := dirname key
    let mut found := false
    for _ in [0:key.length + 1] do
      if parent == key then break
      if candidates.contains parent then
        found := true
        break
      key := parent
      parent := dirname key
    if !found then included := included ++ [p.searchPath]
  return included

/-! ## Trees, and the walk -/

instance : Inhabited Tree := ⟨.leaf⟩

partial def treeOf (j : Json) : Tree :=
  match j with
  | .obj kvs =>
    let cs := kvs.foldl (fun acc k v => (k, treeOf v) :: acc) []
    -- In byte order, as the walk visits them (for ASCII names, `<` on strings is byte order).
    .dir (cs.mergeSort (fun a b => !(b.1 < a.1)))
  | _ => .leaf

def pathOf (segs : List String) : String := "/".intercalate segs

/-- The tree at a path, `/`'s children being `w`'s tree. -/
def lookup : Tree → List String → Option Tree
  | t, [] => some t
  | .dir cs, n :: ns => (cs.find? (·.1 == n)).bind fun c => lookup c.2 ns
  | .leaf, _ :: _ => none

def answer (patterns : List String) (w : Tree) : Option (List String) := do
  let ps ← patterns.mapM (Pattern.init · "/w" false)
  let all := withDescendants ps
  let pats := all.map Pattern.toPat
  let root := Tree.dir [("w", w)]
  let rel := fun segs => relevant (pathOf segs) "/w"
  some <| (searchPaths all).filter (relevant · "/w") |>.flatMap fun sp =>
    let segs := sp.splitOn "/"
    match lookup root segs.tail with
    | none => []
    | some t => (pruned (yieldOf segMatch pats) (keepOf segMatch pats) rel segs t).map pathOf

def main : IO Unit := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    let line := line.trimAscii.toString
    if line.isEmpty then continue
    let j ← IO.ofExcept (Json.parse line)
    let id ← IO.ofExcept (j.getObjValAs? Nat "id")
    let patterns ← IO.ofExcept (j.getObjValAs? (List String) "patterns")
    let tree ← IO.ofExcept (j.getObjVal? "tree")
    let out : Json := match answer patterns (treeOf tree) with
      | some files => Json.mkObj [("id", id), ("files", toJson files)]
      | none => Json.mkObj [("id", id), ("invalid", true)]
    stdout.putStrLn out.compress
