package configmap

import (
	"context"
	"fmt"
	"os"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"

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

	// Add owner reference to the job if available
	if err := addJobOwnerReference(cm, namespace, ts); err != nil {
		// Log the error but don't fail - owner reference is optional
		fmt.Fprintf(os.Stderr, "Warning: Could not add owner reference to ConfigMap: %v\n", err)
	}

	return cm, nil
}

// addJobOwnerReference adds an owner reference to the job that created this ConfigMap
func addJobOwnerReference(cm *corev1.ConfigMap, namespace, timestamp string) error {
	// Get pod name from environment variable
	podName := os.Getenv("POD_NAME")
	if podName == "" {
		return fmt.Errorf("POD_NAME environment variable not set")
	}

	// Create in-cluster config
	config, err := rest.InClusterConfig()
	if err != nil {
		return fmt.Errorf("failed to get in-cluster config: %w", err)
	}

	// Create clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return fmt.Errorf("failed to create kubernetes client: %w", err)
	}

	// Get the pod to find its owner (the Job)
	pod, err := clientset.CoreV1().Pods(namespace).Get(context.TODO(), podName, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("failed to get pod %s: %w", podName, err)
	}

	// Find the Job owner reference
	var jobOwnerRef *metav1.OwnerReference
	for i := range pod.OwnerReferences {
		if pod.OwnerReferences[i].Kind == "Job" {
			jobOwnerRef = &pod.OwnerReferences[i]
			break
		}
	}

	if jobOwnerRef == nil {
		return fmt.Errorf("pod %s does not have a Job owner reference", podName)
	}

	// Add owner reference to ConfigMap
	trueVal := true
	cm.ObjectMeta.OwnerReferences = []metav1.OwnerReference{
		{
			APIVersion:         jobOwnerRef.APIVersion,
			Kind:               jobOwnerRef.Kind,
			Name:               jobOwnerRef.Name,
			UID:                jobOwnerRef.UID,
			Controller:         &trueVal,
			BlockOwnerDeletion: &trueVal,
		},
	}

	return nil
}
