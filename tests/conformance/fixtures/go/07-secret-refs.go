package main

import sykli "github.com/yairfalse/sykli/sdk/go"

func main() {
	p := sykli.New()

	p.Task("deploy").Run("./deploy.sh").
		SecretFrom("db_pass", sykli.FromEnv("DB_PASSWORD")).
		SecretFrom("tls_cert", sykli.FromFile("/certs/tls.pem")).
		SecretFrom("api_key", sykli.FromVault("secret/data/api#key"))

	p.Emit()
}
