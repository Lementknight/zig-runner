import Runner.Native

/-!
# `keyoracle`: the native key's vectors, from the model

Prints the vectors runner/src/native/testdata/step_keys.tsv holds, which
runner/src/native/key_vectors.zig checks the native store's key against. Each vector is two step
inputs of the model, whether the model's keys are equal (`Build.K`, decided), and for each input
what the store is given (the parent's key, the script's text, the full environment, volatile
variables included) and the preimage it must hash (`Native.stepPreimage` of the stable
environment). So the Zig side checks both the bytes (the format P8 specifies) and the relation
(P2 and P3: what parts keys and what does not), and the relation holds of any format the store
adopts as long as it is a sound one (`Native.native_key_iff`).

`.github/scripts/key-vectors.sh` checks the file is this program's output, and rewrites it with
`--write`.

    keyoracle > runner/src/native/testdata/step_keys.tsv

The format: u64 little-endian words (`Format.word`), atoms and scripts as UTF-8. A parent's key is
its sha256; the vectors' parents are bases, whose keys are given as 32 bytes of the base's number.
Each line, tab-separated:

    name  equal|differ  parentA scriptA envA preimageA  parentB scriptB envB preimageB

with every byte string in lowercase hex, and an environment as `name=value` pairs of hex joined by
`,` (`-` when empty), in the container's order.
-/

open Runner Runner.Build Runner.Native

def u64le (n : Nat) : Bytes := (List.range 8).map (fun i => n / 256 ^ i % 256)

def utf8 (s : String) : Bytes := s.toUTF8.toList.map (·.toNat)

/-- The atoms the vectors use, by number: variable names first, then values. -/
def atomText : Nat → String
  | 0 => "PATH"
  | 1 => "GITHUB_RUN_ID"
  | 2 => "HOME"
  | 3 => "GITHUB_SHA"
  | 4 => "Y"
  | 10 => "/usr/bin:/bin"
  | 11 => "123"
  | 12 => "456"
  | 13 => "/root"
  | 14 => "/home/runner"
  | 15 => "1"
  | 16 => "0123abcd"
  | 17 => "4567ef01"
  | n => s!"atom{n}"

/-- The model's `volatile_env` for these atoms: `GITHUB_RUN_ID` and `GITHUB_SHA` are in dagger.zig's,
`PATH`, `HOME` and `Y` are not. key_vectors.zig filters with the real list, so the two must agree. -/
def vol : Volatile := fun n => n == 1 || n == 3

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

def fmt : Format where
  word := u64le
  width := 8
  str n := utf8 (atomText n)
  text sc := utf8 (scriptText sc)

/-- A base's key, as the vectors give it: 32 bytes of its number. -/
def parentKey : State → Bytes
  | .base b => List.replicate 32 b
  | _ => []

def hexByte (n : Nat) : String :=
  let d := fun k => "0123456789abcdef".toList.getD k '0'
  String.ofList [d (n / 16), d (n % 16)]

def hex (bs : Bytes) : String := String.join (bs.map hexByte)

def envField (e : Env) : String :=
  if e.isEmpty then "-"
  else ",".intercalate (e.map fun b => hex (fmt.str b.1) ++ "=" ++ hex (fmt.str b.2))

def preimage (i : Input) : Bytes := stepPreimage fmt (parentKey i.parent) i.script (stable vol i.env)

def side (i : Input) : String :=
  "\t".intercalate [hex (parentKey i.parent), hex (fmt.text i.script), envField i.env, hex (preimage i)]

def input (b : Nat) (sc : Script) (e : Env) (ev : Content := 0) (m : Mounts := []) : Input :=
  ⟨.base b, sc, e, ev, m⟩

def path : Binding := (0, 10)
def home : Binding := (2, 13)

/-- The vectors: Build's P3 theorems (`volatile_invisible`, `mounts_invisible`, `event_invisible`)
as equal pairs, and its P2 theorems (`stable_env_matters`, `text_matters`, `position_matters`,
`parent_matters`) and the stamp, the order of the environment and `Native.Ambiguous` as unequal
ones. -/
def vectors : List (String × Input × Input) :=
  [ ("volatile-value", input 0 (.body 0 1) [path, (1, 11)], input 0 (.body 0 1) [path, (1, 12)]),
    ("volatile-absent", input 0 (.body 0 1) [path, (1, 11), home], input 0 (.body 0 1) [path, home]),
    ("mounts-event-and-sha", input 0 (.body 0 1) [(3, 16), path] 5 [(7, 1)],
      input 0 (.body 0 1) [(3, 17), path] 6 [(7, 2)]),
    ("stable-value", input 0 (.body 0 1) [path, home], input 0 (.body 0 1) [path, (2, 14)]),
    ("text", input 0 (.body 0 1) [path], input 0 (.body 1 1) [path]),
    ("position", input 0 (.body 0 1) [path], input 0 (.body 0 2) [path]),
    ("parent", input 0 (.body 0 1) [path], input 1 (.body 0 1) [path]),
    ("stamped", input 0 (.body 0 1) [path], input 0 (.stamped 42 (.body 0 1)) [path]),
    ("env-order", input 0 (.body 0 1) [path, home], input 0 (.body 0 1) [home, path]),
    ("ambiguous", input 0 (.body 2 1) [(4, 15)], input 0 (.body 3 1) []),
    ("empty-env", input 0 (.body 0 1) [], input 0 (.body 0 1) [(1, 11)]) ]

def main : IO UInt32 := do
  let mut ok := true
  for (name, i, j) in vectors do
    let same := decide (K vol i = K vol j)
    -- The spelling is sound for these, so the preimages are equal exactly when the keys are.
    if same != (preimage i == preimage j) then
      IO.eprintln s!"{name}: the preimages disagree with the model's keys"
      ok := false
    IO.println ("\t".intercalate [name, if same then "equal" else "differ", side i, side j])
  return if ok then 0 else 1
