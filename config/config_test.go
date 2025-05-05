package config

import (
	"flag"
	"os"
	"sync"
	"testing"
)

func TestGetConfig(t *testing.T) {
	// Reset flags for testing
	flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ExitOnError)

	// Set test flags
	once = sync.Once{} // reset the once variable
	os.Args = []string{"cmd", "-results-dir=/tmp/results", "-start-timestamp=2023-01-01T00:00:00Z", "-completion-timestamp=2023-01-01T01:00:00Z"}
	cfg := GetConfig()

	if cfg.ResultsDir != "/tmp/results" {
		t.Errorf("expected ResultsDir to be '/tmp/results', got '%s'", cfg.ResultsDir)
	}
	if cfg.StartTimestamp != "2023-01-01T00:00:00Z" {
		t.Errorf("expected StartTimestamp to be '2023-01-01T00:00:00Z', got '%s'", cfg.StartTimestamp)
	}
	if cfg.CompletionTimestamp != "2023-01-01T01:00:00Z" {
		t.Errorf("expected CompletionTimestamp to be '2023-01-01T01:00:00Z', got '%s'", cfg.CompletionTimestamp)
	}
}

func TestValidate(t *testing.T) {
	tests := []struct {
		name    string
		config  Config
		wantErr bool
	}{
		{
			name: "valid config",
			config: Config{
				ResultsDir:          "/tmp/results",
				StartTimestamp:      "2023-01-01T00:00:00Z",
				CompletionTimestamp: "2023-01-01T01:00:00Z",
			},
			wantErr: false,
		},
		{
			name: "missing ResultsDir",
			config: Config{
				StartTimestamp:      "2023-01-01T00:00:00Z",
				CompletionTimestamp: "2023-01-01T01:00:00Z",
			},
			wantErr: true,
		},
		{
			name: "missing StartTimestamp",
			config: Config{
				ResultsDir:          "/tmp/results",
				CompletionTimestamp: "2023-01-01T01:00:00Z",
			},
			wantErr: true,
		},
		{
			name: "missing CompletionTimestamp",
			config: Config{
				ResultsDir:     "/tmp/results",
				StartTimestamp: "2023-01-01T00:00:00Z",
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.config.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
