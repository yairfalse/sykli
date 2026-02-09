import { Pipeline, fromFile, fromVault } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('lint').run('golangci-lint run')
  .inputs('**/*.go')
  .timeout(60)
  .setCriticality('low')
  .onFail('skip');

p.task('test').run('go test ./...')
  .after('lint')
  .inputs('**/*.go', 'go.mod')
  .env('CGO_ENABLED', '0')
  .retry(2)
  .timeout(300)
  .secrets('CODECOV_TOKEN')
  .matrix('go_version', '1.21', '1.22')
  .service('postgres:15', 'db')
  .covers('src/**/*.go')
  .intent('unit tests for all packages')
  .setCriticality('high')
  .onFail('analyze')
  .selectMode('smart');

p.task('build').run('go build -o /out/app')
  .after('test')
  .output('binary', '/out/app')
  .provides('binary', '/out/app')
  .k8s({ memory: '4Gi', cpu: '2' })
  .target('docker')
  .requires('docker');

p.gate('approve-deploy').after('build')
  .gateStrategy('env')
  .gateTimeout(1800)
  .gateMessage('Deploy to production?')
  .gateEnvVar('DEPLOY_APPROVED');

p.task('deploy').run('kubectl apply -f k8s/')
  .after('approve-deploy')
  .needs('binary')
  .secretFrom('kube_config', fromFile('/home/.kube/config'))
  .secretFrom('registry_pass', fromVault('secret/data/registry#password'))
  .when('branch:main');

p.emit();
