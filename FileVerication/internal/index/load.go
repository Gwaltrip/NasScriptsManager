package index

import (
	def "FileVerication/definitions"
	"encoding/xml"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func Load(path string) (run RunInfo, items []FileItem, err error) {
	data, err := os.ReadFile(path) // #nosec G304
	if err != nil {
		return RunInfo{}, nil, err
	}

	var doc def.Objs
	if err := xml.Unmarshal(data, &doc); err != nil {
		return RunInfo{}, nil, err
	}
	if len(doc.Objects) == 0 {
		return RunInfo{}, nil, fmt.Errorf("clixml: no top-level objects")
	}

	root := doc.Objects[0]
	ms := root.MS

	meta := map[string]any{}
	for _, s := range ms.Strings {
		meta[s.Name] = s.Value
	}
	for _, n := range ms.Int32s {
		meta[n.Name] = n.Value
	}

	var itemsObj *def.Obj
	for i := range ms.Objs {
		if ms.Objs[i].Name == "items" {
			itemsObj = &ms.Objs[i]
			break
		}
	}
	if itemsObj == nil || itemsObj.LST == nil {
		run = RunInfo{
			Algorithm:  ms.Algorithm,
			Meta:       meta,
			TotalBytes: 0,
		}
		return run, []FileItem{}, nil
	}

	toInt64 := func(v any) (int64, bool) {
		switch n := v.(type) {
		case int64:
			return n, true
		case int32:
			return int64(n), true
		case int:
			return int64(n), true
		case string:
			parsed, err := strconv.ParseInt(n, 10, 64)
			if err == nil {
				return parsed, true
			}
		}
		return 0, false
	}

	toBool := func(v any) (bool, bool) {
		switch b := v.(type) {
		case bool:
			return b, true
		case string:
			switch strings.ToLower(strings.TrimSpace(b)) {
			case "true", "1", "yes":
				return true, true
			case "false", "0", "no":
				return false, true
			default:
				return false, false
			}
		}
		return false, false
	}

	items = make([]FileItem, 0, len(itemsObj.LST.Items))
	for _, item := range itemsObj.LST.Items {
		if item.DCT == nil {
			continue
		}
		var fi FileItem
		for _, en := range item.DCT.Entries {
			k, v, ok, err := en.KeyValue()
			if err != nil {
				return RunInfo{}, nil, fmt.Errorf("clixml: entry decode error: %w", err)
			}
			if !ok {
				continue
			}

			switch k {
			case "ok":
				if b, ok := toBool(v); ok {
					fi.Ok = b
				}
			case "path":
				if s, ok := v.(string); ok {
					fi.Path = s
				}
			case "length":
				if n, ok := toInt64(v); ok {
					fi.Length = n
				}
			case "hash":
				if s, ok := v.(string); ok {
					fi.Hash = s
				}
			case "error":
				if v == nil {
					fi.Error = nil
				} else if s, ok := v.(string); ok {
					fi.Error = &s
				}
			}
		}
		items = append(items, fi)
	}

	var totalBytes int64
	for _, fi := range items {
		if fi.Error == nil {
			totalBytes += fi.Length
		}
	}

	run = RunInfo{
		Algorithm:  ms.Algorithm,
		Meta:       meta,
		TotalBytes: totalBytes,
	}
	return run, items, nil
}
