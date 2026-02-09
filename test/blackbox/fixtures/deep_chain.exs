tasks =
  for i <- 1..20 do
    deps = if i == 1, do: "", else: ~s(,"depends_on":["step_#{i - 1}"])
    ~s({"name":"step_#{i}","command":"echo step #{i}"#{deps}})
  end
  |> Enum.join(",")

IO.puts(~s({"version":"1","tasks":[#{tasks}]}))
