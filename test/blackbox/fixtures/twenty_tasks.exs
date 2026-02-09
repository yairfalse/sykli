tasks =
  for i <- 1..20 do
    ~s({"name":"task_#{i}","command":"echo task #{i}"})
  end
  |> Enum.join(",")

IO.puts(~s({"version":"1","tasks":[#{tasks}]}))
