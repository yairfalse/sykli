package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("lint").Run("golangci-lint run").
		Inputs("**/*.go").
		Timeout(60).
		SetCriticality("low").
		OnFail("skip")

	p.Task("test").Run("go test ./...").
		After("lint").
		Inputs("**/*.go", "go.mod").
		Env("CGO_ENABLED", "0").
		Retry(2).
		Timeout(300).
		Secrets("CODECOV_TOKEN").
		Matrix("go_version", "1.21", "1.22").
		Service("postgres:15", "db").
		Covers("src/**/*.go").
		Intent("unit tests for all packages").
		SetCriticality("high").
		OnFail("analyze").
		SelectMode("smart")

	p.Task("build").Run("go build -o /out/app").
		After("test").
		Output("binary", "/out/app").
		Provides("binary", "/out/app").
		K8s(sykli.K8sOptions{Memory: "4Gi", CPU: "2"}).
		Target("docker").
		Requires("docker")

	p.Gate("approve-deploy").After("build").
		GateStrategy("env").
		GateTimeout(1800).
		GateMessage("Deploy to production?").
		GateEnvVar("DEPLOY_APPROVED")

	p.Task("deploy").Run("kubectl apply -f k8s/").
		After("approve-deploy").
		Needs("binary").
		SecretFrom("kube_config", sykli.FromFile("/home/.kube/config")).
		SecretFrom("registry_pass", sykli.FromVault("secret/data/registry#password")).
		When("branch:main")

	p.Emit()
}
