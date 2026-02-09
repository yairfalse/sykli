leaf_tasks =
  for i <- 1..20 do
    ~s({"name":"leaf_#{i}","command":"echo leaf #{i}"})
  end
  |> Enum.join(",")

deps = for i <- 1..20, do: ~s("leaf_#{i}")
deps_str = Enum.join(deps, ",")
join_task = ~s({"name":"join","command":"echo join","depends_on":[#{deps_str}]})

IO.puts(~s({"version":"1","tasks":[#{leaf_tasks},#{join_task}]}))
