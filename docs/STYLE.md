# Style

How the runner's Zig code is written. Four sources, applied in a fixed order: Zig's own style guide
for names, semantic compression for when to make an abstraction, Locality of Behaviour for where
code lives, and TigerStyle for the rest. When two of them disagree, the order below decides; the end
of this file lists the cases that come up.

`zig fmt` is the formatter and CI checks it (`zig fmt --check build.zig build.zig.zon src tools`).
Nothing here overrides it.

## Names: Zig's style guide

- Functions `camelCase`, types `TitleCase`, variables, constants, fields and files that are
  namespaces `snake_case`. A file with top-level fields is a struct and is named for it:
  `dagger/Exec.zig`, `dagger/JobLog.zig`.
- Choose a name for how it reads fully qualified. `checkout.fetch`, not `checkout.fetchCheckout`;
  `services.Port`, not `services.ServicePort`. Methods are read through their type: `Exec.runDocker`
  is fine.
- No `utils`, `misc`, `helpers`, `Manager`, `Data` or `Context` as a name that says nothing. A
  helper lives in the file of the code that calls it. Where GitHub has a term (a "context", a "step
  summary"), use GitHub's term.
- TigerStyle's snake_case functions and files do not apply here: Zig's guide wins on naming.

## Abstractions: semantic compression

Write the code that does the thing first. Pull a function, type or module out only when a pattern
has actually repeated, in two or more places, or clearly the same shape twice in one place. A shape
seen once is not a pattern, and an abstraction made before the second use usually has the wrong
seams.

- Structure follows the call graph and the data, not a diagram of concepts. Values that always
  travel together become a struct (a token and when it was minted), because that is the repetition.
- A long function made of distinct steps that happen once stays one function. Mark its sections with
  comments that say why each step is there; do not split it into helpers called from one place.
- Removing repetition is a refactor of its own: one pull request, no behaviour change, tests
  unchanged.

## Where code lives: Locality of Behaviour

What a unit does should be visible where it is read. Following one step, one job or one log line
must not mean opening many files.

- Prefer fewer, deeper files over many shallow ones. A file boundary has to hide something (Docker,
  JavaScript runtimes, output keys, service containers) and be crossed rarely. Code that calls
  itself across a boundary in both directions belongs in one file (actions and composite steps).
- Tests sit at the bottom of the file whose behaviour they test, including the ones that run a whole
  job through `dagger.run`. Shared fakes go in `testing.zig` next to the code that uses them.
- Constants sit next to the code that reads them, not in a file of constants.

## The rest: TigerStyle

- **100 columns.** The repository wraps code and comments at 100; `zig fmt` does not do it for you.
  Break long string literals with `++` (compile-time, same bytes), including test fixtures.
- **Function length.** TigerStyle's 70-line limit is a prompt, not a rule: a function past 70 lines
  is a reason to look for a repeated pattern. If there is one, extract it; if there is not, the
  function stays whole with section comments (semantic compression wins).
- **Push `if`s up, `for`s down.** The caller decides whether something happens; the helper does it.
  A guard on a policy flag (`step_debug`, `package_caches`) belongs at the one call site, not at the
  top of the helper. A guard shared by many callers stays inside, or it would be repeated at each.
  Loops go into the leaf that processes the batch, and leaves are pure where they can be: they
  compute from their arguments and leave I/O, logging and `err_msg` to the caller.
- **Assertions.** Assert preconditions, postconditions and invariants: a step number within the
  arrays it indexes, numbers that only grow, a query closed before it is sent. Releases are built
  `ReleaseSafe`, so assertions stay on in production, and a failed one takes down the whole process
  with every runner and job in it. Assert only what is a bug in this code if false. Anything that
  comes from GitHub, the engine, a workflow or the network is validated and returned as an error.
- **Smallest scope.** Declare a variable where it is first needed, in the innermost block that uses
  it; prefer `const`.
- **Important code first.** In a file, the public entry point and the main types before their
  helpers. In a struct, fields, then nested types, then methods.

## Comments

Comments say why: what GitHub's runner does that this matches, what broke before (with the issue
number), what a value protects against. The code says what. This is already the habit in the
repository and the reason its files read as they do; keep it.

- Doc comments (`///`, `//!`) on every declaration another file uses, and on anything whose reason
  is not obvious.
- Name other code in backticks by the name a reader can search for (`` `Exec.outputKeyed` ``, ``
  `scan` ``). When code moves or is renamed, the same pull request updates what cites it, including
  `proofs/README.md` and the Lean files, which name runner functions by name.
- No commented-out code, no TODOs without an issue.

## When they conflict

| Conflict | Decision |
|---|---|
| TigerStyle snake_case functions and files vs Zig's guide | Zig's guide |
| 70-line limit vs semantic compression | Semantic compression: split only on repetition |
| Push `if`s up vs a guard used by many callers | Keep the guard inside the helper |
| Many small files vs Locality of Behaviour | Fewer, deeper files with a reason for each boundary |
| An assertion vs input from outside the process | An error, not an assertion |

## Changing structure

A move or rename is its own pull request: no behaviour change, the same number of tests passing,
bodies byte-identical apart from indentation and `pub`. Behaviour changes go in separate pull
requests.
