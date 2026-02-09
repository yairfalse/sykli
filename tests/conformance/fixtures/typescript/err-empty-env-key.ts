import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

// Empty env key should fail
p.task('test').run('echo test').env('', 'value');

p.emit();
