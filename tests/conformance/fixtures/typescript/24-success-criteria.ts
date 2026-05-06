import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();
p.task('test')
  .run('go test ./...')
  .taskType('test')
  .successCriteria([
    { type: 'exit_code', equals: 0 },
    { type: 'file_exists', path: 'coverage.out' },
  ]);
p.task('package')
  .run('go build -o dist/app ./...')
  .taskType('package')
  .successCriteria([{ type: 'file_non_empty', path: 'dist/app' }])
  .after('test');
p.emit();
