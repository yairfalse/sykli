use Sykli

pipeline do
  task "test" do
    run("go test ./...")
    task_type(:test)

    success_criteria([
      exit_code(0),
      file_exists("coverage.out")
    ])
  end

  task "package" do
    run("go build -o dist/app ./...")
    task_type(:package)

    success_criteria([
      file_non_empty("dist/app")
    ])

    after_(["test"])
  end
end
