use Sykli

pipeline do
  task "test" do
    run "go test ./..."
  end

  review "review-code" do
    primitive "lint"
    agent "claude"
    context ["src/**/*.go"]
    after_ ["test"]
    deterministic true
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
