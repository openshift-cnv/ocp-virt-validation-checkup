package result_test

import (
	"encoding/json"
	"junitparser/junit"
	"junitparser/result"
	"testing"
)

func TestCreatesResultWithValidJUnitResults(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"sig1": {
			Tests:    5,
			Failures: 1,
			Skipped:  1,
			Disabled: 0,
			TestCases: []junit.TestCase{
				{Name: "test1", Failure: true},
				{Name: "test2"},
			},
		},
		"sig2": {
			Tests:    3,
			Failures: 0,
			Skipped:  0,
			Disabled: 0,
		},
	}

	res := result.New(junitResults)

	if len(res.SigMap) != 2 {
		t.Errorf("expected 2 sigs, got %d", len(res.SigMap))
	}

	sig1 := res.SigMap["sig1"]
	if sig1.Run != 5 {
		t.Errorf("expected 5 tests run for sig1, got %d", sig1.Run)
	}
	if sig1.Passed != 4 {
		t.Errorf("expected 3 tests passed for sig1, got %d", sig1.Passed)
	}
	if sig1.Failures != 1 {
		t.Errorf("expected 1 failure for sig1, got %d", sig1.Failures)
	}
	if len(sig1.FailedTests) != 1 || sig1.FailedTests[0] != "test1" {
		t.Errorf("expected failed test 'test1' for sig1, got %v", sig1.FailedTests)
	}

	sig2 := res.SigMap["sig2"]
	if sig2.Run != 3 {
		t.Errorf("expected 3 tests run for sig2, got %d", sig2.Run)
	}
	if sig2.Passed != 3 {
		t.Errorf("expected 3 tests passed for sig2, got %d", sig2.Passed)
	}
	if sig2.Failures != 0 {
		t.Errorf("expected 0 failures for sig2, got %d", sig2.Failures)
	}
}

func TestHandlesEmptyJUnitResults(t *testing.T) {
	junitResults := map[string]junit.TestSuite{}

	res := result.New(junitResults)

	if len(res.SigMap) != 0 {
		t.Errorf("expected 0 sigs, got %d", len(res.SigMap))
	}
	if res.Summary.Run != 0 {
		t.Errorf("expected 0 total tests run, got %d", res.Summary.Run)
	}
	if res.Summary.Passed != 0 {
		t.Errorf("expected 0 total tests passed, got %d", res.Summary.Passed)
	}
	if res.Summary.Failed != 0 {
		t.Errorf("expected 0 total tests failed, got %d", res.Summary.Failed)
	}
}

func TestHandlesSpecialSigLogicForSSP(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"ssp": {
			Tests:    4,
			Failures: 1,
			Skipped:  2,
			Disabled: 0,
		},
	}

	res := result.New(junitResults)

	sig := res.SigMap["ssp"]
	if sig.Run != 4 {
		t.Errorf("expected 4 tests run for ssp, got %d", sig.Run)
	}
	if sig.Passed != 1 {
		t.Errorf("expected 1 test passed for ssp (excluding skipped), got %d", sig.Passed)
	}
	if sig.Failures != 1 {
		t.Errorf("expected 1 failure for ssp, got %d", sig.Failures)
	}
}

func TestMarshalsResultToJSONCorrectly(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"sig1": {
			Tests:    2,
			Failures: 1,
			Skipped:  0,
			Disabled: 0,
			TestCases: []junit.TestCase{
				{Name: "test1", Failure: true},
			},
		},
	}

	res := result.New(junitResults)
	jsonData, err := json.Marshal(res)
	if err != nil {
		t.Fatalf("unexpected error marshaling result to JSON: %v", err)
	}

	expected := `{"sig1":{"tests_run":2,"tests_passed":1,"tests_failures":1,"tests_skipped":0,"failed_tests":["test1"]},"summary":{"total_tests_run":2,"total_tests_passed":1,"total_tests_failed":1}}`
	if string(jsonData) != expected {
		t.Errorf("expected JSON %s, got %s", expected, string(jsonData))
	}
}

func TestConvertsResultToYAMLCorrectly(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"sig1": {
			Tests:    2,
			Failures: 1,
			Skipped:  0,
			Disabled: 0,
			TestCases: []junit.TestCase{
				{Name: "test1", Failure: true},
			},
		},
	}

	res := result.New(junitResults)
	yamlData, err := res.GetYaml()
	if err != nil {
		t.Fatalf("unexpected error converting result to YAML: %v", err)
	}

	expected := `sig1:
  failed_tests:
  - test1
  tests_failures: 1
  tests_passed: 1
  tests_run: 2
  tests_skipped: 0
summary:
  total_tests_failed: 1
  total_tests_passed: 1
  total_tests_run: 2
`

	if string(yamlData) != expected {
		t.Errorf("expected YAML:\n%s\n\ngot:\n%s", expected, string(yamlData))
	}
}
