# EventQueue Flake Investigation

## Reproduction

Commands run:

```bash
cd core
for i in $(seq 1 20); do
  echo "=== Run $i ==="
  mix test test/sykli/mesh/transport/sim/event_queue_test.exs --seed $i || break
done
```

```bash
cd core
for i in $(seq 1 30); do
  echo "=== Random Run $i ==="
  STREAMDATA_MAX_RUNS=500 mix test test/sykli/mesh/transport/sim/event_queue_test.exs --seed 0 || break
done
```

Observed result:

- 20 seeded runs (`--seed 1` through `--seed 20`): all green
- 30 additional runs with `--seed 0`: all green
- total attempts: 50
- no failure reproduced locally in this spike

Notes:

- `mix test` still reported `max_cases: 32` in output during the second loop, so the `STREAMDATA_MAX_RUNS=500` environment setting did not visibly change ExUnit's displayed case count in this environment.
- Because the flake did not reproduce, there is no failing seed, no shrunk counterexample captured in this spike, and no new full failure output to attach.

Previous reported failure text from the earlier verification run that triggered this triage:

```text
** (StreamData.TooManyDuplicatesError) too many (10) non-unique elements were generated consecutively. Make sure to avoid generating from a small space of data (such as only a handful of terms) and make sure a small generation size doesn't affect uniqueness too heavily. There were still 7 elements left to generate
```

That report was emitted from the property test at:

- `core/test/sykli/mesh/transport/sim/event_queue_test.exs:56`

## Classification

Class: **A — Test generator bug** `[INFERRED]`

Evidence:

- The property test at `core/test/sykli/mesh/transport/sim/event_queue_test.exs:56` generates `seqs` via `StreamData.uniq_list_of(StreamData.integer())`.
- The earlier reported failure was `StreamData.TooManyDuplicatesError`, which is raised by `StreamData.uniq_list_of/2` while generating unique values, before the property body executes.
- The EventQueue implementation at `core/lib/sykli/mesh/transport/sim/event_queue.ex:8-49` is pure and does not contain randomness, concurrency, or VM-order-sensitive logic. It stores full `{at_ms, seq, event}` tuples in `:gb_sets` and reads them via `smallest` / `take_smallest`.

Why this is `[INFERRED]` rather than fully proven:

- The flake did not reproduce in 50 attempts, so this spike has no fresh counterexample.
- The only concrete failure shape available is the prior `TooManyDuplicatesError`, and that shape points at generation pressure in `uniq_list_of/2`, not at queue ordering.

## Blast Radius

1. Does the flake affect virtual-time progression in the simulator?

- `[INFERRED]` No, not directly.
- If the failure is in `StreamData.uniq_list_of/2` before the property body runs, then the EventQueue code is never exercised in the failing run. That means this flake blocks confidence in the property test, but does not itself demonstrate nondeterministic virtual-time progression.

2. Does the flake manifest at usage patterns the simulator actually hits?

- `[INFERRED]` Probably not.
- The simulator does not generate queue entries through `StreamData.uniq_list_of/2`; it inserts deterministic `{at_ms, seq, event}` tuples produced by its own state machine.
- The reported failure mode is specific to the property generator's attempt to produce a unique integer list, not to actual simulator queue operations.

3. Is the flake fixable in isolation or does it require redesigning the queue?

- `[INFERRED]` Fixable in isolation.
- If the classification is correct, the fix is local to the property generator or its parameters, not to `Sykli.Mesh.Transport.Sim.EventQueue`.

## Proposed Fix Direction

Treat this as a property-generator issue first. The most likely fix direction is to change the property input generation so uniqueness pressure is controlled explicitly, for example by generating from a larger/stable domain or by constructing unique `seq` values without relying on `uniq_list_of(StreamData.integer())` under shrink pressure. Only if a reproduced counterexample reaches the queue implementation should this be reconsidered as an EventQueue determinism bug.

## Cost Estimate

Estimated implementation cost: **~0.05 to 0.1 agent-weeks** if this stays Class A.

- Small end: generator-only adjustment plus rerun of the property suite.
- Larger end: generator adjustment plus an additional focused regression test documenting the previously observed `TooManyDuplicatesError` scenario.
