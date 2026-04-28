IO.puts(~s({"version":"1","tasks":[{"name":"upstream","command":"exit 1"},{"name":"downstream","command":"echo should-not-run > blocked_side_effect.log","depends_on":["upstream"]}]}))
