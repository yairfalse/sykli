import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('A').run('echo A').after('B');
p.task('B').run('echo B').after('A');

p.emit();
