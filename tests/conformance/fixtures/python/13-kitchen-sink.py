from sykli import Pipeline, K8sOptions, from_file, from_vault

p = Pipeline()

p.task("lint").run("golangci-lint run") \
    .inputs("**/*.go") \
    .timeout(60) \
    .set_criticality("low") \
    .on_fail("skip")

p.task("test").run("go test ./...") \
    .after("lint") \
    .inputs("**/*.go", "go.mod") \
    .env("CGO_ENABLED", "0") \
    .retry(2) \
    .timeout(300) \
    .secrets("CODECOV_TOKEN") \
    .matrix("go_version", "1.21", "1.22") \
    .service("postgres:15", "db") \
    .covers("src/**/*.go") \
    .intent("unit tests for all packages") \
    .set_criticality("high") \
    .on_fail("analyze") \
    .select_mode("smart")

p.task("build").run("go build -o /out/app") \
    .after("test") \
    .output("binary", "/out/app") \
    .provides("binary", "/out/app") \
    .k8s(K8sOptions(memory="4Gi", cpu="2")) \
    .target("docker") \
    .requires("docker")

p.gate("approve-deploy").after("build") \
    .gate_strategy("env") \
    .gate_timeout(1800) \
    .gate_message("Deploy to production?") \
    .gate_env_var("DEPLOY_APPROVED")

p.task("deploy").run("kubectl apply -f k8s/") \
    .after("approve-deploy") \
    .needs("binary") \
    .secret_from("kube_config", from_file("kube_config", "/home/.kube/config")) \
    .secret_from("registry_pass", from_vault("registry_pass", "secret/data/registry#password")) \
    .when("branch:main")

p.emit()
