use Sykli

pipeline do
  task "test" do
    run "echo test"
    env "", "value"
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
