import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('build').run('go build ./...').taskType('build');
p.task('test').run('go test ./...').taskType('test').after('build');

p.emit();
