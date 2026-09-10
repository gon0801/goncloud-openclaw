#!/usr/bin/env python3
"""F1: corre la logica de verify-B2 de APLICAR_FASE_B.sh contra un .txt dado.
Simula post = pre con message=<txt> y configRevision distinta (lo que el
`cron edit` persistiria si todo va bien). Mismos checks, mismos mensajes.
Uso: F1-verify-b2.py <pre.json> <txt> ; exit 0 = verify pasa, 1 = falla."""
import json
import sys


def fail(msg):
    print(f'VERIFY_FAIL B2: {msg}')
    sys.exit(1)


pre = json.load(open(sys.argv[1]))
want = open(sys.argv[2]).read().rstrip('\n')
post = dict(pre)
post['payload'] = dict(pre['payload'])
post['payload']['message'] = want
post['configRevision'] = pre['configRevision'] + '-post'
m = post['payload']['message']
if m != want:
    fail('message persistido != generado')
if not all(ord(c) < 128 for c in m):
    fail('no-ASCII')
if post['configRevision'] == pre['configRevision']:
    fail('configRevision no cambio')
if m.count('agent:main:main') != 1:
    fail('ancla B2 no quedo 1x')
print('verify B2 OK')
