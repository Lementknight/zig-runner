# Changelog

All notable changes to zig-runner are recorded here, one file per change under `.changes/`,
assembled by [changie](https://changie.dev). The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions up to v0.2.0 were released from
[Lementknight/zig-actions-runner](https://github.com/Lementknight/zig-actions-runner), where the
runner was developed; their entries below are written from those releases' notes.


## v0.9.0 - 2026-10-26
### Added
* CI checks the expression evaluator against GitHub's own expression test cases (from actions/languageservices): all but 1 of 1020 pass (GitHub's memory limit, which the runner keeps looser on purpose). Failures are listed in `runner/tools/exprcorpus-failing.txt`, and CI fails when a case breaks or when a listed one starts passing. `.github/scripts/expr-conformance.sh --report` shows what GitHub expects for each.
### Changed
* CI's test jobs on GitHub's runners call the compiler directly instead of through `zig build`, skipping the cold compile of Zig's build system: 15 s instead of 119 s on a laptop, where those steps took 81-116 s. The project's own runners still use `zig build test`.
* TLS to the database uses the [tls.zig](https://github.com/ianic/tls.zig) package (MIT, pinned in `build.zig.zon`) instead of a patched copy of Zig 0.17's TLS client, which had to be copied again with every Zig release. It answers a server that asks for a client certificate, as Tiger Data does, which std's client still cannot. Verification is unchanged: tested against TimescaleDB requesting client certificates, the full test suite passes over TLS, and an untrusted CA or a wrong host name is still refused.
### Fixed
* Workflow and action input can no longer crash the runner: indexing an array with a number no index can be (`foo[1e30]`, `foo[Infinity]`), a `timeout-minutes` too large to hold (`1e300`, `inf`), and an expression nested 100000 deep (`!!!…`, possible in an `action.yml`, which GitHub does not check) each stopped the whole runner. Expressions nested deeper than GitHub's limit of 50 are refused as GitHub refuses them, a long `&&`/`||` chain is evaluated without recursing, `fromJSON` refuses input nested more than 1000 deep, and the string-building functions stop at 10 MiB per expression instead of growing until memory runs out.
* Expressions evaluate as on GitHub where they differed: number literals and string-to-number coercion follow JavaScript's `Number()` (`.5`, `+1`, `-Infinity`, `0o17`, `0b101`; `-0xFF` is an error), numbers print with 15 significant digits, `NaN` is falsy, `case()` is supported, strings compare by their upper-case forms beyond ASCII (`'ü' == 'Ü'`, and `'a' < '['`), `a[*]` works and an index after a filter applies to each element, `a[true]` indexes like `a[1]`, `join()` of an object is empty, an empty expression is null, and an unknown function, a wrong number of arguments, or a name that is no context is an error when parsing, as GitHub reports them.
* More expressions evaluate as on GitHub, found by comparing 100000 random expressions with Gitea's evaluator and settling each difference against GitHub's source: `true`, `false`, `null`, `NaN` and `Infinity` are keywords only spelled so (`TRUE` is an unknown name); only a context, a function's result or a parenthesised expression can be indexed (`'abc'[0]` is an error); `1E-2` is one number token; a fractional index is rounded down; `a >= a` is true for arrays and objects; `contains`, `startsWith` and `endsWith` are false for an array or object argument; `toJSON` writes NaN and Infinity as `null`; `case()` evaluates all its arguments, as every function does; and a `*` filter's result stays a filter through a function (`case(c, a.*, b.*).name`).

## v0.8.0 - 2026-10-26
### Changed
* Runners start at once after a restart that finds stale registrations: those are removed in the background, still only once they have stayed offline for 60 s. The first runner listened after 3 s instead of 81 s.
### Fixed
* A request no longer fails after meeting 8 kept-alive connections the server had closed: it tries past every idle connection the pool keeps (33 tries, not 8). 16 runners registering at once left 16 such connections to GitHub a minute later, and the next request failed.

## v0.7.0 - 2026-10-26
### Added
* `RUNNER_ZIG_LOCAL_CACHE=true` (or `--zig-local-cache`) keeps Zig's local cache between jobs, in a cache volume of its own: about 1.2 s off each `zig build test` of zig-runner itself (10%), and 4-6 s when the repository's previous build had the same source. Off by default, because Zig never removes anything from that cache: it grows by about 50 MB per source version built, until the engine collects it.
### Changed
* `zig build test` also compiles the runner, so CI fails on a compile error in code the tests never reach (the runner's main loop), where it passed before.
### Fixed
* `RUNNER_UV_ENV_IN_CACHE` (and `--uv-env-in-cache`) takes effect: it was read but never passed on, so uv's environment always went in its cache volume.

## v0.6.2 - 2026-10-26
### Fixed
* A database that is slow or stops answering no longer holds up jobs: log lines and run-state rows are written by background tasks, never on a job's path. With the database paused for 60 s, jobs on 4 runners took 69-70 s instead of 17-19 s; now 16-17 s, and every line and row still reaches it.

## v0.6.1 - 2026-10-26
### Fixed
* Long-running runners: every connection to GitHub uses TCP keepalive, so one whose peer went away fails within about 90 s instead of waiting forever; a certificate rejected because the HTTP client still judged it by the time the process started gets a fresh client and is tried again; and a job log near the 64 MiB cap is uploaded whole, where its headers took the file past the cap and the upload was empty.

## v0.6.0 - 2026-10-26
### Added
* BENCHMARKS.md: what was measured on the reference Raspberry Pi, this week's numbers and the earlier study's, with their verdicts.
### Changed
* A runner starts its next job about 6 s sooner: 3-4 s between two jobs instead of 9 s, measured on a laptop with 4 runners. The end of a job no longer waits out a 5 s sleep in the cancel watch, uploads its step logs at once instead of one after another, and leaves deleting its session and registration to the background.
### Fixed
* Runners recover from a dropped network: a poll unanswered for 90 s is given up and sent again, where a laptop that slept left every runner offline until restarted. A failed acquirejob (connection error or 5xx) is tried again for up to 15.5 s instead of leaving the job for GitHub to reassign 70 s later.

## v0.5.0 - 2026-10-25
### Changed
* CI keeps Zig unpacked in the tool cache and checks the tree against a pinned digest instead of unpacking it every job: Install Zig takes 2-10 s instead of 9-16 s on razorbill and no longer writes 588 MB to its SD card.
### Fixed
* The Dagger engine gets 80 s to stop instead of Docker's 10 s, so a reboot or restart no longer wipes its cache: on razorbill the next job went from 56 s to 249 s.

## v0.4.1 - 2026-10-20
### Fixed
* zig-runner-deploy finds the plain zig-runner.service as well as zig-runner@*.service instances, and refuses a unit systemd does not know (a mistyped UNITS) before installing anything, instead of installing, failing to restart it, and rolling every instance back

## v0.4.0 - 2026-10-20
### Added
* CI runs the database tests against TimescaleDB, and they fail rather than skip when CI requires a database (ZIG_TEST_REQUIRE_DB); the GitHub client is tested over real connections to a local HTTP server, including that its token never follows a redirect to another host; and the stale-registration cleanup is tested across pages
* Releases deploy themselves to razorbill: the release workflow records a GitHub deployment, and zig-runner-deploy on the machine (a systemd timer) installs it once its checksum and provenance check out (built by release.yml from that tag on GitHub's runners), restarts every runner instance, and reports success, or puts the previous binary back and reports failure
### Fixed
* A runner whose repository was renamed or transferred registers under its current name, with a warning to update GH_SCOPE, and follows GitHub's redirects for requests without a body (it could not remove its registration: HttpRedirectLocationOversize); a runner removes the registrations a stopped runner of its own left behind; and a job failed before its steps (refused, or an unsupported container or services) fails in "Set up job", with "Complete job" keeping its own log

## v0.3.1 - 2026-10-20
### Changed
* CI tests on the project's own runners once their repository variables are set (PROD_RUNNER for pushes to main, PREPROD_RUNNER for pull requests and the merge queue), on GitHub's runner until then; Zig is cached between jobs in RUNNER_TOOL_CACHE and checked against its checksum every time

## v0.3.0 - 2026-10-20
### Added
* A prod runner runs only trusted jobs: RUNNER_TRUSTED_REFS and RUNNER_TRUSTED_EVENTS fail every job from another ref or event, or whose workflow file comes from another ref, before any step runs. Pull requests go to a pre-prod runner on a machine of its own (deploy/runner.preprod.env.example)

## v0.2.3 - 2026-10-20
### Added
* Releases are built by GoReleaser and carry signed build provenance (gh attestation verify), for the binaries and the image; the image also carries an SBOM and is scanned by Trivy, with its Dockerfile, before it is pushed; the Dockerfile pins its base image by digest and checks Zig against its checksum; Renovate replaces Dependabot and also keeps the image digests and the Zig, changie, GoReleaser and Trivy versions current; and OpenSSF Scorecard grades the repository weekly

## v0.2.2 - 2026-10-20
### Security
* The workflows grant no permissions by default and keep no credentials after checkout; actions are pinned by commit and kept current by Dependabot; Zig and changie are checked against pinned checksums; the release deploy key is loaded only in the step that pushes; the release starts from a push to main instead of pull_request_target; and CI checks the workflows with actionlint and zizmor

## v0.2.1 - 2026-10-20
### Added
* Releases are cut by CI on every merge into main, following semantic versioning: the branch prefix picks the bump (bugfix/, hotfix/, ci/ patch; feature/, feat/, release/, docs/, perf/, refactor/ minor; the breaking label major), CI rejects other prefixes, and the release commits build.zig.zon and the changelog to main, tags them, and uses the changie notes for the GitHub release
### Changed
* The code follows written conventions: no function over 70 lines, no line over 100 columns outside tests; the long functions were split into named helpers
* Every Dagger GraphQL query is built by a small query builder (`src/dagger/query.zig`), which escapes every argument and closes what it opens; no query text is written by hand
### Removed
* The repository holds only what the runner needs to build, run and deploy. The design documents, the specification, the deployment guide, the measurements, the Agda proofs and the development tools stay in Lementknight/zig-actions-runner

## v0.2.0 - 2026-10-13

### Added

* The tool cache is kept between jobs, so setup-node and friends download once
* A fuller default image: sudo, compilers, Python, psql and common tools

### Changed

* Steps are numbered as GitHub numbers them, and the checkout has its post step
* Jobs that end together are finished together, and the live feed stays open through silent steps
* A step's file commands are read with one query instead of five

### Fixed

* The release workflow lowercases the image name and can rebuild a tag's image

## v0.1.0 - 2026-10-13

### Added

* The runner: registers itself with GitHub as a just-in-time runner, takes jobs from the broker, runs their steps in a Dagger engine, and reports step and job logs to GitHub's results service
* `run:` steps in bash, sh and python; `uses:` steps for composite, JavaScript (on Bun, with Node as the fallback) and Docker actions, local actions, and their pre and post scripts
* A built-in checkout in place of actions/checkout: submodules, tags, full history, and the refs actions/checkout leaves
* Workflow commands in step output (`::add-mask::`, `::group::`, …), file commands (GITHUB_ENV, GITHUB_OUTPUT, GITHUB_PATH, GITHUB_STEP_SUMMARY), `hashFiles()`, OIDC tokens for jobs with `id-token: write`
* Step caching: unchanged steps are reused across runs through Dagger's cache; steps that use secrets always run
* Package managers' caches kept across jobs in Dagger cache volumes
* Steps may use the job's Dagger engine themselves
* Optional Postgres/TimescaleDB mode: run state and logs written through a pure-Zig PostgreSQL client with TLS; `runner --db-check`
* `runner --inspect` for looking at the broker protocol
* Static binaries for x86_64 and aarch64 Linux and a 2 MB container image, built by the release workflow
