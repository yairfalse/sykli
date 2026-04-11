use sykli::{Pipeline, K8sOptions, SecretRef, Criticality, OnFailAction, SelectMode};

fn main() {
    let mut p = Pipeline::new();

    p.task("lint").run("golangci-lint run")
        .inputs(&["**/*.go"])
        .timeout(60)
        .set_criticality(Criticality::Low)
        .on_fail(OnFailAction::Skip);

    p.task("test").run("go test ./...")
        .after(&["lint"])
        .inputs(&["**/*.go", "go.mod"])
        .env("CGO_ENABLED", "0")
        .retry(2)
        .timeout(300)
        .secrets(&["CODECOV_TOKEN"])
        .matrix("go_version", &["1.21", "1.22"])
        .service("postgres:15", "db")
        .covers(&["src/**/*.go"])
        .intent("unit tests for all packages")
        .set_criticality(Criticality::High)
        .on_fail(OnFailAction::Analyze)
        .select_mode(SelectMode::Smart);

    p.task("build").run("go build -o /out/app")
        .after(&["test"])
        .output("binary", "/out/app")
        .provides("binary", Some("/out/app"))
        .k8s(K8sOptions { memory: Some("4Gi".into()), cpu: Some("2".into()), gpu: None })
        .target("docker")
        .requires(&["docker"]);

    p.gate("approve-deploy").after(&["build"])
        .gate_strategy("env")
        .gate_timeout(1800)
        .gate_message("Deploy to production?")
        .gate_env_var("DEPLOY_APPROVED");

    p.task("deploy").run("kubectl apply -f k8s/")
        .after(&["approve-deploy"])
        .needs(&["binary"])
        .secret_from("kube_config", SecretRef::from_file("/home/.kube/config"))
        .secret_from("registry_pass", SecretRef::from_vault("secret/data/registry#password"))
        .when("branch:main");

    p.emit();
}
