package main

// Random YAML written as text, for what Go's encoder never writes: quoted scalars and flow
// collections over several lines (with empty lines, escaped line breaks, comments and odd
// indentation), `[a: b]` pairs, and explicit keys (`? key` then `: value`, `{? k: v}`). One in five
// files then has a character inserted, deleted or doubled, so that some are not YAML at all:
// yaml.zig must refuse whatever Go refuses.

import (
	"math/rand/v2"
	"strings"
)

type textGen struct {
	r *rand.Rand
}

// Plain scalars that are safe in block and flow context alike, the null words included.
var words = []string{
	"a", "b", "x y", "null", "Null", "~", "1", "-1", "true", "-x", "a:b", "http://x:80/p",
	"été", "${{ inputs.x }}", "k#1", "it's", "a\"b", "x  y",
}

// Pieces of a quoted scalar's text that mean something there.
var quotedPieces = []string{
	"a", "b c", "#", ": ", "- ", "[x]", "{y}", ",", "?", "é", "'", "\"",
}

var doubleEscapes = []string{
	`\n`, `\t`, `\\`, `\"`, `\x41`, `é`, `\U0001F600`, `\0`, `\ `, `\/`, `\_`, `\N`, `\e`, `\q`,
}

func (g *textGen) chance(n int) bool { return g.r.IntN(n) == 0 }

func (g *textGen) pick(s []string) string { return s[g.r.IntN(len(s))] }

func (g *textGen) spaces(n int) string { return strings.Repeat(" ", n) }

// lineBreak is what may stand between two parts of a quoted scalar or two tokens of a flow
// collection: nothing special, white space, line breaks with any indentation (at times too little,
// or tabs), empty lines.
func (g *textGen) lineBreak(indent int) string {
	var b strings.Builder
	if g.chance(3) {
		b.WriteString(g.spaces(g.r.IntN(3)))
	}
	for range 1 + g.r.IntN(3) {
		if g.chance(3) && b.Len() > 0 {
			b.WriteString(g.spaces(g.r.IntN(3))) // an empty line, or a blank one
		}
		b.WriteString("\n")
	}
	switch {
	case g.chance(8):
		b.WriteString("\t")
	case g.chance(6):
		b.WriteString(g.spaces(g.r.IntN(indent + 1))) // as deep as the parent, or less
	default:
		b.WriteString(g.spaces(indent + 1 + g.r.IntN(4)))
	}
	return b.String()
}

func (g *textGen) quoted(indent int) string {
	double := g.chance(2)
	var b strings.Builder
	q := "'"
	if double {
		q = `"`
	}
	b.WriteString(q)
	for range g.r.IntN(6) {
		switch k := g.r.IntN(10); {
		case k < 4:
			p := g.pick(quotedPieces)
			if p == q {
				if double {
					p = `\"`
				} else {
					p = "''"
				}
			}
			if double && p == `"` {
				p = `\"`
			}
			b.WriteString(p)
		case k < 5:
			b.WriteString(g.spaces(1 + g.r.IntN(2)))
		case k < 8:
			if double && g.chance(3) {
				b.WriteString(`\`) // an escaped line break
			}
			b.WriteString(g.lineBreak(indent))
		default:
			if double {
				b.WriteString(g.pick(doubleEscapes))
			} else {
				b.WriteString("''")
			}
		}
	}
	if !g.chance(40) { // at times never closed
		b.WriteString(q)
	}
	return b.String()
}

// plainFlow is a plain scalar inside a flow collection, at times over several lines.
func (g *textGen) plainFlow(indent int) string {
	s := g.pick(words)
	if g.chance(4) {
		s += g.lineBreak(indent) + g.pick(words)
	}
	return s
}

// sep is what goes between two tokens of a flow collection.
func (g *textGen) sep(indent int) string {
	switch g.r.IntN(8) {
	case 0, 1, 2:
		return " "
	case 3:
		return ""
	case 4:
		return " # c" + g.lineBreak(indent)
	default:
		return g.lineBreak(indent)
	}
}

// colon is a `:` and what follows it in flow: a blank, as a plain key needs, and at times nothing.
func (g *textGen) colon(indent int) string {
	switch g.r.IntN(6) {
	case 0:
		return ":"
	case 1:
		return ":" + g.lineBreak(indent)
	default:
		return ": " + g.sep(indent)
	}
}

func (g *textGen) flowNode(indent, depth int) string {
	switch k := g.r.IntN(6); {
	case depth > 0 && k == 0:
		return g.flow(indent, depth-1)
	case k < 3:
		return g.plainFlow(indent)
	default:
		return g.quoted(indent)
	}
}

func (g *textGen) flowKey(indent int) string {
	if g.chance(3) {
		return g.quoted(indent)
	}
	return g.pick(words)
}

func (g *textGen) flow(indent, depth int) string {
	seq := g.chance(2)
	var b strings.Builder
	if seq {
		b.WriteString("[")
	} else {
		b.WriteString("{")
	}
	n := g.r.IntN(4)
	for i := range n {
		b.WriteString(g.sep(indent))
		switch k := g.r.IntN(6); {
		case k == 0: // an explicit key
			b.WriteString("?" + g.sep(indent) + g.flowKey(indent))
			if g.chance(2) {
				b.WriteString(g.sep(indent) + g.colon(indent) + g.flowNode(indent, depth))
			}
		case k == 1 && !seq: // a key with no value
			b.WriteString(g.flowKey(indent))
		case k < 4 || !seq: // `key: value`, a one-entry mapping in a sequence
			b.WriteString(g.flowKey(indent) + g.colon(indent) + g.flowNode(indent, depth))
		default:
			b.WriteString(g.flowNode(indent, depth))
		}
		b.WriteString(g.sep(indent))
		if i < n-1 || g.chance(4) {
			b.WriteString(",")
		}
	}
	b.WriteString(g.sep(indent))
	if seq {
		b.WriteString("]")
	} else {
		b.WriteString("}")
	}
	return b.String()
}

// inline is a value on the line of its key or dash: a scalar, quoted or not, or a flow collection.
func (g *textGen) inline(indent, depth int) string {
	switch g.r.IntN(5) {
	case 0, 1:
		return g.flow(indent, depth)
	case 2, 3:
		return g.quoted(indent)
	default:
		return g.pick(words)
	}
}

// block writes a node at `indent` after a key or dash: on the same line, or on the lines below.
func (g *textGen) block(b *strings.Builder, indent, depth int) {
	if depth == 0 || g.chance(2) {
		b.WriteString(" " + g.inline(indent, depth))
		if g.chance(5) {
			b.WriteString(" # comment")
		}
		b.WriteString("\n")
		return
	}
	b.WriteString("\n")
	if g.chance(3) {
		g.sequence(b, indent+2, depth-1)
	} else {
		g.mapping(b, indent+2, depth-1)
	}
}

func (g *textGen) sequence(b *strings.Builder, indent, depth int) {
	for range 1 + g.r.IntN(3) {
		b.WriteString(g.spaces(indent) + "-")
		g.block(b, indent, depth)
	}
}

func (g *textGen) mapping(b *strings.Builder, indent, depth int) {
	seen := map[string]bool{}
	for range 1 + g.r.IntN(4) {
		key := g.pick(words)
		if seen[key] {
			continue
		}
		seen[key] = true
		b.WriteString(g.spaces(indent))
		if g.chance(3) { // an explicit key, and at times no value
			if g.chance(4) {
				b.WriteString("? " + g.quoted(indent) + "\n") // a key whose text may repeat another's
			} else {
				b.WriteString("? " + key + "\n")
			}
			if g.chance(4) {
				continue
			}
			b.WriteString(g.spaces(indent) + ":")
		} else {
			b.WriteString(key + ":")
		}
		g.block(b, indent, depth)
	}
}

// mutate inserts, deletes or doubles a character, at times breaking the YAML.
func (g *textGen) mutate(s string) string {
	if len(s) == 0 {
		return s
	}
	i := g.r.IntN(len(s))
	switch g.r.IntN(3) {
	case 0:
		return s[:i] + string(",:[]{}\"'#?- \n\t\\"[g.r.IntN(15)]) + s[i:]
	case 1:
		return s[:i] + s[i+1:]
	default:
		return s[:i] + s[i:i+1] + s[i:]
	}
}

func generateText(r *rand.Rand) []byte {
	g := &textGen{r: r}
	var b strings.Builder
	g.mapping(&b, 0, 3)
	s := b.String()
	if g.chance(5) {
		s = g.mutate(s)
	}
	return []byte(s)
}
