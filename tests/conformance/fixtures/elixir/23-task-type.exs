use Sykli

pipeline do
  task "build" do
    run "go build ./..."
    task_type :build
  end

  task "test" do
    run "go test ./..."
    task_type :test
    after_ ["build"]
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
