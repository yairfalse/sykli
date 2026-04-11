use Sykli

pipeline do
  task "build" do
    run "go build -o /out/app"
    output "binary", "/out/app"
  end

  task "test" do
    run "./app test"
    input_from "build", "binary", "/app"
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
