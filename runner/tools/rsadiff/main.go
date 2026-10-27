// Command rsadiff writes the keys, messages and signatures .github/scripts/rsa-diff.sh checks the
// runner's RS256 signing (runner/src/github/rsa_sign.zig) against: SHA-256 RSASSA-PKCS1-v1_5,
// signed by Go's crypto/rsa SignPKCS1v15. The scheme is deterministic, so the signatures must be
// the same byte for byte.
//
//	go run . -out <cases.jsonl> [-n 2000] [-seed 1]
//
// Keys are few (one per 50 messages, at most 40) and reused: 2048 bits mostly, as GitHub's runner
// keys are, some 3072 and 4096 (the most rsa_sign.zig takes), and sizes that are not whole bytes.
// The key is given as the runner reads it from .credentials_rsaparams (.NET's RSAParameters): the
// modulus and private exponent big-endian, the exponent padded to the modulus's length; sometimes
// unpadded, or the modulus with a leading zero byte. Messages are JWT signing inputs like the
// runner's, empty, short, and long random bytes. Go's crypto/rsa ignores the random source it is
// given, so the keys are new each run; runner/tools/rsacorpus.zig prints the key with a
// disagreement.
//
// Each line is {"id": n, "n": hex, "d": hex, "msg": hex, "sig": hex}.
package main

import (
	"bufio"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	mrand "math/rand/v2"
	"os"
	"sync"
)

// Key sizes, in the order the first keys take them; then at random.
var sizes = []int{2048, 4096, 2047, 3072, 2049, 2048, 4095, 2048, 3071, 2052, 2048, 2048}

type testCase struct {
	ID  int    `json:"id"`
	N   string `json:"n"`
	D   string `json:"d"`
	Msg string `json:"msg"`
	Sig string `json:"sig"`
}

func main() {
	out := flag.String("out", "cases.jsonl", "where to write the cases")
	n := flag.Int("n", 2000, "messages")
	seed := flag.Uint64("seed", 1, "random seed (for the key sizes and messages)")
	flag.Parse()

	r := mrand.New(mrand.NewPCG(*seed, 0))
	keys := make([]*rsa.PrivateKey, min(max(*n/50, 1), 40))
	bits := make([]int, len(keys))
	for i := range bits {
		bits[i] = sizes[i%len(sizes)]
		if i >= len(sizes) {
			bits[i] = sizes[r.IntN(len(sizes))]
		}
	}
	var wg sync.WaitGroup
	for i := range keys {
		wg.Go(func() {
			k, err := rsa.GenerateKey(rand.Reader, bits[i])
			must(err)
			keys[i] = k
		})
	}
	wg.Wait()

	f, err := os.Create(*out)
	must(err)
	w := bufio.NewWriter(f)
	enc := json.NewEncoder(w)
	for id := range *n {
		k := keys[id%len(keys)]
		msg := message(r)
		digest := sha256.Sum256(msg)
		sig, err := rsa.SignPKCS1v15(nil, k, crypto.SHA256, digest[:])
		must(err)
		nb := k.N.Bytes()
		d := k.D.FillBytes(make([]byte, len(nb)))
		switch r.IntN(8) {
		case 0:
			d = k.D.Bytes()
		case 1:
			nb = append([]byte{0}, nb...)
		}
		must(enc.Encode(testCase{
			ID: id, N: hex.EncodeToString(nb), D: hex.EncodeToString(d),
			Msg: hex.EncodeToString(msg), Sig: hex.EncodeToString(sig),
		}))
	}
	must(w.Flush())
	must(f.Close())
}

// message returns what the runner signs (a JWT's header and claims), or empty, short or long bytes.
func message(r *mrand.Rand) []byte {
	switch r.IntN(4) {
	case 0:
		b64 := base64.RawURLEncoding
		claims := fmt.Sprintf(`{"sub":"%x","iss":"%x","aud":"https://pipelines.actions.githubusercontent.com/%x/_apis/oauth2/token","nbf":%d,"iat":%d,"exp":%d,"jti":"%x"}`,
			r.Uint64(), r.Uint64(), r.Uint64(), r.Uint32(), r.Uint32(), r.Uint32(), r.Uint64())
		return []byte(b64.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`)) + "." + b64.EncodeToString([]byte(claims)))
	case 1:
		if r.IntN(4) == 0 {
			return nil
		}
		fallthrough
	case 2:
		return random(r, 1+r.IntN(64))
	default:
		return random(r, r.IntN(10000))
	}
}

func random(r *mrand.Rand, n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(r.IntN(256))
	}
	return b
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
