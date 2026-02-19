package main

import (
	"FileVerication/internal/verify"
	"flag"
	"fmt"
	"log"
	"os"
)

func main() {
	var (
		splits    int
		algorithm string
	)

	flag.IntVar(&splits, "splits", 8, "Number of splits")
	flag.StringVar(&algorithm, "alg", "SHA256", "Hash algorithm (SHA256, SHA1, SHA512, SHA384, MD5)")
	flag.Parse()

	paths := flag.Args()

	if len(paths) < 2 {
		_, err := fmt.Fprintf(os.Stderr, "usage: %s -splits 8 -alg SHA256 <file1> <file2> [file3 ...]\n", os.Args[0])
		if err != nil {
			fmt.Println(err)
			return
		}
		os.Exit(2)
	}

	res, err := verify.CompareFileSplitsMany(paths, splits, algorithm)
	if err != nil {
		log.Fatalf("CompareFileSplitsMany failed: %v", err)
	}

	fmt.Printf("Algorithm: %s\n", res.Algorithm)
	fmt.Printf("Splits:    %d\n\n", res.Splits)

	fmt.Println("Files:")
	for i, p := range res.Paths {
		fmt.Printf("  [%d] %s (size=%d)\n", i, p, res.Sizes[i])
	}
	fmt.Println()

	if res.MinSize != res.MaxSize {
		fmt.Printf("Size mismatch detected.\nOverlap: %d bytes\nMax: %d bytes\n\n", res.MinSize, res.MaxSize)
		for i, tb := range res.TailBytes {
			if tb > 0 {
				fmt.Printf("  [%d] extra tail: %d bytes\n", i, tb)
			}
		}
		fmt.Println()
	}

	if len(res.DifferingSplits) == 0 && res.MinSize == res.MaxSize {
		fmt.Println("Result: All splits match and sizes match (files identical).")
		return
	}

	if len(res.DifferingSplits) == 0 {
		fmt.Println("Result: All splits match over overlap; only tails differ.")
		return
	}

	fmt.Printf("Differing splits: %v\n\n", res.DifferingSplits)

	for _, s := range res.DifferingSplits {
		fmt.Printf("Split %d differs:\n", s)
		for fi, p := range res.Paths {
			fmt.Printf("  [%d] %s\n      %s\n", fi, p, res.SplitHashes[s][fi])
		}
		fmt.Println()
	}
}
