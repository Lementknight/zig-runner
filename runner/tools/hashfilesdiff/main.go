// Command hashfilesdiff writes the test tree and the cases .github/scripts/hashfiles-diff.sh
// compares the runner's hashFiles() (runner/src/glob.zig) with GitHub's on.
//
//	go run . -out <dir> [-n 400] [-seed 1]     a tree in <dir>/tree, cases in <dir>/cases.json
//
// GitHub's side is reference.mjs here (actions/runner's hashFiles script on @actions/glob); the
// runner's is runner/tools/hashfilescorpus.zig. Both read the same tree, so they see the same
// directory order and the hashes themselves can be compared, not just the files.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
)

// The test tree: the files a repository has (lockfiles at several depths, vendored and installed
// dependencies, dotfiles), and names that mean something to a glob.
var files = []string{
	"package.json", "package-lock.json", "sub/package-lock.json", "sub/deeper/package-lock.json",
	"node_modules/x/package-lock.json", "node_modules/.bin/tool", ".hidden/file.json", ".dotfile",
	".github/workflows/ci.yml", "a b/space file.txt", "UPPER.TXT", "lower.txt", "dir.json/inner.txt",
	"deep/a/b/c/file.go", "go.sum", "go.mod", "src/main.go", "src/main_test.go", "src/util/util.go",
	"vendor/x/x.go", "brackets[1].txt", "brackets1.txt", "star*.txt", "q?.txt", "#hash.txt",
	"!bang.txt", "-dash.txt", "café.txt", "src/.env", "deep/.cache/x.go", "a.txt", "a/b.txt",
	"[x]/y.txt", "~/tilde.txt",
}

// Links: to a file, to a directory, to nowhere, and a cycle (followed with --follow-symbolic-links).
var symlinks = map[string]string{
	"link.go": "src/main.go", "linkdir": "src", "broken": "nowhere", "src/util/loop": "..",
}

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
	"src/*", "deep/*", "deep/a/*", "sub/*", "*/*", "node_modules/*", "[[]x]/*", "\\[x]/y.txt",
	"[!a-z]*", "[[:upper:]]*", "a*", "a/", "q?.txt", "~/tilde.txt", "!!src/*.go", "!", "linkdir/**",
}

type testCase struct {
	ID       int      `json:"id"`
	Patterns []string `json:"patterns"`
}

func main() {
	out := flag.String("out", ".", "where to write the tree and the cases")
	n := flag.Int("n", 400, "random cases, after one per pattern")
	seed := flag.Uint64("seed", 1, "random seed")
	flag.Parse()

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
		if r.IntN(5) == 0 {
			ps = append(ps, "--follow-symbolic-links")
		}
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

func must(err error) {
	if err != nil {
		panic(err)
	}
}
