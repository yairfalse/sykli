use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.task("lint").run("npm run lint").inputs(&["**/*.ts"]);
    p.task("test").run("npm test").after(&["lint"]).inputs(&["**/*.ts", "**/*.test.ts"]).timeout(120);
    p.task("build").run("npm run build").after(&["test"]);
    p.emit();
}
