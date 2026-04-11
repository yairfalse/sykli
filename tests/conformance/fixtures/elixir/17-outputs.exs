use Sykli

pipeline do
  task "build" do
    run "make build"
    output "binary", "/out/app"
    output "checksum", "/out/sha256"
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
