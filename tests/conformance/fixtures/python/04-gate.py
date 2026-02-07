from sykli import Pipeline

p = Pipeline()

p.task("build").run("make build")

p.gate("approve-deploy").after("build") \
    .gate_strategy("env") \
    .gate_timeout(600) \
    .gate_message("Approve deployment to production?") \
    .gate_env_var("DEPLOY_APPROVED")

p.task("deploy").run("make deploy").after("approve-deploy")

p.emit()
