IO.puts(~s({"version":"1","tasks":[{"name":"a","command":"echo a","depends_on":["b"]},{"name":"b","command":"echo b","depends_on":["a"]}]}))
