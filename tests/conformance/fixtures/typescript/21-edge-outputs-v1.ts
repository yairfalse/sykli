import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

// v1-style outputs (positional, auto-named)
p.task('build').run('make build').outputs('dist/app', 'dist/lib');

p.emit();
