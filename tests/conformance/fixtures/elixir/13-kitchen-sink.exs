use Sykli

pipeline do
  task "lint" do
    run "golangci-lint run"
    inputs ["**/*.go"]
    timeout 60
    set_criticality :low
    on_fail :skip
  end

  task "test" do
    run "go test ./..."
    after_ ["lint"]
    inputs ["**/*.go", "go.mod"]
    env "CGO_ENABLED", "0"
    retry 2
    timeout 300
    secrets ["CODECOV_TOKEN"]
    matrix "go_version", ["1.21", "1.22"]
    service "postgres:15", "db"
    covers ["src/**/*.go"]
    intent "unit tests for all packages"
    set_criticality :high
    on_fail :analyze
    select_mode :smart
  end

  task "build" do
    run "go build -o /out/app"
    after_ ["test"]
    output "binary", "/out/app"
    provides "binary", "/out/app"
    k8s Sykli.K8s.options() |> Sykli.K8s.memory("4Gi") |> Sykli.K8s.cpu("2")
    requires ["docker"]
  end

  gate "approve-deploy" do
    after_ ["build"]
    gate_strategy "env"
    gate_timeout 1800
    gate_message "Deploy to production?"
    gate_env_var "DEPLOY_APPROVED"
  end

  task "deploy" do
    run "kubectl apply -f k8s/"
    after_ ["approve-deploy"]
    needs ["binary"]
    secret_from "kube_config", Sykli.SecretRef.from_file("/home/.kube/config")
    secret_from "registry_pass", Sykli.SecretRef.from_vault("secret/data/registry#password")
    when_ "branch:main"
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
