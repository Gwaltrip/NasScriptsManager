package index_test

import (
	"FileVerication/internal/index"
	"os"
	"path/filepath"
	"testing"
)

func writeTempCLIXML(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "test.clixml")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	return p
}

func strPtr(s string) *string { return &s }

func TestLoad_TableDriven(t *testing.T) {
	const xmlWithItems = `<?xml version="1.0" encoding="utf-8"?>
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">
  <Obj RefId="0">
    <TN RefId="0">
      <T>System.Management.Automation.PSCustomObject</T>
      <T>System.Object</T>
    </TN>
    <MS>
      <S N="createdUtc">2026-02-16T23:09:08.4209857Z</S>
      <S N="startedUtc">2026-02-16T23:08:14.6110939Z</S>
      <S N="algorithm">SHA256</S>
      <S N="root">\\192.168.1.1\anime</S>
      <I32 N="total">2</I32>
      <I32 N="okCount">1</I32>
      <I32 N="errorCount">1</I32>

      <Obj N="items" RefId="1">
        <TN RefId="1">
          <T>System.Object[]</T>
          <T>System.Array</T>
          <T>System.Object</T>
        </TN>
        <LST>
          <Obj RefId="2">
            <TN RefId="2">
              <T>System.Collections.Specialized.OrderedDictionary</T>
              <T>System.Object</T>
            </TN>
            <DCT>
              <En><S N="Key">ok</S><B N="Value">true</B></En>
              <En><S N="Key">path</S><S N="Value">\\192.168.1.1\anime\a.mkv</S></En>
              <En><S N="Key">length</S><I64 N="Value">10</I64></En>
              <En><S N="Key">hash</S><S N="Value">AAA</S></En>
              <En><S N="Key">error</S><Nil N="Value" /></En>
            </DCT>
          </Obj>

          <Obj RefId="3">
            <TN RefId="2">
              <T>System.Collections.Specialized.OrderedDictionary</T>
              <T>System.Object</T>
            </TN>
            <DCT>
              <En><S N="Key">ok</S><B N="Value">false</B></En>
              <En><S N="Key">path</S><S N="Value">\\192.168.1.1\anime\b.mkv</S></En>
              <En><S N="Key">length</S><I64 N="Value">20</I64></En>
              <En><S N="Key">hash</S><S N="Value">BBB</S></En>
              <En><S N="Key">error</S><S N="Value">access denied</S></En>
            </DCT>
          </Obj>
        </LST>
      </Obj>
    </MS>
  </Obj>
</Objs>`

	const xmlNoItems = `<?xml version="1.0" encoding="utf-8"?>
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">
  <Obj RefId="0">
    <MS>
      <S N="algorithm">SHA1</S>
      <S N="root">\\server\share</S>
      <I32 N="total">0</I32>
      <!-- no <Obj N="items"> -->
    </MS>
  </Obj>
</Objs>`

	const xmlNoTopLevel = `<?xml version="1.0" encoding="utf-8"?>
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">
</Objs>`

	tests := []struct {
		name        string
		xml         string
		wantErr     bool
		wantAlg     string
		wantMetaKey string
		wantMetaVal any
		wantItems   []index.FileItem
		wantTotalB  int64
	}{
		{
			name:        "parses items and sums TotalBytes excluding errored items",
			xml:         xmlWithItems,
			wantErr:     false,
			wantAlg:     "SHA256",
			wantMetaKey: "root",
			wantMetaVal: `\\192.168.1.1\anime`,
			wantItems: []index.FileItem{
				{Ok: true, Path: `\\192.168.1.1\anime\a.mkv`, Length: 10, Hash: "AAA", Error: nil},
				{Ok: false, Path: `\\192.168.1.1\anime\b.mkv`, Length: 20, Hash: "BBB", Error: strPtr("access denied")},
			},
			wantTotalB: 10,
		},
		{
			name:        "no items object returns empty slice and TotalBytes=0",
			xml:         xmlNoItems,
			wantErr:     false,
			wantAlg:     "SHA1",
			wantMetaKey: "root",
			wantMetaVal: `\\server\share`,
			wantItems:   []index.FileItem{},
			wantTotalB:  0,
		},
		{
			name:    "no top-level objects returns error",
			xml:     xmlNoTopLevel,
			wantErr: true,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			p := writeTempCLIXML(t, tt.xml)

			run, items, err := index.Load(p)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if run.Algorithm != tt.wantAlg {
				t.Fatalf("Algorithm mismatch: got %q want %q", run.Algorithm, tt.wantAlg)
			}

			if tt.wantMetaKey != "" {
				got, ok := run.Meta[tt.wantMetaKey]
				if !ok {
					t.Fatalf("Meta missing key %q", tt.wantMetaKey)
				}
				if got != tt.wantMetaVal {
					t.Fatalf("Meta[%q] mismatch: got %#v want %#v", tt.wantMetaKey, got, tt.wantMetaVal)
				}
			}

			if run.TotalBytes != tt.wantTotalB {
				t.Fatalf("TotalBytes mismatch: got %d want %d", run.TotalBytes, tt.wantTotalB)
			}

			if len(items) != len(tt.wantItems) {
				t.Fatalf("items length mismatch: got %d want %d", len(items), len(tt.wantItems))
			}

			for i := range tt.wantItems {
				got := items[i]
				want := tt.wantItems[i]

				if got.Ok != want.Ok || got.Path != want.Path || got.Length != want.Length || got.Hash != want.Hash {
					t.Fatalf("item[%d] mismatch:\n got:  %+v\n want: %+v", i, got, want)
				}

				if (got.Error == nil) != (want.Error == nil) {
					t.Fatalf("item[%d] Error nil mismatch: got=%v want=%v", i, got.Error == nil, want.Error == nil)
				}
				if got.Error != nil && want.Error != nil && *got.Error != *want.Error {
					t.Fatalf("item[%d] Error mismatch: got=%q want=%q", i, *got.Error, *want.Error)
				}
			}
		})
	}
}
