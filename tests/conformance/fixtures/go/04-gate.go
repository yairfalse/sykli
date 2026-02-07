package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("build").Run("make build")

	p.Gate("approve-deploy").After("build").
		GateStrategy("env").
		GateTimeout(600).
		GateMessage("Approve deployment to production?").
		GateEnvVar("DEPLOY_APPROVED")

	p.Task("deploy").Run("make deploy").After("approve-deploy")

	p.Emit()
}
