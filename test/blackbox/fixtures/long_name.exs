long_name = String.duplicate("a", 500)
IO.puts(~s({"version":"1","tasks":[{"name":"#{long_name}","command":"echo long"}]}))
