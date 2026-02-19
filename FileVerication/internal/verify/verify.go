package verify

import (
	"FileVerication/internal/index"
	"FileVerication/internal/metrics"
	"FileVerication/internal/progress"
	"os"
	"strings"
	"sync"
	"sync/atomic"
)

func Verify(runAlgorithm string, items []index.FileItem, opts Options, stats *metrics.Stats, bar *progress.Bar) *Result {
	workers := opts.Workers
	if workers <= 0 {
		workers = 1
	}
	res := &Result{}
	var mu sync.Mutex

	jobs := make(chan index.FileItem)
	var wg sync.WaitGroup

	worker := func() {
		defer wg.Done()

		for fi := range jobs {
			finish := func() {
				atomic.AddInt64(&stats.Processed, 1)
			}
			advance := func(n int64) {
				if n > 0 && bar != nil {
					bar.AddBytes(n)
				}
			}

			if fi.Error != nil {
				atomic.AddInt64(&stats.Skipped, 1)
				advance(fi.Length)
				finish()
				continue
			}

			info, err := os.Stat(fi.Path)
			if err != nil {
				atomic.AddInt64(&stats.StatErrors, 1)
				advance(fi.Length)
				finish()
				continue
			}
			if info.Size() != fi.Length {
				atomic.AddInt64(&stats.SizeMismatches, 1)
				advance(fi.Length)
				finish()
				continue
			}

			atomic.AddInt64(&stats.BytesStatOK, info.Size())

			var bytesSent int64
			computed, err := FileHashHex(fi.Path, runAlgorithm, func(n int64) {
				atomic.AddInt64(&stats.BytesHashed, n)
				bytesSent += n
				advance(n)
			})
			if err != nil {
				atomic.AddInt64(&stats.HashErrors, 1)
				advance(fi.Length - bytesSent)
				finish()
				continue
			}

			advance(fi.Length - bytesSent)

			match := strings.EqualFold(computed, strings.TrimSpace(fi.Hash))
			if !match {
				atomic.AddInt64(&stats.HashMismatches, 1)

				mu.Lock()
				res.Mismatches = append(res.Mismatches, Mismatch{
					Path:     fi.Path,
					Expected: fi.Hash,
					Computed: computed,
				})
				mu.Unlock()

				finish()
				continue
			}

			atomic.AddInt64(&stats.OK, 1)
			finish()
		}
	}

	wg.Add(workers)
	for i := 0; i < workers; i++ {
		go worker()
	}

	for _, fi := range items {
		jobs <- fi
	}
	close(jobs)

	wg.Wait()
	return res
}
