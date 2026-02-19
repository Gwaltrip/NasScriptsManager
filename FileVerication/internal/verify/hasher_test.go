package verify

import (
	"bytes"
	"crypto/md5"  // #nosec G401
	"crypto/sha1" // #nosec G401
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func expectedHexUpper(algorithm string, content []byte) (string, error) {
	switch strings.ToUpper(strings.TrimSpace(algorithm)) {
	case "SHA256":
		h := sha256.Sum256(content)
		return strings.ToUpper(hex.EncodeToString(h[:])), nil
	case "SHA1":
		h := sha1.Sum(content)
		return strings.ToUpper(hex.EncodeToString(h[:])), nil
	case "SHA512":
		h := sha512.Sum512(content)
		return strings.ToUpper(hex.EncodeToString(h[:])), nil
	case "SHA384":
		h := sha512.Sum384(content)
		return strings.ToUpper(hex.EncodeToString(h[:])), nil
	case "MD5":
		h := md5.Sum(content)
		return strings.ToUpper(hex.EncodeToString(h[:])), nil
	default:
		return "", os.ErrInvalid
	}
}

func TestFileHashHex_TableDriven(t *testing.T) {
	dir := t.TempDir()

	makeFile := func(name string, content []byte) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, content, 0o600); err != nil {
			t.Fatalf("write temp file: %v", err)
		}
		return p
	}

	contentSmall := []byte("hello world")
	contentLarge := bytes.Repeat([]byte("A"), 2<<20) // 2 MiB

	tests := []struct {
		name      string
		algorithm string
		content   []byte
		missing   bool
		wantErr   bool
	}{
		{"sha256 small", "SHA256", contentSmall, false, false},
		{"sha256 large", "SHA256", contentLarge, false, false},
		{"sha1", "SHA1", contentSmall, false, false},
		{"sha512", "SHA512", contentSmall, false, false},
		{"sha384", "SHA384", contentSmall, false, false},
		{"md5", "MD5", contentSmall, false, false},
		{"unsupported algorithm", "BLAKE3", contentSmall, false, true},
		{"file missing", "SHA256", contentSmall, true, true},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			var path string
			if tt.missing {
				path = filepath.Join(dir, "does-not-exist.bin")
			} else {
				path = makeFile(tt.name+".bin", tt.content)
			}

			var progressed int64
			hash, err := FileHashHex(path, tt.algorithm, func(n int64) {
				progressed += n
			})

			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			want, err := expectedHexUpper(tt.algorithm, tt.content)
			if err != nil {
				t.Fatalf("expectedHexUpper: %v", err)
			}

			if hash != want {
				t.Fatalf("hash mismatch:\n got: %s\nwant: %s", hash, want)
			}

			if progressed != int64(len(tt.content)) {
				t.Fatalf("progress mismatch:\n got: %d\nwant: %d",
					progressed, len(tt.content))
			}
		})
	}
}
