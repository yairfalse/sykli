package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("train").Run("python train.py").
		K8s(sykli.K8sOptions{Memory: "32Gi", CPU: "4", GPU: 2})

	p.Emit()
}
