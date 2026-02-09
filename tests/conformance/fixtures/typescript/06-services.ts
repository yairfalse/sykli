import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('test').run('pytest')
  .service('postgres:15', 'db')
  .service('redis:7', 'cache');

p.emit();
