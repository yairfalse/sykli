import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('build').run('go build -o /out/app')
  .output('binary', '/out/app');

p.task('test').run('./app test')
  .inputFrom('build', 'binary', '/app');

p.emit();
