import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.gate('wait-approval')
  .gateStrategy('file')
  .gateTimeout(1800)
  .gateFilePath('/tmp/approved');

p.emit();
