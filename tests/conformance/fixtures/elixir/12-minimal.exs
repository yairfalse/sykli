use Sykli

pipeline do
  task "hello" do
    run "echo hello"
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
