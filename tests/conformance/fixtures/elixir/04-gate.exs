use Sykli

pipeline do
  task "build" do
    run "make build"
  end

  gate "approve-deploy" do
    after_ ["build"]
    gate_strategy "env"
    gate_timeout 600
    gate_message "Approve deployment to production?"
    gate_env_var "DEPLOY_APPROVED"
  end

  task "deploy" do
    run "make deploy"
    after_ ["approve-deploy"]
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
