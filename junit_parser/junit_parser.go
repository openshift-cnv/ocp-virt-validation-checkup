package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"junitparser/config"
	"junitparser/configmap"
	"junitparser/junit_parser/junit"
	"junitparser/k8s"
	"junitparser/result"
)

func main() {
	cfg := config.GetConfig()
	err := cfg.Validate()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	junitRes, err := junit.NewResultMap(cfg.ResultsDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "unexpected error occurred; %v\n", err)
		os.Exit(1)
	}

	testRes := result.New(junitRes)

	fmt.Print(testRes)

	if testRes.SetupFailure && len(testRes.SigMap) == 0 {
		fmt.Fprintln(os.Stderr, "Skipping ConfigMap creation: no tests were executed due to setup failure")
		os.Exit(1)
	}

	resYaml, err := testRes.GetYaml()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to get yaml: %v\n", err)
		os.Exit(1)
	}

	cm, err := configmap.New(cfg, resYaml)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	err = k8s.CreateCM(ctx, cm)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create configmap: %v\n", err)
		os.Exit(1)
	}
}
