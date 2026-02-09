File.rm("/tmp/sykli_retry_flag")
IO.puts(~s({"version":"1","tasks":[{"name":"flaky","command":"sh -c 'if [ -f /tmp/sykli_retry_flag ]; then echo ok; else touch /tmp/sykli_retry_flag && exit 1; fi'","retry":2}]}))
