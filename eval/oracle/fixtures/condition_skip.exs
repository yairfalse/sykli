IO.puts(~S|{"version":"1","tasks":[{"name":"always","command":"echo always"},{"name":"never","command":"echo never","when":"branch == 'nonexistent-branch-xyz'"}]}|)
