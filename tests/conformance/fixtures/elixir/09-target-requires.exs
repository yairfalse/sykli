use Sykli

pipeline do
  task "build" do
    run "make build"
    target "docker"
    requires ["gpu", "high-memory"]
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
