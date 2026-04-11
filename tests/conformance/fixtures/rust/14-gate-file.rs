use sykli::Pipeline;

fn main() {
    let mut p = Pipeline::new();
    p.gate("wait-approval").gate_strategy("file").gate_timeout(1800).gate_file_path("/tmp/approved");
    p.emit();
}
