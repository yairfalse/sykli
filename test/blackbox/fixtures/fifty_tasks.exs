tasks =
  for i <- 1..50 do
    ~s({"name":"t#{i}","command":"echo t#{i}"})
  end
  |> Enum.join(",")

IO.puts(~s({"version":"1","tasks":[#{tasks}]}))
