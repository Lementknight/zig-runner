// Command hpackdiff writes the HPACK header blocks .github/scripts/hpack-diff.sh decodes with the
// runner's decoder (runner/src/hpack.zig), each with the header list it must give.
//
//	go run . -out <cases.jsonl> [-n 2000] [-seed 1]
//
// A case is one connection: random header lists encoded with golang.org/x/net/http2/hpack's
// Encoder, block after block, so the dynamic table carries over, with table size changes between
// blocks and entries large enough to evict others. Strings are Huffman-coded where that is shorter
// (Go decides), so text comes out Huffman-coded and random bytes literal. The headers a block must
// give are the ones encoded, not what Go's decoder makes of them: it refuses the two size updates
// in a row its own encoder writes after the table shrinks and grows again, which RFC 7541 §4.2
// allows.
//
// One case in four ends with a broken block: the next encoded block truncated, with a byte
// changed, added or dropped, or random bytes. What it must give is Go's Decoder's answer, a header
// list or an error, after the same blocks before it, unless it starts with two size updates and Go
// refuses it. runner/tools/hpackcorpus.zig compares.
//
// Each line is {"id": n, "blocks": [{"block": hex, "headers": [[name, value], ...]}, ...]}, names
// and values in hex; a block Go refuses has "headers": null and an "error", and a broken block has
// "broken": true.
package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"flag"
	"math/rand/v2"
	"os"

	"golang.org/x/net/http2/hpack"
)

// The headers the Dagger engine sends its client (engine.zig), and others gRPC and HTTP/2 use.
var pool = [][2]string{
	{":method", "POST"}, {":method", "GET"}, {":scheme", "http"}, {":scheme", "https"},
	{":path", "/grpc.health.v1.Health/Check"}, {":path", "/moby.filesync.v1.FileSync/DiffCopy"},
	{":path", "/moby.filesync.v1.Auth/Credentials"}, {":path", "/"}, {":authority", "localhost"},
	{":authority", "dagger"}, {"content-type", "application/grpc"}, {"user-agent", "grpc-go/1.72.0"},
	{"te", "trailers"}, {"grpc-timeout", "4999872u"}, {"grpc-accept-encoding", "identity,deflate,gzip"},
	{"x-docker-expose-session-uuid", "8u6m0zv6x5d1rq5gq3x9m2c3a"}, {"x-docker-expose-session-name", "dagger"},
	{"x-docker-expose-session-sharedkey", ""}, {"dir-name", "/host/workspace"}, {"followpaths", "src"},
	{"override-excludes", "true"}, {"cache-control", "no-cache"}, {"accept-encoding", "gzip, deflate"},
	{"grpc-status", "0"}, {"grpc-message", ""}, {"", ""}, {"", "empty name"}, {"empty-value", ""},
}

type block struct {
	Block   string      `json:"block"`
	Headers [][2]string `json:"headers"`
	Error   string      `json:"error,omitempty"`
	Broken  bool        `json:"broken,omitempty"`
}

type testCase struct {
	ID     int     `json:"id"`
	Blocks []block `json:"blocks"`
}

func main() {
	out := flag.String("out", "cases.jsonl", "where to write the cases")
	n := flag.Int("n", 2000, "connections")
	seed := flag.Uint64("seed", 1, "random seed")
	flag.Parse()

	f, err := os.Create(*out)
	must(err)
	w := bufio.NewWriter(f)
	enc := json.NewEncoder(w)
	r := rand.New(rand.NewPCG(*seed, 0))
	for id := range *n {
		must(enc.Encode(connection(r, id)))
	}
	must(w.Flush())
	must(f.Close())
}

func connection(r *rand.Rand, id int) testCase {
	var buf bytes.Buffer
	e := hpack.NewEncoder(&buf)
	d := hpack.NewDecoder(4096, nil)
	c := testCase{ID: id}
	var seen []hpack.HeaderField
	inStep := true
	for range 1 + r.IntN(8) {
		tableSize(r, e)
		buf.Reset()
		fields := headers(r, seen)
		for _, f := range fields {
			must(e.WriteField(f))
		}
		seen = append(seen, fields...)
		b := block{Block: hex.EncodeToString(buf.Bytes()), Headers: [][2]string{}}
		for _, f := range fields {
			b.Headers = append(b.Headers, pair(f))
		}
		c.Blocks = append(c.Blocks, b)
		// Go's decoder, kept in step for the broken block, is out of step once it refuses one.
		if _, err := d.DecodeFull(bytes.Clone(buf.Bytes())); err != nil {
			inStep = false
		}
	}
	if !inStep || r.IntN(4) != 0 {
		return c
	}
	tableSize(r, e)
	buf.Reset()
	for _, f := range headers(r, seen) {
		must(e.WriteField(f))
	}
	raw := broken(r, buf.Bytes())
	b := block{Block: hex.EncodeToString(raw), Broken: true}
	if fields, err := d.DecodeFull(raw); err != nil {
		if sizeUpdates(raw) > 1 {
			return c // possibly Go's refusal of a second size update, which is not to follow
		}
		b.Error = err.Error()
	} else {
		b.Headers = [][2]string{}
		for _, f := range fields {
			b.Headers = append(b.Headers, pair(f))
		}
	}
	c.Blocks = append(c.Blocks, b)
	return c
}

// tableSize changes the encoder's table size, sometimes: up to the 4096 bytes HTTP/2 starts with,
// which is all hpack.zig takes (the engine never asks for more), several times between two blocks
// at times, so the encoder writes the smallest size and then the last.
func tableSize(r *rand.Rand, e *hpack.Encoder) {
	for r.IntN(4) == 0 {
		v := uint32(r.IntN(4097))
		if r.IntN(3) == 0 {
			v = uint32(r.IntN(300))
		}
		if r.IntN(3) == 0 {
			e.SetMaxDynamicTableSizeLimit(v)
		} else {
			e.SetMaxDynamicTableSize(v)
		}
	}
}

// headers returns a random header list: from the pool, repeated from earlier blocks (indexed from
// the dynamic table), a known name with a new value, or new names and values, some sensitive.
func headers(r *rand.Rand, seen []hpack.HeaderField) []hpack.HeaderField {
	var fs []hpack.HeaderField
	for range r.IntN(12) {
		var f hpack.HeaderField
		switch k := r.IntN(10); {
		case k < 3:
			p := pool[r.IntN(len(pool))]
			f = hpack.HeaderField{Name: p[0], Value: p[1]}
		case k < 6 && len(seen) > 0:
			f = seen[len(seen)-1-r.IntN(min(len(seen), 20))]
		case k < 8:
			f = hpack.HeaderField{Name: pool[r.IntN(len(pool))][0], Value: str(r)}
			if len(seen) > 0 && r.IntN(2) == 0 {
				f.Name = seen[r.IntN(len(seen))].Name
			}
		default:
			f = hpack.HeaderField{Name: str(r), Value: str(r)}
		}
		f.Sensitive = r.IntN(10) == 0
		fs = append(fs, f)
	}
	return fs
}

// str returns a random string: empty, a word, text, any bytes, or long enough to fill or overflow
// the table (Go does not index a field larger than the table, so it is sent as a plain literal).
func str(r *rand.Rand) string {
	const text = "abcdefghijklmnopqrstuvwxyz0123456789-_./:;= ,ABCXYZ\"%~"
	var n int
	switch k := r.IntN(10); {
	case k == 0:
		return ""
	case k < 6:
		n = 1 + r.IntN(16)
	case k < 9:
		n = r.IntN(300)
	default:
		n = r.IntN(5000)
	}
	b := make([]byte, n)
	binary := r.IntN(3) == 0
	for i := range b {
		if binary {
			b[i] = byte(r.IntN(256))
		} else {
			b[i] = text[r.IntN(len(text))]
		}
	}
	return string(b)
}

// broken returns b damaged: truncated, a byte changed, added or dropped, or random bytes instead.
func broken(r *rand.Rand, b []byte) []byte {
	b = bytes.Clone(b)
	if len(b) == 0 || r.IntN(6) == 0 {
		b = make([]byte, 1+r.IntN(40))
		for i := range b {
			b[i] = byte(r.IntN(256))
		}
		return b
	}
	i := r.IntN(len(b))
	switch r.IntN(4) {
	case 0:
		return b[:i]
	case 1:
		b[i] ^= byte(1 + r.IntN(255))
		return b
	case 2:
		return append(b[:i], append([]byte{byte(r.IntN(256))}, b[i:]...)...)
	default:
		return append(b[:i], b[i+1:]...)
	}
}

// sizeUpdates counts the table size updates a block starts with.
func sizeUpdates(b []byte) int {
	n := 0
	for len(b) > 0 && b[0]&0xe0 == 0x20 {
		n++
		long := b[0]&0x1f == 0x1f
		b = b[1:]
		for long && len(b) > 0 {
			long = b[0]&0x80 != 0
			b = b[1:]
		}
	}
	return n
}

func pair(f hpack.HeaderField) [2]string {
	return [2]string{hex.EncodeToString([]byte(f.Name)), hex.EncodeToString([]byte(f.Value))}
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
