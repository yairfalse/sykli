IO.puts(~S|{"version":"1","tasks":[{"name":"build","command":"exit 1"},{"name":"deploy","command":"touch deploy_ran.sentinel","depends_on":["build"]}]}|)
