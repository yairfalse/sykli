import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('hello').run('echo hello');

p.emit();
