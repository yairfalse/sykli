%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          # Simulator-facing code: virtual time only.
          "lib/sykli/mesh/transport/",
          "credo_sykli/",
          "test/credo_sykli/",
          # Pure contract & output-shaping transforms: parsing, validation, the
          # closed-vocabulary modules, contract hashing, and occurrence shaping
          # must be deterministic, so wall-clock/global-RNG is a real bug here.
          # The engine's legitimately time-stamping modules (occurrence factory,
          # run history, cache, OIDC, coordinator) are intentionally exempt — a
          # CI engine records real time; output determinism is guarded by the
          # determinism tests, not this lint.
          "lib/sykli/graph.ex",
          "lib/sykli/graph/",
          "lib/sykli/validate.ex",
          "lib/sykli/actor.ex",
          "lib/sykli/mandate.ex",
          "lib/sykli/task_type.ex",
          "lib/sykli/success_criteria.ex",
          "lib/sykli/evidence_requirement.ex",
          "lib/sykli/contract_schema_version.ex",
          "lib/sykli/contract_hash.ex",
          "lib/sykli/contract_lock.ex",
          "lib/sykli/contract_diff.ex",
          "lib/sykli/contract_slice.ex",
          "lib/sykli/failure_semantics.ex",
          "lib/sykli/occurrence/serializer.ex",
          "lib/sykli/occurrence/enrichment.ex"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: ["credo_sykli/check/no_wall_clock.ex"],
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
