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
	// Get namespace from environment variable with default fallback
	namespace := os.Getenv("CONFIGMAP_NAMESPACE")
	if namespace == "" {
		namespace = appName
	}

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: namespace,
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

	// Get configmap name from environment variable with default fallback
	configMapName := os.Getenv("CONFIGMAP_NAME")
	ts := os.Getenv("TIMESTAMP")

	if configMapName != "" {
		// Use custom configmap name
		cm.ObjectMeta.Name = configMapName
	} else {
		// Use default naming logic
		if ts == "" {
			cm.ObjectMeta.GenerateName = cmNamePrefix
		} else {
			cm.ObjectMeta.Name = cmNamePrefix + ts
		}
	}

	return cm, nil
}
