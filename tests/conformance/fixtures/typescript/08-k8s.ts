import { Pipeline } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('train').run('python train.py')
  .k8s({ memory: '32Gi', cpu: '4', gpu: 2 });

p.emit();
