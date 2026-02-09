IO.puts(~s({"version":"1","tasks":[{"name":"test","command":"echo test","env":{"FOO":"bar","BAZ":"qux"},"k8s":{"memory":"1Gi","cpu":"500m","namespace":"ci"}}]}))
