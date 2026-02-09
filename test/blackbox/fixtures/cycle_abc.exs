IO.puts(~s({"version":"1","tasks":[{"name":"a","command":"echo a","depends_on":["c"]},{"name":"b","command":"echo b","depends_on":["a"]},{"name":"c","command":"echo c","depends_on":["b"]}]}))
