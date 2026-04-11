use Sykli

pipeline do
  task "test" do
    run "go test ./..."
  end
  task "test" do
    run "go test -race ./..."
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
