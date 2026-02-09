import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('test').run('go test ./...');
p.task('test').run('go test -race ./...');

p.emit();
