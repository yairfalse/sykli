tasks =
  for i <- 1..30 do
    deps = if i == 1, do: "", else: ~s(,"depends_on":["step_#{i - 1}"])
    ~s({"name":"step_#{i}","command":"echo step #{i}"#{deps}})
  end

IO.puts(~s|{"version":"1","tasks":[#{Enum.join(tasks, ",")}]}|)
