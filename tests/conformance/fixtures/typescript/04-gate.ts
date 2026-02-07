import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('build').run('make build');

p.gate('approve-deploy').after('build')
  .gateStrategy('env')
  .gateTimeout(600)
  .gateMessage('Approve deployment to production?')
  .gateEnvVar('DEPLOY_APPROVED');

p.task('deploy').run('make deploy').after('approve-deploy');

p.emit();
