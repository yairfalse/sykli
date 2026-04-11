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
    after_ ["B"]
  end
  task "D" do
    run "echo D"
    after_ ["C"]
  end
  task "E" do
    run "echo E"
    after_ ["D"]
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
