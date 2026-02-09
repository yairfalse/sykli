import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('test').run('go test ./...')
  .matrix('os', 'linux', 'darwin')
  .matrix('arch', 'amd64', 'arm64');

p.emit();
