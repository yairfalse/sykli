# Simulates SDK that outputs warnings/download messages before JSON
IO.write(:stderr, "Downloading dependencies...\nCompiling project...\n")
IO.puts("Some noisy output before the json")
IO.puts(~s({"version":"1","tasks":[{"name":"clean","command":"echo clean"}]}))
