// Command hashfilesdiff is the Go half of .github/scripts/hashfiles-diff.sh, which compares which
// files the runner's hashFiles() selects with which GitHub's selects.
//
//	go run . setup -out <dir> [-n 400] [-seed 1]     a test tree in <dir>/tree, cases in <dir>/cases.json
//	go run . glob -tree <dir> -plan <globs.json>    what Dagger's glob lists for each glob, as JSON
//	go run . contents -tree <dir> -plan <dirs.json> what is in each directory, by its path, as JSON
//
// The runner lists files with Dagger's Directory.glob (runner/src/dagger.zig) and picks among them
// with runner/src/hashfiles.zig; GitHub's runner runs a Node script on @actions/glob
// (reference.mjs here is that script, reporting the files instead of hashing them). glob asks the
// engine at _EXPERIMENTAL_DAGGER_RUNNER_HOST, through Dagger's Go SDK, at the engine's version.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strings"

	"dagger.io/dagger"
)

// The test tree: the files a repository has (lockfiles at several depths, vendored and installed
// dependencies, dotfiles), and names that mean something to a glob.
var files = []string{
	"package.json", "package-lock.json", "sub/package-lock.json", "sub/deeper/package-lock.json",
	"node_modules/x/package-lock.json", "node_modules/.bin/tool", ".hidden/file.json", ".dotfile",
	".github/workflows/ci.yml", "a b/space file.txt", "UPPER.TXT", "lower.txt", "dir.json/inner.txt",
	"deep/a/b/c/file.go", "go.sum", "go.mod", "src/main.go", "src/main_test.go", "src/util/util.go",
	"vendor/x/x.go", "brackets[1].txt", "star*.txt", "q?.txt", "#hash.txt", "!bang.txt", "-dash.txt",
	"café.txt", "src/.env", "deep/.cache/x.go",
}

var symlinks = map[string]string{"linkdir": "src", "link.go": "src/main.go", "broken": "nowhere"}

// Patterns as workflows write them, and ones that probe the corners. The workspace is /tree.
var pool = []string{
	"**/package-lock.json", "package-lock.json", "**/*.json", "*.json", "**/*.go", "src", "src/",
	"src/**", "src/*.go", "./src/*.go", "/tree/go.sum", "/tree", "/elsewhere/x", "#comment",
	"  lower.txt  ", "**/node_modules", "**/node_modules/**", "*", ".*", "**/.*", "*/", "**",
	"brackets[1].txt", "brackets\\[1\\].txt", "café.txt", "CAFÉ.txt", "Lower.txt", "src/{main,util}.go",
	"src/*.{go,mod}", "**/*.[Gg][Oo]", "deep/**", "deep/**/c", "deep/*/file.go", "linkdir/*.go",
	"link.go", "broken", "emptydir", "a b", "a b/*.txt", "**/**/*.go", "src//main.go", "src/./main.go",
	"../tree/go.sum", "?ower.txt", "[lU]*.T?T", "star\\*.txt", "q\\?.txt", "\\#hash.txt", "\\!bang.txt",
	"-dash.txt", "*.TXT", "**/*.txt", "go.*", "src/**/*.go", "src/*/", ".github/**/*.yml", "**/.env",
	"src/*", "deep/*", "deep/a/*", "sub/*", "*/*", "node_modules/*",
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: hashfilesdiff setup|glob ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "setup":
		setup(os.Args[2:])
	case "glob":
		globs(os.Args[2:], false)
	case "contents":
		globs(os.Args[2:], true)
	default:
		fmt.Fprintln(os.Stderr, "usage: hashfilesdiff setup|glob ...")
		os.Exit(2)
	}
}

type testCase struct {
	ID       int      `json:"id"`
	Patterns []string `json:"patterns"`
}

func setup(args []string) {
	fs := flag.NewFlagSet("setup", flag.ExitOnError)
	out := fs.String("out", ".", "where to write the tree and the cases")
	n := fs.Int("n", 400, "random cases, after one per pattern")
	seed := fs.Uint64("seed", 1, "random seed")
	fs.Parse(args)

	tree := filepath.Join(*out, "tree")
	for i, f := range files {
		p := filepath.Join(tree, f)
		must(os.MkdirAll(filepath.Dir(p), 0o755))
		must(os.WriteFile(p, []byte(fmt.Sprintf("file %d: %s\n", i, f)), 0o644))
	}
	must(os.MkdirAll(filepath.Join(tree, "emptydir"), 0o755))
	for name, target := range symlinks {
		must(os.Symlink(target, filepath.Join(tree, name)))
	}

	var cases []testCase
	for _, p := range pool {
		cases = append(cases, testCase{ID: len(cases), Patterns: []string{p}})
	}
	r := rand.New(rand.NewPCG(*seed, 0))
	for range *n {
		var ps []string
		for j := range 1 + r.IntN(4) {
			p := pool[r.IntN(len(pool))]
			if j > 0 && r.IntN(2) == 0 {
				p = "!" + p
			}
			ps = append(ps, p)
		}
		cases = append(cases, testCase{ID: len(cases), Patterns: ps})
	}
	raw, err := json.MarshalIndent(cases, "", " ")
	must(err)
	must(os.WriteFile(filepath.Join(*out, "cases.json"), raw, 0o644))
}

// globs lists each glob in the plan, or with contents, everything in each directory of the plan as
// the runner asks for it: directory(path: D).glob("**").
func globs(args []string, contents bool) {
	fs := flag.NewFlagSet("glob", flag.ExitOnError)
	tree := fs.String("tree", "", "the tree to glob")
	plan := fs.String("plan", "", "a JSON array of the globs to ask for")
	fs.Parse(args)

	var want []string
	raw, err := os.ReadFile(*plan)
	must(err)
	must(json.Unmarshal(raw, &want))

	ctx := context.Background()
	c, err := dagger.Connect(ctx)
	must(err)
	defer c.Close()
	dir := c.Host().Directory(*tree)
	got := map[string][]string{}
	for _, g := range want {
		var paths []string
		var err error
		if contents {
			paths, err = dir.Directory(g).Glob(ctx, "**")
		} else {
			paths, err = dir.Glob(ctx, g)
		}
		if err != nil {
			// The runner sends the same glob; an error there fails hashFiles().
			got[g] = []string{"ERROR: " + strings.ReplaceAll(err.Error(), "\n", " ")}
			continue
		}
		got[g] = append([]string{}, paths...)
		// What is a directory once symbolic links are followed: the runner's hash step skips it,
		// as GitHub's script does, and the harness needs to know which those are.
		for _, p := range paths {
			full := p
			if contents {
				full = g + p
			}
			if fi, err := os.Stat(filepath.Join(*tree, full)); err == nil && fi.IsDir() && !strings.HasSuffix(p, "/") {
				got[followedKey] = append(got[followedKey], full)
			}
		}
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	must(enc.Encode(got))
}

// followedKey holds, in glob's output, the listed names that are directories once symbolic links
// are followed (a link to a directory).
const followedKey = "//followed"

func must(err error) {
	if err != nil {
		panic(err)
	}
}
