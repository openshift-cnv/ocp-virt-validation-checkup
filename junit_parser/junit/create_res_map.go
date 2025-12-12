package junit

import (
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
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
			fileName := path.Join(dir, sig, junitFileName)
			junitResult, err := readOneFile(fileName)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				return
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

	if len(testSuites.TestSuites) == 0 {
		return TestSuite{}, nil
	}

	return testSuites.TestSuites[0], nil
}
