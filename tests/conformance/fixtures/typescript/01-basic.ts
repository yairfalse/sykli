import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('lint').run('npm run lint').inputs('**/*.ts');

p.task('test').run('npm test').after('lint')
  .inputs('**/*.ts', '**/*.test.ts').timeout(120);

p.task('build').run('npm run build').after('test');

p.emit();
