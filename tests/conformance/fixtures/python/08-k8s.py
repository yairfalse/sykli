from sykli import Pipeline, K8sOptions

p = Pipeline()

p.task("train").run("python train.py") \
    .k8s(K8sOptions(memory="32Gi", cpu="4", gpu=2))

p.emit()
