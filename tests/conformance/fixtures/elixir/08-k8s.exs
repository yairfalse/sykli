use Sykli

pipeline do
  task "train" do
    run "python train.py"
    k8s Sykli.K8s.options() |> Sykli.K8s.memory("32Gi") |> Sykli.K8s.cpu("4") |> Sykli.K8s.gpu(2)
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
