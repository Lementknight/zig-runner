import Runner.Native

/-!
# `keyoracle`: the native key's vectors, from the model

Prints the vectors runner/src/native/testdata/step_keys.tsv holds, which
runner/src/native/key_vectors.zig checks the native store's key against. Each vector is two inputs,
whether the model says their keys are equal, and for each what the store is given and the preimage
it must hash. So the Zig side checks both the bytes (P2's format: `Store.KeyHasher`,
`Backend.keyFor`, `Backend.below`) and the relation (P2 and P3: what parts keys and what does not),
and the relation holds of any format the store adopts as long as it is a sound one
(`Native.native_key_iff`).

`.github/scripts/key-vectors.sh` checks the file is this program's output, and rewrites it with
`--write`.

    keyoracle > runner/src/native/testdata/step_keys.tsv

The format: u64 little-endian words (`Format.word`), atoms and scripts as UTF-8. A parent's key is
a sha256, which the model does not compute: the vectors' parents are given as 32 bytes of a number.
Each line is tab-separated, every byte string in lowercase hex, numbers in decimal:

    key    name equal|differ  A B   with A, B: tag parent script env uid gid workdir files preimage
    below  name equal|differ  A B   with A, B: format scope repository fingerprint userns idBase
                                         binds preimage

An environment is `name=value` pairs joined by `,` in the container's order, volatile names
included (the preimage has the stable ones); files are `path=contents=mode`, binds
`host=place=readOnly=optional` (0 or 1); `-` is an empty list.
-/

open Runner Runner.Build Runner.Native

def u64le (n : Nat) : Bytes := (List.range 8).map (fun i => n / 256 ^ i % 256)

def utf8 (s : String) : Bytes := s.toUTF8.toList.map (·.toNat)

/-- The atoms the vectors use, by number: variable names, then values, paths and the rest. -/
def atomText : Nat → String
  | 0 => "PATH"
  | 1 => "GITHUB_RUN_ID"
  | 2 => "HOME"
  | 3 => "GITHUB_SHA"
  | 4 => "Y"
  | 5 => "ZIG_RUNNER_EVENT"
  | 6 => "ZIG_RUNNER_RAN"
  | 7 => "ZIG_RUNNER_MARK"
  | 8 => "ZIG_SECRET_0"
  | 10 => "/usr/bin:/bin"
  | 11 => "123"
  | 12 => "456"
  | 13 => "/root"
  | 14 => "/home/runner"
  | 15 => "1"
  | 16 => "0123abcd"
  | 17 => "4567ef01"
  | 18 => "{\"inputs\":{}}"
  | 19 => "{\"inputs\":{\"v\":\"2\"}}"
  | 20 => "/"
  | 21 => "/home/runner/work/r/r"
  | 22 => "/github/workflow/event.json"
  | 23 => "fingerprint-a"
  | 24 => "fingerprint-b"
  | 25 => "mapped"
  | 26 => "inherited"
  | 27 => "/run/systemd/resolve/resolv.conf"
  | 28 => "/etc/resolv.conf"
  | 29 => "mkdir -p /home/runner/work/r/r /home/runner/work/_temp"
  | 31 => "zig-runner native store 2"
  | 33 => "repo"
  | 34 => "untrusted"
  | 35 => "Open-Blue/zig-runner"
  | 36 => "Open-Blue/other"
  | 32 => "zig-runner native store 1"
  | n => s!"atom{n}"

/-- The model's stable-env filter for these atoms, as `Store.stableEnv` has it: `GITHUB_RUN_ID` and
`GITHUB_SHA` are in dagger.zig's `volatile_env`, and the runner's own per-job values
(`ZIG_RUNNER_EVENT`, `ZIG_RUNNER_RAN`, `ZIG_RUNNER_MARK`) and the secret aliases (`ZIG_SECRET_*`)
are dropped too; `PATH`, `HOME` and `Y` are kept. key_vectors.zig filters with the real lists, so
the two must agree. -/
def vol : Volatile := fun n => [1, 3, 5, 6, 7, 8].contains n

def bodyText : Nat → String
  | 0 => "make test"
  | 1 => "make"
  | 2 => "x"
  | 3 => "xY=1"
  | n => s!"step{n}"

/-- A script's text: the position line, then the body; a stamped one ends with the always-run line,
as `scripts.zig` writes them (not byte for byte: what matters here is that the model's `Script`s
have different texts). -/
def scriptText : Script → String
  | .body b n => s!": step {n}\n{bodyText b}"
  | .stamped t s => s!"{scriptText s}\n: 'zig-runner runs this step every time (run {t})'"

def path : Binding := (0, 10)
def home : Binding := (2, 14)
def below0 : Below := ⟨31, 33, 35, 23, 25, 1900000000, [⟨27, 28, true, true⟩]⟩
def asRoot : Extra := ⟨0, 0, 20, []⟩
def eventFile (c : Nat) : Kept := ⟨22, c, 0o644⟩

/-- The bases the vectors name, each with its stable env. 2 to 4 differ from 0 in one thing each;
base 1's steps run as root, the others' as the runner user (`fmt.stepExtra`). -/
def baseOf : Nat → BaseSpec
  | 0 => ⟨below0, 29, [path, home], asRoot⟩
  | 1 => ⟨below0, 29, [path], asRoot⟩
  | 2 => ⟨below0, 29, [path, home], ⟨0, 0, 20, [eventFile 18]⟩⟩
  | 3 => ⟨below0, 29, [path, home], ⟨0, 0, 20, [eventFile 19]⟩⟩
  | 4 => ⟨{ below0 with idBase := 1900065536 }, 29, [path, home], asRoot⟩
  | 5 => ⟨{ below0 with scope := 34 }, 29, [path, home], asRoot⟩
  | n => ⟨below0, n, [], asRoot⟩

def fmt : Format where
  word := u64le
  width := 8
  str n := utf8 (atomText n)
  text sc := utf8 (scriptText sc)
  label := utf8 "below a base"
  base := baseOf
  stepExtra
    | 1 => ⟨0, 0, 21, []⟩
    | _ => ⟨1001, 1001, 21, []⟩

/-- Equality of the model's values, by their fields: the derived `DecidableEq` of a structure with a
`Bool` field does not compile to code. -/
def bindT (b : Bind) := (b.host, b.place, b.readOnly, b.optional)
def belowT (w : Below) := (w.format, w.scope, w.repository, w.fingerprint, w.userns, w.idBase, w.binds.map bindT)
def extraT (x : Extra) := (x.uid, x.gid, x.workdir, x.files.map fun k => (k.path, k.contents, k.mode))
def baseT (b : BaseSpec) := (belowT b.below, b.script, b.env, extraT b.extra)

/-- A parent's key, as the vectors give it: 32 bytes of a number. -/
def parentKey (n : Nat) : Bytes := List.replicate 32 n

def hexByte (n : Nat) : String :=
  let d := fun k => "0123456789abcdef".toList.getD k '0'
  String.ofList [d (n / 16), d (n % 16)]

def hex (bs : Bytes) : String := String.join (bs.map hexByte)

def list {α : Type} (g : α → String) (xs : List α) : String :=
  if xs.isEmpty then "-" else ",".intercalate (xs.map g)

def envField : Env → String := list fun b => hex (fmt.str b.1) ++ "=" ++ hex (fmt.str b.2)

def filesField : List Kept → String :=
  list fun k => s!"{hex (fmt.str k.path)}={hex (fmt.str k.contents)}={k.mode}"

def bit (x : Bool) : String := if x then "1" else "0"

def bindsField : List Bind → String :=
  list fun b => s!"{hex (fmt.str b.host)}={hex (fmt.str b.place)}={bit b.readOnly}={bit b.optional}"

/-- What the store is given for one key: the tag, the parent's key, the script, the whole env, the
extras; and its preimage, over the stable env. -/
structure KeySide where
  tag : Nat
  parent : Bytes
  script : Bytes
  env : Env
  extra : Extra

def KeySide.preimage (k : KeySide) : Bytes :=
  keyPreimage fmt k.tag k.parent k.script (stable vol k.env) k.extra

def KeySide.line (k : KeySide) : String :=
  "\t".intercalate [toString k.tag, hex k.parent, hex k.script, envField k.env, toString k.extra.uid,
    toString k.extra.gid, hex (fmt.str k.extra.workdir), filesField k.extra.files, hex k.preimage]

/-- A step's side: its parent is base `b`, so its extras are the base's `stepExtra`. -/
def stepSide (b : Nat) (sc : Script) (e : Env) : KeySide :=
  ⟨1, parentKey b, fmt.text sc, e, fmt.stepExtra b⟩

/-- A base's side, with the env as the job has it (`full`), whose stable part is the base's. Its
parent is the digest below it, given as 32 bytes of 176 for `below0` and 177 for another. -/
def baseSide (b : Nat) (full : Env) : KeySide :=
  ⟨0, parentKey (if belowT (baseOf b).below == belowT below0 then 176 else 177),
    fmt.str (baseOf b).script, full,
    (baseOf b).extra⟩

def input (b : Nat) (sc : Script) (e : Env) (ev : Content := 0) (m : Mounts := []) : Input :=
  ⟨.base b, sc, e, ev, m⟩

/-- Step vectors: Build's P3 theorems (`volatile_invisible`, `mounts_invisible`, `event_invisible`)
and the runner's own variables as equal pairs; its P2 theorems (`stable_env_matters`,
`text_matters`, `position_matters`, `parent_matters`), the stamp, the environment's order and
`Native.Ambiguous` as unequal ones. The verdict is the model's: `K` decided. -/
def stepVectors : List (String × Input × Input) :=
  [ ("volatile-value", input 0 (.body 0 1) [path, (1, 11)], input 0 (.body 0 1) [path, (1, 12)]),
    ("volatile-absent", input 0 (.body 0 1) [path, (1, 11), home], input 0 (.body 0 1) [path, home]),
    ("mounts-event-and-sha", input 0 (.body 0 1) [(3, 16), path] 5 [(30, 1)],
      input 0 (.body 0 1) [(3, 17), path] 6 [(30, 2)]),
    ("runner-own-variables", input 0 (.body 0 1) [path, (5, 18), (6, 16), (7, 11), (8, 15)],
      input 0 (.body 0 1) [path, (5, 19), (6, 17), (7, 12), (8, 4)]),
    ("stable-value", input 0 (.body 0 1) [path, home], input 0 (.body 0 1) [path, (2, 13)]),
    ("text", input 0 (.body 0 1) [path], input 0 (.body 1 1) [path]),
    ("position", input 0 (.body 0 1) [path], input 0 (.body 0 2) [path]),
    ("parent", input 0 (.body 0 1) [path], input 2 (.body 0 1) [path]),
    ("parent-and-user", input 0 (.body 0 1) [path], input 1 (.body 0 1) [path]),
    ("fork", input 0 (.body 0 1) [path], input 5 (.body 0 1) [path]),
    ("stamped", input 0 (.body 0 1) [path], input 0 (.stamped 42 (.body 0 1)) [path]),
    ("env-order", input 0 (.body 0 1) [path, home], input 0 (.body 0 1) [home, path]),
    ("ambiguous", input 0 (.body 2 1) [(4, 15)], input 0 (.body 3 1) []),
    ("empty-env", input 0 (.body 0 1) [], input 0 (.body 0 1) [(1, 11)]) ]

/-- Base vectors: two bases of the model, each with the env the job gives it. Equal when the model's
bases are (`Format.base_inj`): the same `BaseSpec` once the env is filtered. -/
def baseVectors : List (String × (Nat × Env) × (Nat × Env)) :=
  [ ("base-event-variable", (0, [path, home, (5, 18), (6, 16)]), (0, [path, home, (5, 19), (6, 17)])),
    ("base-env", (0, [path, home]), (1, [path])),
    ("base-event-file", (2, [path, home]), (3, [path, home])),
    ("base-file-or-none", (0, [path, home]), (2, [path, home])),
    ("base-slot", (0, [path, home]), (4, [path, home])),
    ("base-fork", (0, [path, home]), (5, [path, home])) ]

def belowVectors : List (String × Below × Below) :=
  [ ("below-same", below0, below0),
    ("below-store-format", below0, { below0 with format := 32 }),
    ("below-fork", below0, { below0 with scope := 34 }),
    ("below-repository", below0, { below0 with repository := 36 }),
    ("below-rootfs", below0, { below0 with fingerprint := 24 }),
    ("below-userns", below0, { below0 with userns := 26, idBase := 0 }),
    ("below-slot", below0, { below0 with idBase := 1900065536 }),
    ("below-read-only", below0, { below0 with binds := [⟨27, 28, false, true⟩] }),
    ("below-no-binds", below0, { below0 with binds := [] }) ]

def belowLine (w : Below) : String :=
  "\t".intercalate [hex (fmt.str w.format), hex (fmt.str w.scope), hex (fmt.str w.repository),
    hex (fmt.str w.fingerprint), hex (fmt.str w.userns), toString w.idBase,
    bindsField w.binds, hex (belowPreimage fmt w)]

def baseNum : State → Nat
  | .base b => b
  | _ => 0

def main : IO UInt32 := do
  let mut ok := true
  let verdict := fun (b : Bool) => if b then "equal" else "differ"
  for (name, i, j) in stepVectors do
    let same := decide (K vol i = K vol j)
    let a := stepSide (baseNum i.parent) i.script i.env
    let b := stepSide (baseNum j.parent) j.script j.env
    -- The spelling is sound for these, so the preimages are equal exactly when the keys are.
    if same != (a.preimage == b.preimage) then
      IO.eprintln s!"{name}: the preimages disagree with the model's keys"
      ok := false
    IO.println ("\t".intercalate ["key", name, verdict same, a.line, b.line])
  for (name, (bi, ei), (bj, ej)) in baseVectors do
    let spec := fun (b : Nat) (e : Env) => { baseOf b with env := stable vol e }
    let same := baseT (spec bi ei) == baseT (spec bj ej)
    let a := baseSide bi ei
    let b := baseSide bj ej
    if same != (a.preimage == b.preimage) then
      IO.eprintln s!"{name}: the preimages disagree with the model's bases"
      ok := false
    IO.println ("\t".intercalate ["key", name, verdict same, a.line, b.line])
  for (name, v, w) in belowVectors do
    let same := belowT v == belowT w
    if same != (belowPreimage fmt v == belowPreimage fmt w) then
      IO.eprintln s!"{name}: the preimages disagree with the model's"
      ok := false
    IO.println ("\t".intercalate ["below", name, verdict same, belowLine v, belowLine w])
  return if ok then 0 else 1
