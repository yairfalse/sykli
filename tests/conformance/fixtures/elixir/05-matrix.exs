use Sykli

pipeline do
  task "test" do
    run "go test ./..."
    matrix "os", ["linux", "darwin"]
    matrix "arch", ["amd64", "arm64"]
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
