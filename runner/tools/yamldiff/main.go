// Command yamldiff reads YAML files with go.yaml.in/yaml/v3 (the parser nektos/act and Gitea's
// actionslib read workflows and action.yml files with) and writes, one JSON line per file, the tree
// in the shape runner/src/yaml.zig produces: every scalar a string, null for an empty value, `~`
// and the null words, and mappings as ordered [key, value] pairs. runner/tools/yamlcorpus.zig
// compares yaml.zig's tree for the same file. .github/scripts/yaml-diff.sh does all of it.
//
//	go run . <file>... > expected.jsonl
//	go run . -gen 500 -seed 1 -out <dir>     write 500 random YAML files to compare instead
//
// Each line is {"file": name, "tree": ...}, or {"file": name, "error": message} when Go refuses it.
// A tree is null, a string, {"seq": [...]} or {"map": [[key, value], ...]}.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"

	"go.yaml.in/yaml/v3"
)

type line struct {
	File  string `json:"file"`
	Tree  any    `json:"tree,omitempty"`
	Error string `json:"error,omitempty"`
}

func main() {
	gen := flag.Int("gen", 0, "write this many random YAML files to -out, and nothing else")
	seed := flag.Uint64("seed", 1, "random seed for -gen")
	outDir := flag.String("out", ".", "where -gen writes")
	flag.Parse()
	if *gen > 0 {
		generate(*gen, *seed, *outDir)
		return
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	for _, path := range flag.Args() {
		l := line{File: filepath.Base(path)}
		if tree, err := read(path); err != nil {
			l.Error = err.Error()
		} else {
			l.Tree = tree
		}
		if err := enc.Encode(l); err != nil {
			panic(err)
		}
	}
}

func read(path string) (any, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(src, &doc); err != nil {
		return nil, err
	}
	if doc.Kind == 0 { // an empty file
		return nil, nil
	}
	return convert(doc.Content[0])
}

// tree is a JSON-encodable value that is never omitted as empty, so that a null tree still shows.
type tree struct{ v any }

func (t tree) MarshalJSON() ([]byte, error) { return json.Marshal(t.v) }

func convert(n *yaml.Node) (any, error) {
	switch n.Kind {
	case yaml.ScalarNode:
		if n.Tag == "!!null" {
			return tree{nil}, nil
		}
		return n.Value, nil
	case yaml.SequenceNode:
		items := []any{}
		for _, c := range n.Content {
			v, err := convert(c)
			if err != nil {
				return nil, err
			}
			items = append(items, v)
		}
		return map[string]any{"seq": items}, nil
	case yaml.MappingNode:
		pairs := [][2]any{}
		for i := 0; i+1 < len(n.Content); i += 2 {
			k := n.Content[i]
			if k.Kind != yaml.ScalarNode {
				return nil, fmt.Errorf("line %d: a key that is not a scalar", k.Line)
			}
			v, err := convert(n.Content[i+1])
			if err != nil {
				return nil, err
			}
			pairs = append(pairs, [2]any{k.Value, v})
		}
		return map[string]any{"map": pairs}, nil
	case yaml.AliasNode:
		return nil, fmt.Errorf("line %d: an alias", n.Line)
	}
	return nil, fmt.Errorf("line %d: node kind %d", n.Line, n.Kind)
}

// Scalars that are easy to misread: YAML's special words, numbers, and text with the characters
// that mean something in YAML.
var scalars = []string{
	"plain", "two words", "", " ", "null", "Null", "NULL", "~", "true", "False", "yes", "no", "on",
	"1", "-1.5", "0x1F", "1e3", ".inf", "a: b", "a:b", "a #b", "#c", "- x", "[x]", "{x}", "'q'",
	"\"q\"", "it's", "say \"hi\"", "back\\slash", "tab\there", "multi\nline", "trailing\n",
	"line\n\nwith gap\n", "  leading", "trailing  ", "ü & ñ", "${{ inputs.x }}", "*star", "&amp",
	"!bang", "%pct", "@at", "`tick`", "a,b", "key: [1, 2]", "|", ">", "-", "?", "x\n  indented",
}

var styles = []yaml.Style{0, 0, 0, yaml.DoubleQuotedStyle, yaml.SingleQuotedStyle, yaml.LiteralStyle, yaml.FoldedStyle}

func generate(n int, seed uint64, dir string) {
	r := rand.New(rand.NewPCG(seed, 0))
	for i := range n {
		root := randomNode(r, 4)
		if root.Kind != yaml.MappingNode { // an action.yml is a mapping
			root = &yaml.Node{Kind: yaml.MappingNode, Content: []*yaml.Node{scalar(r, "root"), root}}
		}
		out, err := yaml.Marshal(&yaml.Node{Kind: yaml.DocumentNode, Content: []*yaml.Node{root}})
		if err != nil {
			continue
		}
		if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("gen%05d.yml", i)), out, 0o644); err != nil {
			panic(err)
		}
	}
}

func scalar(r *rand.Rand, v string) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Value: v, Style: styles[r.IntN(len(styles))]}
}

func randomNode(r *rand.Rand, depth int) *yaml.Node {
	k := r.IntN(4)
	if depth == 0 || k < 2 {
		return scalar(r, scalars[r.IntN(len(scalars))])
	}
	n := &yaml.Node{}
	if r.IntN(5) == 0 {
		n.Style = yaml.FlowStyle
	}
	count := r.IntN(4)
	if k == 2 {
		n.Kind = yaml.SequenceNode
		for range count {
			n.Content = append(n.Content, randomNode(r, depth-1))
		}
		return n
	}
	n.Kind = yaml.MappingNode
	seen := map[string]bool{}
	for range count {
		key := scalars[r.IntN(len(scalars))]
		if seen[key] || key == "" {
			continue
		}
		seen[key] = true
		k := scalar(r, key)
		if k.Style == yaml.LiteralStyle || k.Style == yaml.FoldedStyle {
			k.Style = 0
		}
		n.Content = append(n.Content, k, randomNode(r, depth-1))
	}
	return n
}
