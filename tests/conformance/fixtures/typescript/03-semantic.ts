import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('test-auth').run('pytest tests/auth/')
  .inputs('src/auth/**/*.py', 'tests/auth/**/*.py')
  .covers('src/auth/*')
  .intent('unit tests for auth module')
  .setCriticality('high')
  .onFail('analyze')
  .selectMode('smart');

p.emit();
