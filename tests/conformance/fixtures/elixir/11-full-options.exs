use Sykli

pipeline do
  task "test" do
    run "npm test"
    container "node:20"
    workdir "/app"
    env "CI", "true"
    env "NODE_ENV", "test"
    retry 3
    timeout 300
    secrets ["NPM_TOKEN", "GH_TOKEN"]
    when_ "branch:main"
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
