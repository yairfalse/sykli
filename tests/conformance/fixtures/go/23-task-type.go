package main

import sykli "github.com/false-systems/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("build").Run("echo build").TaskType(sykli.TaskTypeBuild)
	p.Task("test").Run("echo test").TaskType(sykli.TaskTypeTest).After("build")
	p.Task("lint").Run("echo lint").TaskType(sykli.TaskTypeLint).After("test")
	p.Task("format").Run("echo format").TaskType(sykli.TaskTypeFormat).After("lint")
	p.Task("scan").Run("echo scan").TaskType(sykli.TaskTypeScan).After("format")
	p.Task("package").Run("echo package").TaskType(sykli.TaskTypePackage).After("scan")
	p.Task("publish").Run("echo publish").TaskType(sykli.TaskTypePublish).After("package")
	p.Task("deploy").Run("echo deploy").TaskType(sykli.TaskTypeDeploy).After("publish")
	p.Task("migrate").Run("echo migrate").TaskType(sykli.TaskTypeMigrate).After("deploy")
	p.Task("generate").Run("echo generate").TaskType(sykli.TaskTypeGenerate).After("migrate")
	p.Task("verify").Run("echo verify").TaskType(sykli.TaskTypeVerify).After("generate")
	p.Task("cleanup").Run("echo cleanup").TaskType(sykli.TaskTypeCleanup).After("verify")

	p.Emit()
}
