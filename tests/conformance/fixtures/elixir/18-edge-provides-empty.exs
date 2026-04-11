use Sykli

pipeline do
  task "build" do
    run "make build"
    provides "artifact"
  end

  task "migrate" do
    run "dbmate up"
    provides "db-ready"
  end

  task "package" do
    run "docker build"
    after_ ["build"]
    provides "image", "myapp:latest"
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
