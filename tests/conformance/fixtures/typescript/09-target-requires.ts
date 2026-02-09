import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('build').run('make build')
  .target('docker')
  .requires('gpu', 'high-memory');

p.emit();
