use Sykli

pipeline do
  task "build" do
    run "make build"
  end

  task "test" do
    run "go test"
    after_ ["build"]
  end

  task "deploy" do
    run "./deploy.sh"
    after_ ["build", "test"]
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
