import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('test');

p.emit();
