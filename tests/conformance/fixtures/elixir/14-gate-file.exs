use Sykli

pipeline do
  gate "wait-approval" do
    gate_strategy "file"
    gate_timeout 1800
    gate_file_path "/tmp/approved"
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
