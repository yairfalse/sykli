use Sykli

pipeline do
  task "test" do
    run "echo test"
  end

  task "flaky" do
    run "echo flaky"
    retry 2
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
