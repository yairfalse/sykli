import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('test').run('echo test').retry(0);

p.task('flaky').run('echo flaky').retry(2);

p.emit();
