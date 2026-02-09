import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('build').run('make build').provides('artifact', '');

p.task('migrate').run('dbmate up').provides('db-ready');

p.task('package').run('docker build').provides('image', 'myapp:latest').after('build');

p.emit();
