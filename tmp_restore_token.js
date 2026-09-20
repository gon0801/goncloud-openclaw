const fs = require('fs');
const p = process.env.USERPROFILE + '\\.openclaw\\openclaw.json';
const j = JSON.parse(fs.readFileSync(p, 'utf8'));
console.log('before=' + j.gateway.auth.mode);
j.gateway.auth.mode = 'token';
fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n');
const j2 = JSON.parse(fs.readFileSync(p, 'utf8'));
console.log('after=' + j2.gateway.auth.mode);
console.log('token_still=' + (j2.gateway.auth.token != null));
