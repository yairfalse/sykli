use sykli::{Pipeline, K8sOptions};

fn main() {
    let mut p = Pipeline::new();
    p.task("train").run("python train.py").k8s(K8sOptions { memory: Some("32Gi".into()), cpu: Some("4".into()), gpu: Some(2) });
    p.emit();
}
