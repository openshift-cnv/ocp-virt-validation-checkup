package k8s

import (
	"context"
	"fmt"
	"os"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func getConfig() (*rest.Config, error) {
	var (
		config *rest.Config
		err    error
	)

	if _, inCluster := os.LookupEnv("KUBERNETES_SERVICE_HOST"); inCluster {
		// Use in-cluster configuration
		config, err = rest.InClusterConfig()
		if err != nil {
			return nil, fmt.Errorf("failed to create in-cluster config: %w", err)
		}
	} else {
		// Use kubeconfig from environment variable or default path
		kubeconfig := os.Getenv("KUBECONFIG")
		if kubeconfig == "" {
			kubeconfig = clientcmd.RecommendedHomeFile
		}
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err != nil {
			return nil, fmt.Errorf("failed to build kubeconfig: %w", err)
		}
	}

	return config, nil
}

func CreateCM(ctx context.Context, cm *corev1.ConfigMap) error {
	config, err := getConfig()
	if err != nil {
		return fmt.Errorf("failed to get config: %v", err)
	}

	cli, err := kubernetes.NewForConfig(config)
	if err != nil {
		return fmt.Errorf("failed to create client: %v", err)
	}

	_, err = cli.CoreV1().ConfigMaps(cm.Namespace).Create(ctx, cm, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("failed to create configmap: %v", err)
	}

	return nil
}
