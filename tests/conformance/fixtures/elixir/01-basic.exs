use Sykli

pipeline do
  task "lint" do
    run "npm run lint"
    inputs ["**/*.ts"]
  end

  task "test" do
    run "npm test"
    after_ ["lint"]
    inputs ["**/*.ts", "**/*.test.ts"]
    timeout 120
  end

  task "build" do
    run "npm run build"
    after_ ["test"]
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
