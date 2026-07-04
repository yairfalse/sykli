use sykli::{Actor, ActorKind, Mandate, Pipeline};

fn main() {
    let mut p = Pipeline::new();
    p.task("docs")
        .run("make docs")
        .actor(Actor::new(ActorKind::Human).id("maintainer"))
        .mandate(
            Mandate::new(&["docs/**", "README.md"])
                .diff_lines(200)
                .wall_clock_ms(900000)
                .network(false),
        );
    p.emit();
}
