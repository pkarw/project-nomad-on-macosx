package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRuntimeName(t *testing.T) {
	cases := []struct {
		label     string
		contents  string
		missing   bool
		want      string
		wantError bool
	}{
		{label: "legacy workspace", missing: true, want: "nomad-x5"},
		{label: "independent installation", contents: "nomad-12ab34cd56ef7890\n", want: "nomad-12ab34cd56ef7890"},
		{label: "empty id", contents: "", wantError: true},
		{label: "prefix only", contents: "nomad-", wantError: true},
		{label: "invalid name", contents: "../../nomad-x5", wantError: true},
	}
	for _, scenario := range cases {
		t.Run(scenario.label, func(t *testing.T) {
			workspace := t.TempDir()
			if !scenario.missing {
				if err := os.WriteFile(filepath.Join(workspace, "runtime-id"), []byte(scenario.contents), 0600); err != nil {
					t.Fatal(err)
				}
			}
			got, err := runtimeName(workspace)
			if (err != nil) != scenario.wantError {
				t.Fatalf("error = %v, wantError %v", err, scenario.wantError)
			}
			if got != scenario.want {
				t.Fatalf("name = %q, want %q", got, scenario.want)
			}
		})
	}
}
