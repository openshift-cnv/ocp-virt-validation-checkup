package configmap

import (
	"os"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"junitparser/config"
)

const (
	appName      = "ocp-virt-validation"
	cmNamePrefix = appName + "-"
)

func New(cfg config.Config, result []byte) (*corev1.ConfigMap, error) {
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: appName,
			Labels: map[string]string{
				"app": appName,
			},
		},
		Data: map[string]string{
			"self-validation-results":    string(result),
			"status.startTimestamp":      cfg.StartTimestamp,
			"status.completionTimestamp": cfg.CompletionTimestamp,
		},
	}

	ts := os.Getenv("TIMESTAMP")
	if ts == "" {
		cm.ObjectMeta.GenerateName = cmNamePrefix
	} else {
		cm.ObjectMeta.Name = cmNamePrefix + ts
	}

	return cm, nil
}
