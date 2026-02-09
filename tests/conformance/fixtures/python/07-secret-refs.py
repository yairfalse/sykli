from sykli import Pipeline, from_env, from_file, from_vault

p = Pipeline()

p.task("deploy").run("./deploy.sh") \
    .secret_from("db_pass", from_env("db_pass", "DB_PASSWORD")) \
    .secret_from("tls_cert", from_file("tls_cert", "/certs/tls.pem")) \
    .secret_from("api_key", from_vault("api_key", "secret/data/api#key"))

p.emit()
