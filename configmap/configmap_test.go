package configmap

import (
	"os"
	"testing"

	"junitparser/config"
)

func TestNew(t *testing.T) {
	tests := []struct {
		name          string
		cfg           config.Config
		result        []byte
		envTimestamp  string
		expectedName  string
		expectedError bool
	}{
		{
			name: "valid config with TIMESTAMP set",
			cfg: config.Config{
				StartTimestamp:      "2023-01-01T00:00:00Z",
				CompletionTimestamp: "2023-01-01T01:00:00Z",
			},
			result:        []byte("test results"),
			envTimestamp:  "20230101",
			expectedName:  "ocp-virt-validation-20230101",
			expectedError: false,
		},
		{
			name: "valid config without TIMESTAMP",
			cfg: config.Config{
				StartTimestamp:      "2023-01-01T00:00:00Z",
				CompletionTimestamp: "2023-01-01T01:00:00Z",
			},
			result:        []byte("test results"),
			envTimestamp:  "",
			expectedName:  "",
			expectedError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Set up environment variable
			if tt.envTimestamp != "" {
				os.Setenv("TIMESTAMP", tt.envTimestamp)
			} else {
				os.Unsetenv("TIMESTAMP")
			}

			cm, err := New(tt.cfg, tt.result)
			if (err != nil) != tt.expectedError {
				t.Errorf("New() error = %v, expectedError %v", err, tt.expectedError)
			}

			if cm == nil {
				t.Fatalf("expected ConfigMap, got nil")
			}

			if tt.envTimestamp == "" {
				if cm.ObjectMeta.GenerateName != "ocp-virt-validation-" {
					t.Errorf("expected GenerateName to be 'ocp-virt-validation-', got '%s'", cm.ObjectMeta.GenerateName)
				}
			} else {
				if cm.ObjectMeta.Name != tt.expectedName {
					t.Errorf("expected Name to be '%s', got '%s'", tt.expectedName, cm.ObjectMeta.Name)
				}
			}

			if cm.Data["self-validation-results"] != string(tt.result) {
				t.Errorf("expected self-validation-results to be '%s', got '%s'", string(tt.result), cm.Data["self-validation-results"])
			}

			if cm.Data["status.startTimestamp"] != tt.cfg.StartTimestamp {
				t.Errorf("expected status.startTimestamp to be '%s', got '%s'", tt.cfg.StartTimestamp, cm.Data["status.startTimestamp"])
			}

			if cm.Data["status.completionTimestamp"] != tt.cfg.CompletionTimestamp {
				t.Errorf("expected status.completionTimestamp to be '%s', got '%s'", tt.cfg.CompletionTimestamp, cm.Data["status.completionTimestamp"])
			}
		})
	}
}
