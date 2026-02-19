package index

type RunInfo struct {
	Algorithm  string
	Meta       map[string]any
	Total      int64
	OkCount    int64
	ErrorCount int64
	Root       string
	CreatedUtc string
	StartedUtc string
	TotalBytes int64
}

type FileItem struct {
	Ok     bool
	Path   string
	Length int64
	Hash   string
	Error  *string
}
