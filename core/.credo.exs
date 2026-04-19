%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/sykli/mesh/transport/",
          "lib/credo_sykli/",
          "test/credo_sykli/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: ["lib/credo_sykli/check/no_wall_clock.ex"],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          {CredoSykli.Check.NoWallClock, [severity: :error]}
        ],
        disabled: []
      }
    }
  ]
}
