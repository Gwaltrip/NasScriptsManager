package metrics

import (
	"fmt"
	"sync/atomic"
)

type Snapshot struct {
	DurationMs     int64
	Total          int64
	Processed      int64
	OK             int64
	Skipped        int64
	StatErrors     int64
	SizeMismatches int64
	HashErrors     int64
	HashMismatches int64
	BytesHashed    int64
	BytesStatOK    int64
	TotalBytes     int64
}

func (s *Stats) Snapshot() Snapshot {
	dur := s.Duration()

	return Snapshot{
		DurationMs:     dur.Milliseconds(),
		Total:          atomic.LoadInt64(&s.Total),
		Processed:      atomic.LoadInt64(&s.Processed),
		OK:             atomic.LoadInt64(&s.OK),
		Skipped:        atomic.LoadInt64(&s.Skipped),
		StatErrors:     atomic.LoadInt64(&s.StatErrors),
		SizeMismatches: atomic.LoadInt64(&s.SizeMismatches),
		HashErrors:     atomic.LoadInt64(&s.HashErrors),
		HashMismatches: atomic.LoadInt64(&s.HashMismatches),
		BytesHashed:    atomic.LoadInt64(&s.BytesHashed),
		BytesStatOK:    atomic.LoadInt64(&s.BytesStatOK),
		TotalBytes:     atomic.LoadInt64(&s.TotalBytes),
	}
}

func Print(s *Stats) {
	snap := s.Snapshot()

	fmt.Println("--- stats ---")
	fmt.Println("duration_ms:", snap.DurationMs)
	fmt.Println("total:", snap.Total)
	fmt.Println("processed:", snap.Processed)
	fmt.Println("ok:", snap.OK)
	fmt.Println("skipped:", snap.Skipped)
	fmt.Println("stat_errors:", snap.StatErrors)
	fmt.Println("size_mismatches:", snap.SizeMismatches)
	fmt.Println("hash_errors:", snap.HashErrors)
	fmt.Println("hash_mismatches:", snap.HashMismatches)
	fmt.Println("bytes_hashed:", snap.BytesHashed)
	fmt.Println("bytes_stat_ok:", snap.BytesStatOK)
	fmt.Println("total_bytes:", snap.TotalBytes)

	if snap.DurationMs > 0 {
		secs := float64(snap.DurationMs) / 1000.0
		bps := float64(snap.BytesHashed) / secs
		fmt.Println("throughput_bytes_per_sec:", bps)
		fmt.Println("throughput_mb_per_sec:", bps/1_000_000.0)
	}
}
