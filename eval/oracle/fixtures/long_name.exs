name = String.duplicate("a", 200)
IO.puts(~s|{"version":"1","tasks":[{"name":"#{name}","command":"echo long"}]}|)
