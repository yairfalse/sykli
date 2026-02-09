import { Pipeline, fromEnv, fromFile, fromVault } from '../../../../sdk/typescript/src/index';

const p = new Pipeline();

p.task('deploy').run('./deploy.sh')
  .secretFrom('db_pass', fromEnv('DB_PASSWORD'))
  .secretFrom('tls_cert', fromFile('/certs/tls.pem'))
  .secretFrom('api_key', fromVault('secret/data/api#key'));

p.emit();
