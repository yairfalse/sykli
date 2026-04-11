use Sykli

pipeline do
  task "build" do
    run "make build"
    outputs ["dist/app", "dist/lib"]
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
