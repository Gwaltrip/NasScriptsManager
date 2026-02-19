package verify

import (
	"crypto/md5"  // #nosec G501 -- used for file integrity verification only
	"crypto/sha1" // #nosec G505 -- used for file integrity verification only
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"fmt"
	"hash"
	"io"
	"os"
	"strings"
)

func newHasher(algorithm string) (hash.Hash, error) {
	switch strings.ToUpper(strings.TrimSpace(algorithm)) {
	case "SHA256":
		return sha256.New(), nil
	case "SHA1":
		return sha1.New(), nil // #nosec G401 -- used for file integrity verification only
	case "SHA512":
		return sha512.New(), nil
	case "SHA384":
		return sha512.New384(), nil
	case "MD5":
		return md5.New(), nil // #nosec G401 -- used for file integrity verification only
	default:
		return nil, fmt.Errorf("unsupported algorithm: %q", algorithm)
	}
}

func FileHashHex(path string, algorithm string, onProgress func(n int64)) (string, error) {
	h, err := newHasher(algorithm)
	if err != nil {
		return "", err
	}

	f, err := os.Open(path) // #nosec G304
	if err != nil {
		return "", err
	}
	defer func(f *os.File) {
		err := f.Close()
		if err != nil {
			panic(err)
		}
	}(f)

	buf := make([]byte, 1<<20) // 1 MiB
	var pending int64
	flush := func() {
		if pending > 0 && onProgress != nil {
			onProgress(pending)
			pending = 0
		}
	}

	for {
		n, rerr := f.Read(buf)
		if n > 0 {
			if _, werr := h.Write(buf[:n]); werr != nil {
				return "", werr
			}
			pending += int64(n)
			if pending >= int64(1<<20) {
				flush()
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return "", rerr
		}
	}
	flush()

	return strings.ToUpper(hex.EncodeToString(h.Sum(nil))), nil
}

func FileHashHexRange(path string, algorithm string, start, length int64, onProgress func(n int64)) (string, error) {
	if start < 0 || length < 0 {
		return "", fmt.Errorf("invalid range: start=%d length=%d", start, length)
	}

	h, err := newHasher(algorithm)
	if err != nil {
		return "", err
	}

	f, err := os.Open(path) // #nosec G304
	if err != nil {
		return "", err
	}
	defer func() {
		_ = f.Close()
	}()

	const bufSize = 1 << 20 // 1 MiB
	buf := make([]byte, bufSize)

	var pending int64
	flush := func() {
		if pending > 0 && onProgress != nil {
			onProgress(pending)
			pending = 0
		}
	}

	var read int64
	for read < length {
		toRead := int64(len(buf))
		remain := length - read
		if remain < toRead {
			toRead = remain
		}

		n, rerr := f.ReadAt(buf[:toRead], start+read)
		if n > 0 {
			if _, werr := h.Write(buf[:n]); werr != nil {
				return "", werr
			}
			pending += int64(n)
			if pending >= bufSize {
				flush()
			}
			read += int64(n)
		}

		if rerr != nil {
			// If we got EOF early, the file is shorter than start+length.
			if rerr == io.EOF && read == length {
				break
			}
			if rerr == io.EOF {
				return "", fmt.Errorf("unexpected EOF at offset %d (wanted %d bytes total)", start+read, length)
			}
			return "", rerr
		}
	}

	flush()
	return strings.ToUpper(hex.EncodeToString(h.Sum(nil))), nil
}

func CompareFileSplitsMany(paths []string, splits int, algorithm string) (*MultiSplitResult, error) {
	if len(paths) < 2 {
		return nil, fmt.Errorf("need at least 2 files")
	}
	if splits <= 0 {
		return nil, fmt.Errorf("splits must be > 0")
	}
	if strings.TrimSpace(algorithm) == "" {
		return nil, fmt.Errorf("algorithm must be specified")
	}

	sizes := make([]int64, len(paths))
	var minSize, maxSize int64

	for i, p := range paths {
		st, err := os.Stat(p)
		if err != nil {
			return nil, err
		}
		sz := st.Size()
		sizes[i] = sz

		if i == 0 {
			minSize, maxSize = sz, sz
		} else {
			if sz < minSize {
				minSize = sz
			}
			if sz > maxSize {
				maxSize = sz
			}
		}
	}

	base := minSize / int64(splits)
	rem := minSize % int64(splits)

	splitHashes := make([][]string, splits)
	for i := range splitHashes {
		splitHashes[i] = make([]string, len(paths))
	}

	var offset int64
	for s := 0; s < splits; s++ {
		chunkLen := base
		if int64(s) < rem {
			chunkLen++
		}
		start := offset
		offset += chunkLen

		for fi, p := range paths {
			hx, err := FileHashHexRange(p, algorithm, start, chunkLen, nil)
			if err != nil {
				return nil, err
			}
			splitHashes[s][fi] = hx
		}
	}

	differing := make([]int, 0)
	for s := 0; s < splits; s++ {
		ref := splitHashes[s][0]
		allSame := true
		for fi := 1; fi < len(paths); fi++ {
			if splitHashes[s][fi] != ref {
				allSame = false
				break
			}
		}
		if !allSame {
			differing = append(differing, s)
		}
	}

	tails := make([]int64, len(paths))
	if minSize != maxSize {
		for i := range sizes {
			if sizes[i] > minSize {
				tails[i] = sizes[i] - minSize
			}
		}
	}

	return &MultiSplitResult{
		Algorithm:       algorithm,
		Splits:          splits,
		Paths:           paths,
		Sizes:           sizes,
		MinSize:         minSize,
		MaxSize:         maxSize,
		SplitHashes:     splitHashes,
		DifferingSplits: differing,
		TailBytes:       tails,
	}, nil
}
