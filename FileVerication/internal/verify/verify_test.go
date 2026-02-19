package verify

import (
	"FileVerication/internal/index"
	"FileVerication/internal/metrics"
	"bytes"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func hashHexUpper(algorithm string, content []byte) (string, error) {
	alg := strings.ToUpper(strings.TrimSpace(algorithm))

	var sum []byte
	switch alg {
	case "SHA256":
		h := sha256.Sum256(content)
		sum = h[:]
	case "SHA1":
		h := sha1.Sum(content)
		sum = h[:]
	case "SHA512":
		h := sha512.Sum512(content)
		sum = h[:]
	case "SHA384":
		h := sha512.Sum384(content)
		sum = h[:]
	case "MD5":
		h := md5.Sum(content)
		sum = h[:]
	default:
		return "", &unsupportedAlgError{alg: algorithm}
	}

	return strings.ToUpper(hex.EncodeToString(sum)), nil
}

type unsupportedAlgError struct{ alg string }

func (e *unsupportedAlgError) Error() string { return "unsupported algorithm: " + e.alg }

func writeFile(t *testing.T, dir, name string, data []byte) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, data, 0o600); err != nil {
		t.Fatalf("write file %s: %v", p, err)
	}
	return p
}
func writeBytesFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func TestVerify_TableDriven(t *testing.T) {
	dir := t.TempDir()

	goodContent := bytes.Repeat([]byte("A"), 1024) // 1 KiB
	badContent := bytes.Repeat([]byte("B"), 2048)  // 2 KiB

	goodPath := writeFile(t, dir, "good.bin", goodContent)
	badPath := writeFile(t, dir, "bad.bin", badContent)

	const alg = "SHA256"

	goodHash, err := hashHexUpper(alg, goodContent)
	if err != nil {
		t.Fatal(err)
	}

	wrongHash, err := hashHexUpper(alg, []byte("not the file content"))
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name      string
		algorithm string
		items     []index.FileItem
		want      want
		wantMis   []Mismatch
		workers   int
	}{
		{
			name:      "all ok",
			algorithm: alg,
			workers:   2,
			items: []index.FileItem{
				{Ok: true, Path: goodPath, Length: int64(len(goodContent)), Hash: goodHash, Error: nil},
			},
			want: want{
				processed:      1,
				ok:             1,
				skipped:        0,
				statErrors:     0,
				sizeMismatches: 0,
				hashErrors:     0,
				hashMismatches: 0,
			},
			wantMis: nil,
		},
		{
			name:      "hash mismatch recorded",
			algorithm: alg,
			workers:   2,
			items: []index.FileItem{
				{Ok: true, Path: badPath, Length: int64(len(badContent)), Hash: wrongHash, Error: nil},
			},
			want: want{
				processed:      1,
				ok:             0,
				skipped:        0,
				statErrors:     0,
				sizeMismatches: 0,
				hashErrors:     0,
				hashMismatches: 1,
			},
			wantMis: []Mismatch{
				{Path: badPath, Expected: wrongHash},
			},
		},
		{
			name:      "skip when item has error",
			algorithm: alg,
			workers:   2,
			items: []index.FileItem{
				{
					Ok:     false,
					Path:   goodPath,
					Length: int64(len(goodContent)),
					Hash:   goodHash,
					Error:  ptr("some prior error"),
				},
			},
			want: want{
				processed:      1,
				ok:             0,
				skipped:        1,
				statErrors:     0,
				sizeMismatches: 0,
				hashErrors:     0,
				hashMismatches: 0,
			},
			wantMis: nil,
		},
		{
			name:      "stat error when file missing",
			algorithm: alg,
			workers:   2,
			items: []index.FileItem{
				{Ok: true, Path: filepath.Join(dir, "does-not-exist.bin"), Length: 123, Hash: "ABC", Error: nil},
			},
			want: want{
				processed:      1,
				ok:             0,
				skipped:        0,
				statErrors:     1,
				sizeMismatches: 0,
				hashErrors:     0,
				hashMismatches: 0,
			},
			wantMis: nil,
		},
		{
			name:      "size mismatch when length differs",
			algorithm: alg,
			workers:   2,
			items: []index.FileItem{
				{Ok: true, Path: goodPath, Length: int64(len(goodContent) + 1), Hash: goodHash, Error: nil},
			},
			want: want{
				processed:      1,
				ok:             0,
				skipped:        0,
				statErrors:     0,
				sizeMismatches: 1,
				hashErrors:     0,
				hashMismatches: 0,
			},
			wantMis: nil,
		},
		{
			name:      "mixed batch updates all counters",
			algorithm: alg,
			workers:   2,
			items: []index.FileItem{
				{Ok: true, Path: goodPath, Length: int64(len(goodContent)), Hash: goodHash, Error: nil},                 // ok
				{Ok: true, Path: badPath, Length: int64(len(badContent)), Hash: wrongHash, Error: nil},                  // mismatch
				{Ok: false, Path: goodPath, Length: int64(len(goodContent)), Hash: goodHash, Error: ptr("prior error")}, // skipped
				{Ok: true, Path: filepath.Join(dir, "missing.bin"), Length: 5, Hash: "X", Error: nil},                   // stat error
				{Ok: true, Path: goodPath, Length: int64(len(goodContent) + 10), Hash: goodHash, Error: nil},            // size mismatch
			},
			want: want{
				processed:      5,
				ok:             1,
				skipped:        1,
				statErrors:     1,
				sizeMismatches: 1,
				hashErrors:     0,
				hashMismatches: 1,
			},
			wantMis: []Mismatch{
				{Path: badPath, Expected: wrongHash},
			},
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			stats := &metrics.Stats{}
			atomic.StoreInt64(&stats.Total, int64(len(tt.items)))

			res := Verify(tt.algorithm, tt.items, Options{Workers: tt.workers}, stats, nil)

			got := want{
				processed:      atomic.LoadInt64(&stats.Processed),
				ok:             atomic.LoadInt64(&stats.OK),
				skipped:        atomic.LoadInt64(&stats.Skipped),
				statErrors:     atomic.LoadInt64(&stats.StatErrors),
				sizeMismatches: atomic.LoadInt64(&stats.SizeMismatches),
				hashErrors:     atomic.LoadInt64(&stats.HashErrors),
				hashMismatches: atomic.LoadInt64(&stats.HashMismatches),
			}
			if got != tt.want {
				t.Fatalf("stats mismatch:\n got: %+v\nwant: %+v", got, tt.want)
			}

			if len(tt.wantMis) == 0 {
				if res != nil && len(res.Mismatches) != 0 {
					t.Fatalf("expected no mismatches, got %d", len(res.Mismatches))
				}
				return
			}

			if res == nil {
				t.Fatalf("expected Result, got nil")
			}

			for _, w := range tt.wantMis {
				found := false
				for _, m := range res.Mismatches {
					if m.Path == w.Path && strings.EqualFold(strings.TrimSpace(m.Expected), strings.TrimSpace(w.Expected)) {
						found = true
						if strings.TrimSpace(m.Computed) == "" {
							t.Fatalf("mismatch for %s has empty Computed", m.Path)
						}
						break
					}
				}
				if !found {
					t.Fatalf("expected mismatch for path=%q expected=%q not found; got=%+v", w.Path, w.Expected, res.Mismatches)
				}
			}
		})
	}
}

type want struct {
	processed      int64
	ok             int64
	skipped        int64
	statErrors     int64
	sizeMismatches int64
	hashErrors     int64
	hashMismatches int64
}

func ptr(s string) *string { return &s }

func makeTestData(size int) []byte {
	b := make([]byte, size)
	_, _ = rand.Read(b) // fine for tests
	return b
}

func flipOneBitInFile(t *testing.T, path string, offset int64, bit uint8) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatalf("open for r/w %s: %v", path, err)
	}
	defer f.Close()

	var one [1]byte
	if _, err := f.ReadAt(one[:], offset); err != nil {
		t.Fatalf("readat %s offset %d: %v", path, offset, err)
	}

	one[0] ^= (1 << bit)

	if _, err := f.WriteAt(one[:], offset); err != nil {
		t.Fatalf("writeat %s offset %d: %v", path, offset, err)
	}
}

func appendBytes(t *testing.T, path string, extra []byte) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatalf("open append %s: %v", path, err)
	}
	defer f.Close()

	if _, err := f.Write(extra); err != nil {
		t.Fatalf("append %s: %v", path, err)
	}
}

func TestCompareFileSplitsMany_Identical(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a.bin")
	b := filepath.Join(dir, "b.bin")

	data := makeTestData(8 * 1024 * 1024) // 8 MiB
	writeBytesFile(t, a, data)
	writeBytesFile(t, b, data)

	res, err := CompareFileSplitsMany([]string{a, b}, 8, "SHA256")
	if err != nil {
		t.Fatalf("CompareFileSplitsMany: %v", err)
	}

	if res.MinSize != res.MaxSize {
		t.Fatalf("expected same size, got min=%d max=%d", res.MinSize, res.MaxSize)
	}
	if len(res.DifferingSplits) != 0 {
		t.Fatalf("expected no differing splits, got %v", res.DifferingSplits)
	}
	for _, tb := range res.TailBytes {
		if tb != 0 {
			t.Fatalf("expected no tails, got %v", res.TailBytes)
		}
	}
}

func TestCompareFileSplitsMany_OneBitFlip(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a.bin")
	b := filepath.Join(dir, "b.bin")

	data := makeTestData(8 * 1024 * 1024) // 8 MiB
	writeBytesFile(t, a, data)
	writeBytesFile(t, b, data)

	flipOffset := int64(len(data) / 2)
	flipOneBitInFile(t, b, flipOffset, 3) // flip bit #3

	afterA, _ := os.ReadFile(a)
	afterB, _ := os.ReadFile(b)
	if bytes.Equal(afterA, afterB) {
		t.Fatalf("expected files to differ after bit flip")
	}

	res, err := CompareFileSplitsMany([]string{a, b}, 8, "SHA256")
	if err != nil {
		t.Fatalf("CompareFileSplitsMany: %v", err)
	}

	if res.MinSize != res.MaxSize {
		t.Fatalf("expected same size, got min=%d max=%d", res.MinSize, res.MaxSize)
	}
	if len(res.DifferingSplits) == 0 {
		t.Fatalf("expected at least one differing split, got none")
	}

	if len(res.DifferingSplits) != 1 {
		t.Fatalf("expected exactly 1 differing split for one bit flip, got %v", res.DifferingSplits)
	}

	expectedSplit := int(flipOffset / (1 << 20))
	if res.DifferingSplits[0] != expectedSplit {
		t.Fatalf("expected differing split %d, got %v", expectedSplit, res.DifferingSplits)
	}
}

func TestCompareFileSplitsMany_TailDifference(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a.bin")
	b := filepath.Join(dir, "b.bin")

	data := makeTestData(4 * 1024 * 1024) // 4 MiB
	writeBytesFile(t, a, data)
	writeBytesFile(t, b, data)

	appendBytes(t, b, []byte("EXTRA_TAIL_BYTES"))

	res, err := CompareFileSplitsMany([]string{a, b}, 8, "SHA256")
	if err != nil {
		t.Fatalf("CompareFileSplitsMany: %v", err)
	}

	if res.MinSize == res.MaxSize {
		t.Fatalf("expected size mismatch, got min=%d max=%d", res.MinSize, res.MaxSize)
	}

	if len(res.DifferingSplits) != 0 {
		t.Fatalf("expected no differing splits over overlap, got %v", res.DifferingSplits)
	}

	if res.TailBytes[0] != 0 || res.TailBytes[1] == 0 {
		t.Fatalf("expected tail on file 1 only, got %v", res.TailBytes)
	}
}
