package result

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"sigs.k8s.io/yaml"

	"junitparser/junit_parser/junit"
)

// Result represents the result of a test run, including a map of test suite results and a summary.
type Result struct {
	SigMap  SigMap  `json:",omitempty,inline"`
	Summary Summary `json:"summary,omitempty"`
}

// New creates a new Result struct from the given map of JUnit test results.
func New(junitResults map[string]junit.TestSuite) Result {
	res := Result{
		SigMap: make(SigMap),
	}

	for sig, testSuite := range junitResults {
		skipped := testSuite.Skipped + testSuite.Disabled
		passed := testSuite.Tests - testSuite.Failures
		if sig == "ssp" {
			passed -= skipped
		}

		sigRes := Sig{
			Run:      testSuite.Tests,
			Passed:   passed,
			Failures: testSuite.Failures,
			Skipped:  skipped,
		}

		if testSuite.Failures > 0 {
			var failedTests []string
			for _, testCase := range testSuite.TestCases {
				if testCase.Failure || testCase.Error {
					failedTests = append(failedTests, testCase.Name)
				}
			}

			sigRes.FailedTests = failedTests
		}

		res.SigMap[sig] = sigRes
		res.Summary.Run += testSuite.Tests
		res.Summary.Passed += passed
		res.Summary.Failed += testSuite.Failures
	}

	return res
}

// SigMap is a map of test suite names to their corresponding Sig results.
type SigMap map[string]Sig

// Sig represents the result of a test suite, including the number of tests run, passed, failed, and skipped.
type Sig struct {
	Run         int      `json:"tests_run"`
	Passed      int      `json:"tests_passed"`
	Failures    int      `json:"tests_failures"`
	Skipped     int      `json:"tests_skipped"`
	FailedTests []string `json:"failed_tests,omitempty"`
}

type Summary struct {
	Run    int `json:"total_tests_run"`
	Passed int `json:"total_tests_passed"`
	Failed int `json:"total_tests_failed"`
}

// MarshalJSON implements the json.Marshaler interface for Result, to make the SigMap's Sigs field inline in the
// JSON output.
func (r Result) MarshalJSON() ([]byte, error) {
	type Alias Result
	alias := Alias(r)

	// Marshal the SigMap's Sigs field inline
	sigMapJSON, err := json.Marshal(r.SigMap)
	if err != nil {
		return nil, err
	}

	alias.SigMap = nil
	// Marshal the rest of the Result struct
	aliasJSON, err := json.Marshal(alias)
	if err != nil {
		return nil, err
	}

	// Combine the two JSON objects
	var resultJSON []byte
	if len(sigMapJSON) > 0 {
		resultJSON = append(sigMapJSON[:len(sigMapJSON)-1], ',')
	}
	resultJSON = append(resultJSON, aliasJSON[1:]...) // Remove the opening brace from aliasJSON

	return resultJSON, nil
}

// String implements the Stringer interface for Result, to provide a human-readable summary of the test results.
func (r Result) String() string {
	sb := strings.Builder{}
	for sig, sigRes := range r.SigMap {
		// Print summary for suite
		header := "Summary for " + sig
		seperator := strings.Repeat("=", len(header))

		sb.WriteString(seperator + "\n")
		sb.WriteString(header + "\n")
		sb.WriteString(seperator + "\n")

		sb.WriteString(fmt.Sprintf("Tests Run: %d\n", sigRes.Run))
		sb.WriteString(fmt.Sprintf("Tests Passed: %d\n", sigRes.Passed))
		sb.WriteString(fmt.Sprintf("Tests Failed: %d\n", sigRes.Failures))
		sb.WriteString(fmt.Sprintf("Tests Skipped: %d\n", sigRes.Skipped))

		if len(sigRes.FailedTests) > 0 {
			sb.WriteString("Failed Tests:\n")
			for _, testName := range sigRes.FailedTests {
				sb.WriteString(fmt.Sprintf("  - %s\n", testName))
			}
		}
	}

	header := fmt.Sprintf("Total Summary for execution from %s", os.Getenv("TIMESTAMP"))
	seperator := strings.Repeat("=", len(header))
	sb.WriteString(seperator + "\n")
	sb.WriteString(header + "\n")
	sb.WriteString(seperator + "\n")
	sb.WriteString(fmt.Sprintf("Total Tests Run: %d\n", r.Summary.Run))
	sb.WriteString(fmt.Sprintf("Total Tests Passed: %d\n", r.Summary.Passed))
	sb.WriteString(fmt.Sprintf("Total Tests Failed: %d\n", r.Summary.Failed))

	return sb.String()
}

// GetYaml converts the Result struct to YAML format.
func (r Result) GetYaml() ([]byte, error) {
	resJson, err := json.Marshal(r)
	if err != nil {
		return nil, fmt.Errorf("failed to encode result: %w", err)
	}

	resForYaml := make(map[string]any)
	err = json.Unmarshal(resJson, &resForYaml)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal result for yaml: %w", err)
	}

	resYaml, err := yaml.Marshal(resForYaml)
	if err != nil {
		return nil, fmt.Errorf("failed to encode result for yaml: %w", err)
	}

	return resYaml, nil
}
