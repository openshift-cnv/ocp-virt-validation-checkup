package junit

import (
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"
)

const junitFileName = "junit.results.xml"

func NewResultMap(dir string) (map[string]TestSuite, error) {
	type resultWithSig struct {
		sig         string
		junitResult TestSuite
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}

	wg := &sync.WaitGroup{}

	ch := make(chan resultWithSig, 1)

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		// Skip the lost+found directory
		if entry.Name() == "lost+found" {
			continue
		}

		// Skip the .dry-run directory (used by progress_watcher for test discovery)
		if entry.Name() == ".dry-run" {
			continue
		}

		wg.Add(1)

		go func(sig string) {
			defer wg.Done()
			sigDir := path.Join(dir, sig)
			exitCode := readExitCode(path.Join(sigDir, ".exit_code"))

			fileName := path.Join(sigDir, junitFileName)
			junitResult, err := readOneFile(fileName)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				if exitCode != 0 {
					ch <- resultWithSig{sig: sig, junitResult: TestSuite{SetupFailure: true}}
				}
				return
			}

			// Split Tier-2 path+Windows runs record per-phase exits/JUnit. Assess
			// each phase so a Windows test failure cannot mask a path setup failure.
			if hasSplitPhaseArtifacts(sigDir) {
				if phaseSetupFailure(readExitCode(path.Join(sigDir, ".exit_code_phase1")), path.Join(sigDir, "junit.phase1.xml")) ||
					phaseSetupFailure(readExitCode(path.Join(sigDir, ".exit_code_windows")), path.Join(sigDir, "junit.windows.xml")) {
					junitResult.SetupFailure = true
				}
			} else if exitCode != 0 && junitResult.Failures == 0 && junitResult.Errors == 0 {
				junitResult.SetupFailure = true
			}

			ch <- resultWithSig{sig: sig, junitResult: junitResult}
		}(entry.Name())
	}

	go func() {
		wg.Wait()
		close(ch)
	}()

	junitResults := make(map[string]TestSuite)
	for res := range ch {
		junitResults[res.sig] = res.junitResult
	}

	return junitResults, nil
}

func readExitCode(filePath string) int {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return 0
	}
	code, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return 0
	}
	return code
}

func hasSplitPhaseArtifacts(sigDir string) bool {
	_, errPhase1 := os.Stat(path.Join(sigDir, ".exit_code_phase1"))
	_, errWindows := os.Stat(path.Join(sigDir, ".exit_code_windows"))
	return errPhase1 == nil || errWindows == nil
}

// phaseSetupFailure is true when a phase exited nonzero without reporting test
// failures/errors (missing JUnit counts as a setup failure).
func phaseSetupFailure(exitCode int, junitPath string) bool {
	if exitCode == 0 {
		return false
	}
	suite, err := readOneFile(junitPath)
	if err != nil {
		return true
	}
	return suite.Failures == 0 && suite.Errors == 0
}

func readOneFile(fileName string) (TestSuite, error) {
	junitFile, err := os.Open(fileName)
	if err != nil {
		if os.IsNotExist(err) {
			return TestSuite{}, fmt.Errorf("junit file %q does not exist", fileName)
		}
		return TestSuite{}, fmt.Errorf("unknow error while opening %s; %w", fileName, err)
	}

	defer junitFile.Close()

	testSuite, err := readTestSuite(junitFile)
	if err != nil {
		return testSuite, fmt.Errorf("failed to parse junit file: %s; %v", fileName, err)
	}

	return testSuite, nil
}

func readTestSuite(reader io.Reader) (TestSuite, error) {
	testSuites := TestSuites{}
	xmlContent, err := io.ReadAll(reader)
	if err != nil {
		return TestSuite{}, err
	}

	err = xml.Unmarshal(xmlContent, &testSuites)
	if err != nil {
		var expErr xml.UnmarshalError
		if errors.As(err, &expErr) {
			testSuite := TestSuite{}
			err = xml.Unmarshal(xmlContent, &testSuite)
			if err != nil {
				return TestSuite{}, err
			}
			return testSuite, nil
		}
		return TestSuite{}, err
	}

	return aggregateTestSuites(testSuites.TestSuites), nil
}

// aggregateTestSuites merges every child suite into one summary suite so
// multi-phase JUnit reports (e.g. path + Windows) keep all cases and counts.
func aggregateTestSuites(suites []TestSuite) TestSuite {
	if len(suites) == 0 {
		return TestSuite{}
	}
	if len(suites) == 1 {
		return suites[0]
	}

	out := TestSuite{Name: suites[0].Name}
	for _, suite := range suites {
		out.Tests += suite.Tests
		out.Failures += suite.Failures
		out.Errors += suite.Errors
		out.Skipped += suite.Skipped
		out.Disabled += suite.Disabled
		out.Time += suite.Time
		out.TestCases = append(out.TestCases, suite.TestCases...)
		if suite.SetupFailure {
			out.SetupFailure = true
		}
	}
	return out
}
