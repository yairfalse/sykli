use Sykli

pipeline do
  task "A" do
    run "echo A"
  end
  task "B" do
    run "echo B"
    after_ ["A"]
  end
  task "C" do
    run "echo C"
    after_ ["A"]
  end
  task "D" do
    run "echo D"
    after_ ["B", "C"]
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
