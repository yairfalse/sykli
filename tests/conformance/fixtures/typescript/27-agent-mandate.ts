import { Pipeline, fileEvidenceNonEmpty } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();
p.task('implement')
  .run('go test ./...')
  .taskType('test')
  .successCriteria([{ type: 'exit_code', equals: 0 }])
  .evidenceRequired([fileEvidenceNonEmpty('coverage', 'coverage.out')])
  .actor({ kind: 'agent', id: 'claude' })
  .mandate({ scope: ['sdk/**', 'tests/conformance/**'] });
p.emit();
