package config

import (
	"errors"
	"flag"
	"sync"
)

type Config struct {
	ResultsDir          string
	StartTimestamp      string
	CompletionTimestamp string
}

var (
	cfg  = Config{}
	once sync.Once
)

func GetConfig() Config {
	once.Do(func() {
		flag.StringVar(&cfg.ResultsDir, "results-dir", "", "Directory to read the result files from")
		flag.StringVar(&cfg.StartTimestamp, "start-timestamp", "", "test start timestamp")
		flag.StringVar(&cfg.CompletionTimestamp, "completion-timestamp", "", "test completion timestamp")
		flag.Parse()
	})
	return cfg
}

func (c Config) Validate() error {
	if c.ResultsDir == "" {
		return errors.New("results-dir flag is required")
	}
	if c.StartTimestamp == "" {
		return errors.New("start-timestamp flag is required")
	}
	if c.CompletionTimestamp == "" {
		return errors.New("completion-timestamp flag is required")
	}

	return nil
}
