use Sykli

pipeline do
  task "test" do
    run "pytest"
    service "postgres:15", "db"
    service "redis:7", "cache"
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
