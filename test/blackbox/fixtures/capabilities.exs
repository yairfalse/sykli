IO.puts(~s({"version":"1","tasks":[{"name":"start_db","command":"echo db ready","provides":["database"]},{"name":"test","command":"echo testing","needs":["database"]}]}))
