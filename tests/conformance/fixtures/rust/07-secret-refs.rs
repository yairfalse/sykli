use sykli::{Pipeline, SecretRef};

fn main() {
    let mut p = Pipeline::new();
    p.task("deploy").run("./deploy.sh")
        .secret_from("db_pass", SecretRef::from_env("DB_PASSWORD"))
        .secret_from("tls_cert", SecretRef::from_file("/certs/tls.pem"))
        .secret_from("api_key", SecretRef::from_vault("secret/data/api#key"));
    p.emit();
}
