package progress

import (
	"fmt"
	"os"
	"time"

	"github.com/schollz/progressbar/v3"
)

type SnapshotFn func() (p, total, ok, hash_mismatch, errc, skip, bytesHashed int64)

type Bar struct {
	bar  *progressbar.ProgressBar
	ch   chan int64
	done chan struct{}
	stop chan struct{}

	snap   SnapshotFn
	lastB  int64
	lastAt time.Time
}

func New(totalBytes int64, snap SnapshotFn) *Bar {
	b := &Bar{
		ch:     make(chan int64, 16384),
		done:   make(chan struct{}),
		stop:   make(chan struct{}),
		snap:   snap,
		lastAt: time.Now(),
	}

	b.bar = progressbar.NewOptions64(
		totalBytes,
		progressbar.OptionSetWriter(os.Stdout),
		progressbar.OptionUseANSICodes(true),
		progressbar.OptionSetDescription("hashing"),
		progressbar.OptionShowCount(),
		progressbar.OptionShowIts(),
		progressbar.OptionShowBytes(true),
		progressbar.OptionSetPredictTime(true),
		progressbar.OptionThrottle(120*time.Millisecond),
	)

	err := b.bar.RenderBlank()
	if err != nil {
		panic(err)
	}
	go func() {
		defer close(b.done)
		for n := range b.ch {
			_ = b.bar.Add64(n)
		}
		_ = b.bar.Finish()
	}()

	go func() {
		t := time.NewTicker(1 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				b.updateDescription()
			case <-b.stop:
				return
			}
		}
	}()

	return b
}

func (b *Bar) AddBytes(n int64) {
	if n <= 0 {
		return
	}
	b.ch <- n
}

func (b *Bar) Close() {
	close(b.stop)
	close(b.ch)
	<-b.done
}

func (b *Bar) updateDescription() {
	if b.snap == nil {
		return
	}
	p, total, ok, hash_mismatches, errc, skip, bytesHashed := b.snap()

	now := time.Now()
	dt := now.Sub(b.lastAt).Seconds()

	mbps := 0.0
	if dt > 0 {
		dBytes := bytesHashed - b.lastB
		mbps = (float64(dBytes) / 1_000_000.0) / dt
	}

	b.lastB = bytesHashed
	b.lastAt = now

	desc := fmt.Sprintf("hashing %d/%d files | ok=%d hash_mismatches=%d err=%d skip=%d | %.1f MB/s",
		p, total, ok, hash_mismatches, errc, skip, mbps,
	)
	b.bar.Describe(desc)
}
