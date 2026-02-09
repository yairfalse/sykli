import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('build').run('make build');

// Duplicate after calls should be deduplicated
p.task('test').run('go test').after('build').after('build');

p.task('deploy').run('./deploy.sh').after('build', 'test', 'build', 'test');

p.emit();
