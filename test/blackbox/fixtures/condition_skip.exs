IO.puts(~s({"version":"1","tasks":[{"name":"always","command":"echo always"},{"name":"deploy","command":"echo deploy","when":"branch == 'nonexistent-branch-xyz'"}]}))
