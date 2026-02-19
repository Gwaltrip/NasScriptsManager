package metrics

import "time"

type Stats struct {
	TotalBytes int64

	Processed      int64
	Total          int64
	Skipped        int64
	StatErrors     int64
	SizeMismatches int64
	HashErrors     int64
	HashMismatches int64
	OK             int64

	BytesHashed int64
	BytesStatOK int64
	Started     time.Time
	Finished    time.Time
}

func (s *Stats) Start() { s.Started = time.Now() }
func (s *Stats) Stop()  { s.Finished = time.Now() }
func (s *Stats) Duration() time.Duration {
	if s.Finished.IsZero() {
		return time.Since(s.Started)
	}
	return s.Finished.Sub(s.Started)
}
