package verify

type Mismatch struct {
	Path     string
	Expected string
	Computed string
}

type Result struct {
	Mismatches []Mismatch
}

type Options struct {
	Workers int
}

type SplitDiff struct {
	Index int
	Start int64
	End   int64
	HashA string
	HashB string
	Equal bool
}

type SplitCompareResult struct {
	SizeA, SizeB int64
	SameSize     bool
	Splits       int
	Diffs        []SplitDiff
}

type MultiSplitResult struct {
	Algorithm       string
	Splits          int
	Paths           []string
	Sizes           []int64
	SplitHashes     [][]string
	DifferingSplits []int
	TailBytes       []int64
	MinSize         int64
	MaxSize         int64
}
