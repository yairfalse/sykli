use Sykli

pipeline do
  task "deploy" do
    run "./deploy.sh"
    secret_from "db_pass", Sykli.SecretRef.from_env("DB_PASSWORD")
    secret_from "tls_cert", Sykli.SecretRef.from_file("/certs/tls.pem")
    secret_from "api_key", Sykli.SecretRef.from_vault("secret/data/api#key")
  end
end
|> Sykli.Emitter.validate!()
|> Sykli.Emitter.to_json()
|> IO.puts()
