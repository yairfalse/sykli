IO.puts(~S|{"version":"1","tasks":[{"name":"build","command":"exit 1"},{"name":"deploy","command":"echo deploy","depends_on":["build"]}]}|)
