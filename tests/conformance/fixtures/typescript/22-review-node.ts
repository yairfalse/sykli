import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('test').run('go test ./...');
p.review('review-code')
  .primitive('lint')
  .agent('claude')
  .context('src/**/*.go')
  .after('test')
  .deterministic(true);

p.emit();
