use Sykli

pipeline do
  task "test" do
    run "go test ./..."
    after_ ["nonexistent"]
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
