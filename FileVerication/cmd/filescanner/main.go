package main

import (
	"FileVerication/internal/index"
	"FileVerication/internal/metrics"
	"FileVerication/internal/progress"
	"FileVerication/internal/verify"
	"flag"
	"fmt"
	"os"
	"sync/atomic"
)

func main() {
	defaultPath := "\\\\192.168.1.1\\anime\\AnimeHashIndex.clixml"
	indexPath := flag.String("index", defaultPath, "path to CLIXML index")
	flag.Parse()

	run, items, err := index.Load(*indexPath)
	if err != nil {
		panic(err)
	}

	fmt.Println("meta:", run.Meta)
	fmt.Println("algorithm:", run.Algorithm)
	fmt.Println("items count:", len(items))

	stats := &metrics.Stats{}
	stats.Start()
	atomic.StoreInt64(&stats.Total, int64(len(items)))
	atomic.StoreInt64(&stats.TotalBytes, run.TotalBytes)

	bar := progress.New(run.TotalBytes, func() (p, total, ok, hash_mismatch, errc, skip, bytesHashed int64) {
		p = atomic.LoadInt64(&stats.Processed)
		total = atomic.LoadInt64(&stats.Total)
		ok = atomic.LoadInt64(&stats.OK)
		hash_mismatch = atomic.LoadInt64(&stats.HashMismatches)
		err := atomic.LoadInt64(&stats.HashErrors) + atomic.LoadInt64(&stats.StatErrors)
		skip = atomic.LoadInt64(&stats.Skipped)
		bytesHashed = atomic.LoadInt64(&stats.BytesHashed)
		return p, total, ok, hash_mismatch, err, skip, bytesHashed
	})
	defer bar.Close()

	res := verify.Verify(run.Algorithm, items, verify.Options{Workers: 2}, stats, bar)

	stats.Stop()

	metrics.Print(stats)
	f, _ := os.Create("mismatches.txt")
	defer func(f *os.File) {
		err := f.Close()
		if err != nil {
			fmt.Println("Error:", err)
		}
	}(f)
	fmt.Println("mismatched files:", len(res.Mismatches))
	for _, m := range res.Mismatches {
		fmt.Println(m.Path)
		_, err := fmt.Fprintln(f, m.Path)
		if err != nil {
			fmt.Println("Error:", err)
		}
	}
}
