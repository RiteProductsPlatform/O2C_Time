#!/usr/bin/env python3
"""
Build the Postman collection from the VBCS service spec.

    python postman/build_collection.py

Generated rather than hand-written on purpose: services/oc_time/openapi3.json is
already validated against the deployed ORDS handlers by the build checks, so
generating from it means a Postman request can never point at a path that does
not exist. Re-run this after adding an endpoint.

The login request carries a test script that stores the token as a collection
variable, so every later request is authenticated by running Auth > login first.
"""

import collections
import io
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SPEC = os.path.join(ROOT, 'services', 'oc_time', 'openapi3.json')
OUT = os.path.join(HERE, 'O2C_Time.postman_collection.json')

DEFAULT_BASE_URL = 'https://ords-sit.rite.digital/ords/o2c_time'

# Body fields that should bind to a collection variable rather than a blank, so
# a request is runnable without editing every field by hand.
VAR_FOR = {
    'actor': '{{actorEmail}}',
    'actorEmpId': '{{actorEmpId}}',
    'employeeId': '{{employeeId}}',
    'periodId': '{{periodId}}',
    'projectId': '{{projectId}}',
    'managerId': '{{actorEmpId}}',
    'tsWeekId': '{{tsWeekId}}',
    'traceId': '{{$guid}}',
    'email': '{{email}}',
    'password': '{{password}}',
    'token': '{{token}}',
}

FOLDERS = [
    '1. Auth  (oc.time.auth)',
    '2. Employee  (oc.time)',
    '3. Manager  (oc.time.approval)',
    '4. Admin  (oc.time.admin)',
]

LOGIN_TEST = [
    "const r = pm.response.json();",
    "if (pm.response.code === 200 && r.token) {",
    "  pm.collectionVariables.set('token', r.token);",
    "  pm.collectionVariables.set('actorEmpId', r.employeeId || '');",
    "  pm.collectionVariables.set('actorEmail', pm.collectionVariables.get('email'));",
    "  if (r.employeeId) { pm.collectionVariables.set('employeeId', r.employeeId); }",
    "  console.log('token saved -', r.role, r.employeeId || '(no worker row)');",
    "} else {",
    "  console.log('login failed', pm.response.code, pm.response.text());",
    "}",
    "pm.test('200 and a 64-character token', function () {",
    "  pm.response.to.have.status(200);",
    "  pm.expect(r.token).to.have.lengthOf(64);",
    "});",
]

DESCRIPTION = (
    'O2C Timesheet Module - the ORDS surface.\n\n'
    'Generated from services/oc_time/openapi3.json, so no request can point at '
    'a path that is not deployed. Regenerate with postman/build_collection.py.\n\n'
    'START HERE: run "1. Auth" -> "login". Its test script stores the token and '
    'the signed-in employee id as collection variables; every other request '
    'reads them from there.\n\n'
    'periodId, projectId and tsWeekId start empty. The GET requests that list '
    'them (getPeriods, getManagerProjects, getWeeks) tell you what to fill in.\n\n'
    'Sign in as a different persona by changing the email collection variable:\n'
    '  admin@rite.digital              ROLE_TIME_ADMIN   (no worker row)\n'
    '  navamani.solairajan@rite.digital ROLE_TIME_MANAGER RI9001\n'
    '  sampaul.jeevan@rite.digital     ROLE_TIME_EMPLOYEE RI2824\n'
    'All seeded with password Rite@123 (test data only).'
)


def load_spec():
    with io.open(SPEC, encoding='utf-8') as fh:
        return json.load(fh)


def sample_body(node, schemas, depth=0):
    """Turn a schema (possibly a $ref) into a sample JSON body."""
    if depth > 4 or not isinstance(node, dict):
        return None
    if '$ref' in node:
        target = schemas.get(node['$ref'].split('/')[-1], {})
        return sample_body(target, schemas, depth + 1)

    node_type = node.get('type')
    if node_type == 'object' or 'properties' in node:
        return {k: sample_body(v, schemas, depth + 1)
                for k, v in (node.get('properties') or {}).items()}
    if node_type == 'array':
        return [sample_body(node.get('items', {}), schemas, depth + 1)]
    if node_type in ('integer', 'number'):
        return 0
    if node_type == 'boolean':
        return False
    return ''


def folder_for(path):
    if path.startswith('/oc/time/auth/'):
        return FOLDERS[0]
    if path.startswith('/oc/time/approval/'):
        return FOLDERS[2]
    if path.startswith('/oc/time/admin/'):
        return FOLDERS[3]
    return FOLDERS[1]


def build_item(path, method, op, schemas):
    # {periodId} -> {{periodId}} so path parameters bind to collection variables
    url_path = re.sub(r'\{([A-Za-z0-9_]+)\}',
                      lambda m: '{{' + m.group(1) + '}}', path)

    request = collections.OrderedDict()
    request['method'] = method.upper()
    request['header'] = []
    request['url'] = collections.OrderedDict([
        ('raw', '{{baseUrl}}' + url_path),
        ('host', ['{{baseUrl}}']),
        ('path', [s for s in url_path.strip('/').split('/') if s]),
    ])
    request['description'] = op.get('summary', '')

    json_body = (op.get('requestBody', {})
                   .get('content', {})
                   .get('application/json', {}))
    if json_body.get('schema'):
        body = sample_body(json_body['schema'], schemas) or {}
        for key in list(body):
            if key in VAR_FOR:
                body[key] = VAR_FOR[key]
        request['header'].append(
            {'key': 'Content-Type', 'value': 'application/json'})
        request['body'] = {
            'mode': 'raw',
            'raw': json.dumps(body, indent=2),
            'options': {'raw': {'language': 'json'}},
        }

    item = collections.OrderedDict()
    item['name'] = op.get('operationId') or (method + ' ' + path)
    item['request'] = request

    if op.get('operationId') == 'login':
        item['event'] = [{
            'listen': 'test',
            'script': {'type': 'text/javascript', 'exec': LOGIN_TEST},
        }]
    return item


ORDS_FILES = collections.OrderedDict([
    ('11_ords_time.sql', '/oc/time/'),
    ('12_ords_time_approval.sql', '/oc/time/approval/'),
    ('13_ords_time_admin.sql', '/oc/time/admin/'),
    ('14_ords_time_auth.sql', '/oc/time/auth/'),
])


def deployed_handlers():
    """(method, path) for every ORDS.DEFINE_HANDLER in db/ords."""
    found = set()
    for filename, base in ORDS_FILES.items():
        full = os.path.join(ROOT, 'db', 'ords', filename)
        if not os.path.exists(full):
            continue
        with io.open(full, encoding='utf-8') as fh:
            sql = fh.read()
        for block in re.finditer(r'DEFINE_HANDLER\((.*?)\n\s*p_source', sql, re.S):
            pattern = re.search(r"p_pattern\s*=>\s*'([^']*)'", block.group(1))
            method = re.search(r"p_method\s*=>\s*'([^']*)'", block.group(1))
            if not (pattern and method):
                continue
            path = (base + pattern.group(1)).replace('//', '/')
            path = re.sub(r':([A-Za-z0-9_]+)', r'{\1}', path)
            found.add((method.group(1).lower(), path))
    return found


def report_drift(spec):
    """
    Warn where the spec and the ORDS source disagree.

    The build checks only verify that every callRest resolves to an operation —
    the other direction was never checked, which is how the whole oc.time.auth
    module and the three dormant push endpoints ended up deployed but
    undescribed, and therefore invisible here.
    """
    described = {(m, p) for p, ops in spec['paths'].items()
                 for m in ops if m in ('get', 'post', 'put', 'delete')}
    deployed = deployed_handlers()

    missing = deployed - described
    extra = described - deployed

    if missing:
        print('\nWARNING: deployed in db/ords but NOT in the spec '
              '(so not in this collection):')
        for method, path in sorted(missing, key=lambda x: x[1]):
            print('   %-6s %s' % (method.upper(), path))
    if extra:
        print('\nWARNING: in the spec but NOT deployed (these would 404):')
        for method, path in sorted(extra, key=lambda x: x[1]):
            print('   %-6s %s' % (method.upper(), path))
    if not missing and not extra:
        print('spec matches db/ords exactly (%d handlers).' % len(deployed))


def main():
    spec = load_spec()
    schemas = spec.get('components', {}).get('schemas', {})

    grouped = collections.OrderedDict((name, []) for name in FOLDERS)
    total = 0

    for path, ops in sorted(spec['paths'].items()):
        for method, op in ops.items():
            if method not in ('get', 'post', 'put', 'delete'):
                continue
            grouped[folder_for(path)].append(
                build_item(path, method, op, schemas))
            total += 1

    # Login first inside its folder - it is the request everything else needs.
    auth = grouped[FOLDERS[0]]
    auth.sort(key=lambda i: (i['name'] != 'login', i['name']))

    collection = collections.OrderedDict()
    collection['info'] = collections.OrderedDict([
        ('name', 'O2C Timesheet Module (ORDS)'),
        ('description', DESCRIPTION),
        ('schema',
         'https://schema.getpostman.com/json/collection/v2.1.0/collection.json'),
    ])
    collection['item'] = [{'name': name, 'item': items}
                          for name, items in grouped.items() if items]
    collection['variable'] = [
        {'key': 'baseUrl', 'value': DEFAULT_BASE_URL},
        {'key': 'email', 'value': 'admin@rite.digital'},
        {'key': 'password', 'value': 'Rite@123'},
        {'key': 'token', 'value': ''},
        {'key': 'actorEmail', 'value': 'admin@rite.digital'},
        {'key': 'actorEmpId', 'value': ''},
        {'key': 'employeeId', 'value': 'RI2824'},
        {'key': 'periodId', 'value': ''},
        {'key': 'projectId', 'value': ''},
        {'key': 'tsWeekId', 'value': ''},
        {'key': 'periodYear', 'value': '2026'},
        {'key': 'periodMonth', 'value': '7'},
        {'key': 'confirmId', 'value': ''},
        {'key': 'batchId', 'value': ''},
    ]

    with io.open(OUT, 'w', encoding='utf-8') as fh:
        fh.write(json.dumps(collection, indent=2, ensure_ascii=False) + '\n')

    print('wrote %s' % os.path.relpath(OUT, ROOT))
    print('requests: %d' % total)
    for name, items in grouped.items():
        print('   %-34s %d' % (name, len(items)))

    report_drift(spec)


if __name__ == '__main__':
    main()
