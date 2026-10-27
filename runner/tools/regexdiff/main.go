// Command regexdiff writes the cases .github/scripts/regex-diff.sh compares the runner's regular
// expressions (runner/src/regex.zig) with .NET's on: problem matchers' patterns as GitHub's
// runner compiles them (reference/, .NET with RegexOptions.CultureInvariant | ECMAScript).
//
//	go run . -out <cases.json> [-matchers <dir>] [-n 2000] [-seed 1]
//
// Cases are the real patterns (every "regexp" in the problem matcher files in -matchers; the
// script fetches those matchers.txt lists) and random ones over
// what .NET's ECMAScript mode takes, each with inputs: strings the pattern was built to match,
// mutations of them, log-like lines, and text outside ASCII.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"regexp/syntax"
	"sort"
	"strings"
	"unicode/utf8"
)

type testCase struct {
	ID      int      `json:"id"`
	Pattern string   `json:"pattern"`
	Inputs  []string `json:"inputs"`
}

// Lines like the ones problem matchers read.
var logLines = []string{
	"src/main.ts(12,5): error TS2304: Cannot find name 'x'.",
	"  12:5  error  'x' is not defined  no-undef",
	"main.go:10:2: undefined: foo",
	"/home/runner/work/r/r/a.c:3:14: warning: unused variable 'y' [-Wunused-variable]",
	"Error: src/lib.rs:7:9: mismatched types",
	"  File \"app.py\", line 42, in <module>",
	"WARNING: deprecated option --foo (use --bar)",
	"C:\\src\\Program.cs(10,20): error CS1002: ; expected [C:\\src\\app.csproj]",
	"test_thing.py::test_ok PASSED",
	"",
	"   ",
	"ok\tgithub.com/x/y\t0.012s",
	"café: résumé naïve ü 中文 ✓",
	"--- FAIL: TestX (0.00s)",
	"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaab",
}

func main() {
	out := flag.String("out", "cases.json", "where to write the cases")
	matchers := flag.String("matchers", "", "a directory of problem matcher files whose patterns to include")
	n := flag.Int("n", 2000, "random patterns")
	seed := flag.Uint64("seed", 1, "random seed")
	flag.Parse()
	g := &gen{r: rand.New(rand.NewPCG(*seed, 0))}

	var cases []testCase
	if *matchers != "" {
		for _, p := range realPatterns(*matchers) {
			cases = append(cases, testCase{ID: len(cases), Pattern: p, Inputs: g.inputsForReal(p)})
		}
	}
	for range *n {
		g.groups, g.closed = nil, nil
		node := g.node(3)
		samples := []string{}
		for range 3 {
			g.taken = map[int]string{}
			samples = append(samples, node.sample(g))
		}
		cases = append(cases, testCase{ID: len(cases), Pattern: node.text, Inputs: g.inputs(samples)})
	}
	raw, err := json.MarshalIndent(cases, "", " ")
	must(err)
	must(os.WriteFile(*out, raw, 0o644))
}

type gen struct {
	r      *rand.Rand
	groups []string // capture group names ("" when unnamed), in order of opening parenthesis
	closed []bool   // whether each group has closed: only those are referred to
	taken  map[int]string
}

func (g *gen) pick(xs ...string) string { return xs[g.r.IntN(len(xs))] }

// node is a pattern fragment, how to make a string it matches, and whether it can match the
// empty string (then it is not quantified: see quantified).
type node struct {
	text   string
	sample func(g *gen) string
	empty  bool
}

func lit(text, sample string) node {
	return node{text: text, sample: func(*gen) string { return sample }}
}

var plainChars = []string{"a", "b", "c", "x", "Z", "0", "7", "_", " ", ":", ",", "-", "/", "é", "中"}
var metaChars = []string{".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "^", "$", "\\", "/"}

func (g *gen) atom(depth int) node {
	switch g.r.IntN(20) {
	case 0, 1, 2, 3:
		c := plainChars[g.r.IntN(len(plainChars))]
		return lit(c, c)
	case 4:
		m := metaChars[g.r.IntN(len(metaChars))]
		return lit("\\"+m, m)
	case 5:
		return node{text: ".", sample: func(g *gen) string { return g.pick("a", "9", " ", "é", ":") }}
	case 6:
		sh := g.pick(`\d`, `\w`, `\s`, `\D`, `\W`, `\S`)
		samples := map[string][]string{`\d`: {"0", "5"}, `\w`: {"a", "_", "9"}, `\s`: {" ", "\t"}, `\D`: {"a", ":", "é"}, `\W`: {":", " ", "é"}, `\S`: {"a", ":", "é"}}
		return node{text: sh, sample: func(g *gen) string { return g.pick(samples[sh]...) }}
	case 7:
		return g.class()
	case 8:
		esc := g.pick(`\t`, `\x41`, `\u00e9`, `\x2F`, `\n`)
		return lit(esc, map[string]string{`\t`: "\t", `\x41`: "A", `\u00e9`: "é", `\x2F`: "/", `\n`: "\n"}[esc])
	case 9:
		// No `\B`: after a loop it must give back to (` \S*(中\W{2,})\B`), .NET finds no match where
		// a shorter fixed loop (`\W{3}`) matches: its optimizer making the loop atomic, not a rule.
		a := g.pick("^", "$", `\b`)
		n := lit(a, "")
		n.empty = true
		return n
	case 10, 11, 12:
		if depth > 0 {
			return g.group(depth - 1)
		}
		return lit("a", "a")
	case 13:
		if depth > 0 {
			inner := g.node(depth - 1)
			kind := g.pick("(?=", "(?!", "(?<=", "(?<!")
			return node{text: kind + inner.text + ")", sample: func(*gen) string { return "" }, empty: true}
		}
		return lit("b", "b")
	case 14:
		// Only to a group that has closed: a reference from inside the group itself (ECMAScript's
		// self-reference) is where .NET gives answers that cannot be right (a match missing the
		// pattern's own first characters), and no problem matcher does it.
		var done []int
		for i, c := range g.closed {
			if c {
				done = append(done, i)
			}
		}
		if len(done) > 0 {
			i := done[g.r.IntN(len(done))]
			ref := fmt.Sprintf(`\%d`, i+1)
			if g.groups[i] != "" && g.r.IntN(2) == 0 {
				ref = `\k<` + g.groups[i] + `>`
			}
			return node{text: ref, sample: func(g *gen) string { return g.taken[i] }, empty: true}
		}
		return lit("c", "c")
	default:
		w := g.pick("error", "warning", "file", "line", ":", "(", "TS")
		return lit(strings.NewReplacer("(", `\(`).Replace(w), w)
	}
}

func (g *gen) class() node {
	negate := g.r.IntN(4) == 0
	var parts []string
	var members []string
	for range 1 + g.r.IntN(3) {
		switch g.r.IntN(4) {
		case 0:
			parts = append(parts, "a-f")
			members = append(members, "c")
		case 1:
			parts = append(parts, `\d`)
			members = append(members, "4")
		case 2:
			c := g.pick(":", "/", "_", "é", `\]`, `\-`, ".")
			parts = append(parts, c)
			members = append(members, strings.TrimPrefix(c, `\`))
		default:
			parts = append(parts, `\s`)
			members = append(members, " ")
		}
	}
	text := "[" + map[bool]string{true: "^"}[negate] + strings.Join(parts, "") + "]"
	return node{text: text, sample: func(g *gen) string {
		if negate {
			return g.pick("Q", "#", "~")
		}
		return members[g.r.IntN(len(members))]
	}}
}

func (g *gen) group(depth int) node {
	kind := g.r.IntN(4)
	idx := -1
	name := ""
	open := "(?:"
	if kind < 3 {
		idx = len(g.groups)
		if kind == 2 {
			name = fmt.Sprintf("n%d", idx)
			open = "(?<" + name + ">"
		} else {
			open = "("
		}
		g.groups = append(g.groups, name)
		g.closed = append(g.closed, false)
	}
	inner := g.node(depth)
	if idx >= 0 {
		g.closed[idx] = true
	}
	return node{text: open + inner.text + ")", sample: func(g *gen) string {
		s := inner.sample(g)
		if idx >= 0 {
			g.taken[idx] = s
		}
		return s
	}, empty: inner.empty}
}

func (g *gen) quantified(depth int) node {
	a := g.atom(depth)
	// Nothing that can match the empty string is quantified: there (`(\B)+?`, `(?!x){1,3}?`,
	// `\2+?` for a group that took no part) .NET reports matches that leave out the pattern's own
	// first characters, which no other engine would, and no problem matcher does it.
	if g.r.IntN(3) != 0 || a.empty {
		return a
	}
	q, lo, hi := g.pick("*", "+", "?", "{2}", "{1,3}", "{2,}"), 0, 0
	switch q {
	case "*":
		lo, hi = 0, 3
	case "+":
		lo, hi = 1, 3
	case "?":
		lo, hi = 0, 1
	case "{2}":
		lo, hi = 2, 2
	case "{1,3}":
		lo, hi = 1, 3
	default:
		lo, hi = 2, 4
	}
	if g.r.IntN(4) == 0 {
		q += "?"
	}
	return node{text: a.text + q, sample: func(g *gen) string {
		var b strings.Builder
		for range lo + g.r.IntN(hi-lo+1) {
			b.WriteString(a.sample(g))
		}
		return b.String()
	}, empty: lo == 0}
}

func (g *gen) node(depth int) node {
	var alts []node
	for range 1 + map[bool]int{true: g.r.IntN(2)}[g.r.IntN(4) == 0] {
		var seq []node
		for range 1 + g.r.IntN(5) {
			seq = append(seq, g.quantified(depth))
		}
		text := ""
		empty := true
		for _, s := range seq {
			text += s.text
			empty = empty && s.empty
		}
		alts = append(alts, node{text: text, sample: func(g *gen) string {
			var b strings.Builder
			for _, s := range seq {
				b.WriteString(s.sample(g))
			}
			return b.String()
		}, empty: empty})
	}
	if len(alts) == 1 {
		return alts[0]
	}
	return node{text: alts[0].text + "|" + alts[1].text, sample: func(g *gen) string {
		return alts[g.r.IntN(2)].sample(g)
	}, empty: alts[0].empty || alts[1].empty}
}

// realPatterns: every distinct "regexp" in the JSON files in dir, in sorted order.
func realPatterns(dir string) []string {
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	must(err)
	seen := map[string]bool{}
	var out []string
	var walk func(v any)
	walk = func(v any) {
		switch x := v.(type) {
		case map[string]any:
			for k, e := range x {
				if s, ok := e.(string); ok && k == "regexp" {
					if !seen[s] {
						seen[s] = true
						out = append(out, s)
					}
				} else {
					walk(e)
				}
			}
		case []any:
			for _, e := range x {
				walk(e)
			}
		}
	}
	for _, f := range files {
		raw, err := os.ReadFile(f)
		must(err)
		var v any
		if json.Unmarshal(raw, &v) != nil {
			continue // not JSON (a page instead of the file): skipped
		}
		walk(v)
	}
	sort.Strings(out)
	return out
}

// inputs: the samples, mutations of them, framed by other text, and log lines.
func (g *gen) inputs(samples []string) []string {
	var out []string
	for _, s := range samples {
		out = append(out, s, "  "+s+" tail", g.mutate(s))
	}
	out = append(out, logLines[g.r.IntN(len(logLines))], logLines[g.r.IntN(len(logLines))])
	return out
}

func (g *gen) mutate(s string) string {
	runes := []rune(s)
	if len(runes) == 0 {
		return "x"
	}
	i := g.r.IntN(len(runes))
	switch g.r.IntN(3) {
	case 0:
		return string(runes[:i]) + string(runes[i+1:])
	case 1:
		return string(runes[:i]) + g.pick("a", "é", " ", ":", "Z") + string(runes[i:])
	default:
		return strings.ToUpper(s)
	}
}

// inputsForReal: strings sampled from the pattern where Go's parser reads it, and log lines.
func (g *gen) inputsForReal(p string) []string {
	var samples []string
	if re, err := syntax.Parse(p, syntax.Perl); err == nil {
		for range 4 {
			samples = append(samples, g.sampleSyntax(re.Simplify()))
		}
	}
	out := g.inputs(samples)
	return append(out, logLines...)
}

func (g *gen) sampleSyntax(re *syntax.Regexp) string {
	switch re.Op {
	case syntax.OpLiteral:
		return string(re.Rune)
	case syntax.OpCharClass:
		if len(re.Rune) == 0 {
			return ""
		}
		k := 2 * g.r.IntN(len(re.Rune)/2)
		lo, hi := re.Rune[k], re.Rune[k+1]
		if hi-lo > 64 {
			hi = lo + 64
		}
		r := lo + rune(g.r.IntN(int(hi-lo+1)))
		if !utf8.ValidRune(r) {
			r = 'a'
		}
		return string(r)
	case syntax.OpAnyCharNotNL, syntax.OpAnyChar:
		return g.pick("a", "1", " ", "/")
	case syntax.OpCapture:
		return g.sampleSyntax(re.Sub[0])
	case syntax.OpConcat:
		var b strings.Builder
		for _, s := range re.Sub {
			b.WriteString(g.sampleSyntax(s))
		}
		return b.String()
	case syntax.OpAlternate:
		return g.sampleSyntax(re.Sub[g.r.IntN(len(re.Sub))])
	case syntax.OpStar, syntax.OpPlus, syntax.OpQuest, syntax.OpRepeat:
		lo, hi := re.Min, re.Max
		switch re.Op {
		case syntax.OpStar:
			lo, hi = 0, 3
		case syntax.OpPlus:
			lo, hi = 1, 3
		case syntax.OpQuest:
			lo, hi = 0, 1
		}
		if hi < 0 || hi > lo+3 {
			hi = lo + 3
		}
		var b strings.Builder
		for range lo + g.r.IntN(hi-lo+1) {
			b.WriteString(g.sampleSyntax(re.Sub[0]))
		}
		return b.String()
	}
	return ""
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
