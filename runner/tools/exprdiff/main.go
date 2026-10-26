// Command exprdiff writes random GitHub Actions expressions, with the answers Gitea's evaluator
// (gitea.dev/actionslib, derived from nektos/act) gives for them, as a test file in the format of
// GitHub's own expression cases (actions/languageservices, expressions/testdata). The runner's
// harness, runner/tools/exprcorpus.zig, then runs them through runner/src/expr.zig and prints every
// disagreement. .github/scripts/expr-diff.sh does all of it.
//
//	go run . -n 5000 -seed 1 -out <dir>/generated.json
//
// actionslib is not GitHub: a disagreement says only that one of the two is wrong. GitHub's own
// cases (expr-conformance.sh) are the reference; this finds what they do not cover.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"reflect"
	"strings"

	"gitea.dev/actionslib/pkg/exprparser"
)

// The data expressions read. matrix and inputs take any JSON; env only strings. Every object's keys
// are in byte order: actionslib holds them in Go maps, which list keys sorted, where GitHub (and the
// runner) keep the order they are written in.
const contextsJSON = `{
 "env": {
  "CASE": "MiXeD",
  "EMPTY": "",
  "NAME": "World",
  "NUM": "42"
 },
 "inputs": {
  "flag": "true",
  "list": [
   "p",
   "q"
  ],
  "x": "1",
  "y": 2
 },
 "matrix": {
  "arr": [
   "a",
   "B",
   2,
   true,
   null,
   [
    "x"
   ],
   {
    "k": "v"
   }
  ],
  "brackets": "a[b]c",
  "empty": "",
  "f": false,
  "fmt": "{0}-{1}",
  "hexstr": "0x1F",
  "neg": -1.5,
  "nul": null,
  "num": 3,
  "nums": [
   3,
   1,
   2
  ],
  "numstr": " 12 ",
  "obj": {
   "K2": 2,
   "k": "v",
   "list": [
    1,
    2
   ],
   "nested": {
    "deep": "yes"
   }
  },
  "objs": [
   {
    "n": 1,
    "name": "bug"
   },
   {
    "n": 2,
    "name": "Docs"
   },
   {
    "other": 3
   }
  ],
  "quote": "it's",
  "str": "Hello",
  "t": true,
  "unicode": "Grüße",
  "upper": "HELLO",
  "zero": 0
 }
}`

var (
	// No `0b11`: GitHub reads number literals with JavaScript's Number(), which takes binary;
	// actionslib does not.
	literals = []string{
		"null", "true", "false", "TRUE", "0", "1", "-1", "1.5", ".5", "-0", "0x10", "0o7",
		"1e3", "1E-2", "NaN", "Infinity", "-Infinity", "''", "'a'", "'A'", "'abc'", "'ABC'", "'1'",
		"' 1 '", "'0x10'", "'true'", "'null'", "'ü'", "'Ü'", "'['", "'it''s'", "'{0}'", "'{{0}}'",
		"' '", "'1e3'", "'-1'", "'NaN'", "'Infinity'", "'[1,2]'", "'{\"a\":1}'",
	}
	refs = []string{
		"matrix.str", "matrix.upper", "matrix.empty", "matrix.num", "matrix.neg", "matrix.zero",
		"matrix.numstr", "matrix.hexstr", "matrix.t", "matrix.f", "matrix.nul", "matrix.arr",
		"matrix.nums", "matrix.obj", "matrix.objs", "matrix.unicode", "matrix.brackets",
		"matrix.quote", "matrix.fmt", "matrix.missing", "matrix.obj.k", "matrix.obj.K",
		"matrix.obj.k2", "matrix.obj.nested.deep", "matrix.obj.list", "matrix.arr[0]",
		"matrix.arr[1]", "matrix.arr[5][0]", "matrix.arr[6].k", "matrix.arr[9]", "matrix.arr.*",
		"matrix.objs.*.name", "matrix.objs[*].n", "matrix.objs.*", "matrix.obj.*", "matrix['str']",
		"matrix['STR']", "matrix.nums[matrix.zero]", "matrix.arr['1']", "matrix.str[0]",
		"inputs.x", "inputs.y", "inputs.list", "inputs.flag", "env.NAME", "env.name", "env.EMPTY",
		"env.NUM", "env.CASE", "env.MISSING", "matrix", "env",
	}
	binops = []string{"==", "!=", "<", "<=", ">", ">=", "&&", "||"}
)

type gen struct{ r *rand.Rand }

func (g gen) pick(xs []string) string { return xs[g.r.IntN(len(xs))] }

// expr returns a random expression at most `depth` levels deep.
func (g gen) expr(depth int) string {
	if depth <= 0 || g.r.IntN(4) == 0 {
		if g.r.IntN(2) == 0 {
			return g.pick(literals)
		}
		return g.pick(refs)
	}
	d := depth - 1
	switch g.r.IntN(13) {
	case 0, 1, 2:
		return g.expr(d) + " " + g.pick(binops) + " " + g.expr(d)
	case 3:
		return "!" + g.expr(d)
	case 4:
		return "(" + g.expr(d) + ")"
	case 5:
		return fmt.Sprintf("contains(%s, %s)", g.expr(d), g.expr(d))
	case 6:
		f := []string{"startsWith", "endsWith"}[g.r.IntN(2)]
		return fmt.Sprintf("%s(%s, %s)", f, g.expr(d), g.expr(d))
	case 7:
		fmts := []string{"'{0}'", "'{0} {1}'", "'{1}{0}'", "'{{{0}}}'", "'x{0}y'", "matrix.fmt"}
		return fmt.Sprintf("format(%s, %s, %s)", g.pick(fmts), g.expr(d), g.expr(d))
	case 8:
		if g.r.IntN(2) == 0 {
			return fmt.Sprintf("join(%s)", g.expr(d))
		}
		return fmt.Sprintf("join(%s, %s)", g.expr(d), g.expr(d))
	case 9:
		return fmt.Sprintf("toJSON(%s)", g.jsonable(d))
	case 10:
		return fmt.Sprintf("fromJSON(%s)", g.pick([]string{
			"'[1,\"a\",null,true]'", "'{\"a\":{\"b\":2}}'", "'1.50'", "'\"s\"'", "'null'", "'true'",
			"toJSON(" + g.jsonable(d) + ")", "'[]'", "'{}'", "' 7 '",
		}))
	case 11:
		return fmt.Sprintf("case(%s, %s, %s)", g.predicate(d), g.expr(d), g.expr(d))
	default:
		return g.expr(d) + "[" + g.expr(d) + "]"
	}
}

// Where actionslib differs from GitHub (actions/languageservices, expressions/src), the generator
// steers clear, so that what is left to report is news:
//
//   - case() takes any predicate; GitHub's case.ts refuses one that is not a boolean. So predicates
//     here are always booleans.
//   - toJSON(Infinity) is "Infinity" and toJSON(NaN) "NaN"; GitHub's are "null" (JSON.stringify).
//     So toJSON's argument never names either.

// predicate returns an expression that is always a boolean.
func (g gen) predicate(depth int) string {
	switch g.r.IntN(4) {
	case 0:
		return g.pick([]string{"true", "false", "matrix.t", "matrix.f"})
	case 1:
		return "!(" + g.expr(depth) + ")"
	case 2:
		return fmt.Sprintf("contains(%s, %s)", g.expr(depth), g.expr(depth))
	default: // parenthesised: `a || b == c` is `a || (b == c)`, which need not be a boolean
		return "(" + g.expr(depth) + ") " + g.pick(binops[:6]) + " (" + g.expr(depth) + ")"
	}
}

// jsonable returns an expression whose text names neither Infinity nor NaN.
func (g gen) jsonable(depth int) string {
	for {
		if e := g.expr(depth); !strings.Contains(e, "Infinity") && !strings.Contains(e, "NaN") {
			return e
		}
	}
}

type expected struct {
	Kind  string `json:"kind"`
	Value any    `json:"value,omitempty"`
}

type corpusCase struct {
	Expr     string          `json:"expr"`
	Contexts json.RawMessage `json:"contexts"`
	Result   *expected       `json:"result,omitempty"`
	Err      *expected       `json:"err,omitempty"`
}

func main() {
	n := flag.Int("n", 5000, "how many expressions")
	seed := flag.Uint64("seed", 1, "random seed")
	depth := flag.Int("depth", 4, "how deeply expressions nest")
	out := flag.String("out", "generated.json", "the test file to write")
	flag.Parse()

	var ctx struct {
		Matrix map[string]any    `json:"matrix"`
		Inputs map[string]any    `json:"inputs"`
		Env    map[string]string `json:"env"`
	}
	if err := json.Unmarshal([]byte(contextsJSON), &ctx); err != nil {
		panic(err)
	}
	env := &exprparser.EvaluationEnvironment{Matrix: ctx.Matrix, Inputs: ctx.Inputs, Env: ctx.Env}

	g := gen{rand.New(rand.NewPCG(*seed, 0))}
	seen := map[string]bool{}
	var cases []corpusCase
	for len(cases) < *n {
		e := g.expr(*depth)
		if seen[e] {
			continue
		}
		seen[e] = true
		c := corpusCase{Expr: e, Contexts: json.RawMessage(contextsJSON)}
		v, err := exprparser.NewInterpeter(env, exprparser.Config{}).Evaluate(e, exprparser.DefaultStatusCheckNone)
		if err != nil {
			var parse *exprparser.ExprError
			kind := "evaluation"
			if errors.As(err, &parse) {
				kind = "parsing"
			}
			c.Err = &expected{Kind: kind, Value: err.Error()}
		} else {
			r, ok := result(v)
			if !ok {
				continue // a value JSON cannot carry (NaN inside an array): skip it
			}
			c.Result = r
		}
		cases = append(cases, c)
	}

	f, err := json.MarshalIndent(map[string][]corpusCase{"generated": cases}, "", " ")
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(*out, f, 0o644); err != nil {
		panic(err)
	}
}

// result is v as the corpus writes a result: its kind, and a JSON value (numbers that JSON has no
// word for as "NaN", "Infinity" and "-Infinity").
func result(v any) (*expected, bool) {
	rv := reflect.ValueOf(v)
	for rv.IsValid() && (rv.Kind() == reflect.Pointer || rv.Kind() == reflect.Interface) {
		if rv.IsNil() {
			return &expected{Kind: "Null"}, true
		}
		if rv.Kind() == reflect.Pointer && rv.Elem().Kind() == reflect.Struct {
			break // an object (fromJSON's)
		}
		rv = rv.Elem()
	}
	if !rv.IsValid() {
		return &expected{Kind: "Null"}, true
	}
	switch rv.Kind() {
	case reflect.Bool:
		return &expected{Kind: "Boolean", Value: rv.Bool()}, true
	case reflect.Float32, reflect.Float64, reflect.Int, reflect.Int64, reflect.Int32:
		x := rv.Convert(reflect.TypeFor[float64]()).Float()
		switch {
		case math.IsNaN(x):
			return &expected{Kind: "Number", Value: "NaN"}, true
		case math.IsInf(x, 1):
			return &expected{Kind: "Number", Value: "Infinity"}, true
		case math.IsInf(x, -1):
			return &expected{Kind: "Number", Value: "-Infinity"}, true
		}
		return &expected{Kind: "Number", Value: x}, true
	case reflect.String:
		return &expected{Kind: "String", Value: rv.String()}, true
	}
	kind := "Object"
	if rv.Kind() == reflect.Slice || rv.Kind() == reflect.Array {
		kind = "Array"
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, false
	}
	var decoded any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, false
	}
	if strings.HasPrefix(string(raw), "null") {
		decoded = []any{}
	}
	return &expected{Kind: kind, Value: decoded}, true
}
