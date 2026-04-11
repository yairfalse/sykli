use Sykli

pipeline do
  task "A" do
    run "echo A"
    after_ ["B"]
  end
  task "B" do
    run "echo B"
    after_ ["A"]
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
