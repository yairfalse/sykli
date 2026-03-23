tasks =
  for i <- 1..50 do
    ~s({"name":"task_#{i}","command":"echo task #{i}"})
  end

IO.puts(~s|{"version":"1","tasks":[#{Enum.join(tasks, ",")}]}|)
