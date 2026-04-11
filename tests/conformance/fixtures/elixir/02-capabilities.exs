use Sykli

pipeline do
  task "compile" do
    run "go build -o /out/app ./cmd/server"
    provides "binary", "/out/app"
  end

  task "migrate" do
    run "dbmate up"
    provides "db-ready"
  end

  task "integration-test" do
    run "go test -tags=integration ./..."
    needs ["binary", "db-ready"]
    timeout 300
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
