import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();
p.task('docs')
  .run('make docs')
  .actor({ kind: 'human', id: 'maintainer' })
  .mandate({
    scope: ['docs/**', 'README.md'],
    budget: { diff_lines: 200, wall_clock_ms: 900000 },
    capabilities: { network: false },
  });
p.emit();
