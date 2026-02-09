import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('build').run('make build')
  .output('binary', '/out/app')
  .output('checksum', '/out/sha256');

p.emit();
