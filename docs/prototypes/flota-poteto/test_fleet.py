import unittest
from copy import deepcopy
from fleet import reconcile, apply_simulated, dispatch


def fixture():
    current = {'native': {'agents': {'main': {'allowAgents': ['legacy'], 'memory': 'keep'}},
                          'models': {}, 'gateway': {'port': 42}},
               'cli': {'workers': {}, 'capacity': 3},
               'sessions': {'old': {'model': 'f-1'}}}
    desired = {'now': 100, 'poteto': 'CANONICAL POTETO CONTENT',
               'mappings': {'native': 'native mapping', 'cli': 'cli mapping'},
               'skills': {'code': 'coding instructions', 'mail': 'email instructions'},
               'publication_targets': ['engineer'], 'profiles': {}}
    discovered, models = [], []
    for runtime, identity in [('native', 'engineer'), ('cli', 'worker')]:
        discovered.append({'runtime': runtime, 'id': identity, 'account': 'acct',
                           'host': 'host', 'revision': 'adapter-v1', 'probe_revision': 'smoke-v1'})
        desired['profiles'][runtime + ':' + identity] = {
            'family': 'f', 'specialty': 'backend', 'skills': ['code'],
            'capabilities': ['tools'], 'expires': 200, 'delegators': ['main'],
            'argv': ['tool', '--model', '{model}', '--prompt-file', 'bundle.txt']}
        models.append({'runtime': runtime, 'id': 'f-1', 'family': 'f', 'order': [1, 9],
                       'account': 'acct', 'host': 'host', 'revision': 'adapter-v1', 'probe_revision': 'smoke-v1',
                       'stable': True, 'source': 'fixture catalog', 'probe_ok': True,
                       'expires': 200, 'capabilities': ['tools'], 'specialties': ['backend']})
    return current, desired, discovered, models


class FleetTests(unittest.TestCase):
    def setUp(self):
        self.c, self.d, self.a, self.m = fixture()

    def plan(self, receipts=None):
        return reconcile(self.c, self.d, self.a, self.m, receipts or {})

    def activate(self):
        plan = self.plan()
        self.c, receipts = apply_simulated(plan, self.c, {}, 100)
        return self.plan(receipts), receipts

    def test_both_projections_bundle_and_preservation(self):
        before = deepcopy(self.c)
        plan = self.plan()
        native = plan['proposed']['native']
        cli = plan['proposed']['cli']['workers']['worker']
        self.assertEqual(native['agents']['engineer']['primary'], 'f-1')
        self.assertEqual(cli['model'], cli['argv'][2])
        self.assertEqual(native['agents']['main']['allowAgents'], ['legacy', 'engineer'])
        self.assertEqual(native['routes'], {'backend': 'engineer'})
        self.assertEqual(cli['bundle'], {'poteto': 'CANONICAL POTETO CONTENT',
                         'mapping': 'cli mapping', 'specialty': 'backend',
                         'skills': {'code': 'coding instructions'}})
        self.assertEqual(native['gateway'], {'port': 42})
        self.assertEqual(native['agents']['main']['memory'], 'keep')
        self.assertEqual(plan['proposed']['sessions'], before['sessions'])
        self.assertEqual(self.c, before)

    def test_repeat_no_diff(self):
        plan, receipts = self.activate()
        self.assertEqual(plan['changes'], [])
        self.assertEqual(plan['active'], {'cli': True, 'native': True})

    def test_successor_changes_actual_outputs_and_pins_session(self):
        old, old_receipts = self.activate()
        session = dispatch(old, 'native:engineer', old_receipts, 100,
                           old['contracts']['native:engineer']['bundle'])
        for model in list(self.m):
            self.m.append(dict(model, id='f-2', order=[1, 10]))
        new = self.plan(old_receipts)
        self.assertEqual(new['proposed']['native']['agents']['engineer']['primary'], 'f-2')
        worker = new['proposed']['cli']['workers']['worker']
        self.assertEqual((worker['model'], worker['argv'][2]), ('f-2', 'f-2'))
        resumed = dispatch(new, 'native:engineer', old_receipts, 101,
                           session['bundle'], session=session)
        self.assertEqual(resumed['model'], 'f-1')
        self.assertEqual(new['proposed']['sessions']['old']['model'], 'f-1')

    def test_invalid_successors_never_promote(self):
        self.activate()
        for change, reason in [({'expires': 99}, 'model-evidence-expired'),
                               ({'account': 'other'}, 'probe-scope-mismatch'),
                               ({'host': 'other'}, 'probe-scope-mismatch'),
                               ({'revision': 'other'}, 'probe-scope-mismatch'),
                               ({'probe_revision': 'other'}, 'probe-scope-mismatch'),
                               ({'order': None}, 'unknown-order'),
                               ({'stable': False}, 'unverified'),
                               ({'probe_ok': False}, 'unverified'),
                               ({'capabilities': []}, 'capability-or-specialty-proof-missing')]:
            with self.subTest(change=change):
                candidate = dict(self.m[0], id='f-2', order=[2])
                candidate.update(change)
                self.m.append(candidate)
                plan = self.plan()
                self.assertEqual(plan['proposed']['native']['agents']['engineer']['primary'], 'f-1')
                self.assertTrue(any(reason in g['reason'] for g in plan['gaps']))
                self.m.pop()

    def test_new_discovery_onboards_only_approved_profile_and_target(self):
        self.activate()
        self.a.append(dict(self.a[0], id='mail'))
        plan = self.plan()
        self.assertIn('native:mail', plan['inventory'])
        self.assertIn({'executor': 'native:mail', 'reason': 'needs-profile'}, plan['gaps'])
        self.d['profiles']['native:mail'] = dict(self.d['profiles']['native:engineer'], specialty='email', skills=['mail'])
        self.assertTrue(any(g['reason'] == 'publication-not-authorized' for g in self.plan()['gaps']))
        self.d['publication_targets'].append('mail')
        self.m[0]['specialties'].append('email')
        native = self.plan()['proposed']['native']
        self.assertEqual(native['agents']['mail']['primary'], 'f-1')
        self.assertIn('mail', native['agents']['main']['allowAgents'])
        self.assertEqual(native['routes']['email'], 'mail')
        self.assertEqual(native['agents']['mail']['bundle']['skills'], {'mail': 'email instructions'})

    def test_context_and_receipt_required_at_dispatch(self):
        plan, receipts = self.activate()
        for context, proof in [(None, receipts), ({}, receipts),
                               (plan['contracts']['native:engineer']['bundle'], {})]:
            with self.assertRaises(ValueError):
                dispatch(plan, 'native:engineer', proof, 100, context)
        self.d['poteto'] = ''
        broken = self.plan(receipts)
        with self.assertRaisesRegex(ValueError, 'missing-contract'):
            dispatch(broken, 'native:engineer', receipts, 100, None)

    def test_native_failure_never_claims_both_active(self):
        plan = self.plan()
        self.c, receipts = apply_simulated(plan, self.c, {}, 100, fail_native=True)
        fresh = self.plan(receipts)
        self.assertEqual(fresh['active'], {'cli': True, 'native': False})
        with self.assertRaisesRegex(ValueError, 'runtime-not-activated'):
            dispatch(fresh, 'native:engineer', receipts, 100,
                     fresh['contracts']['native:engineer']['bundle'])

    def test_cross_runtime_family_and_expired_model_evidence(self):
        self.activate()
        self.m.append(dict(self.m[1], id='cli-only-new', order=[99]))
        self.m.append(dict(self.m[0], id='different-family', family='other', order=[99]))
        plan = self.plan()
        self.assertEqual(plan['proposed']['native']['agents']['engineer']['primary'], 'f-1')
        self.assertEqual(plan['proposed']['cli']['workers']['worker']['model'], 'cli-only-new')
        self.assertIn({'executor': 'native:engineer', 'reason': 'other:outside-approved-family'}, plan['gaps'])
        for model in self.m:
            model['expires'] = 99
        blocked = self.plan()
        self.assertEqual(blocked['contracts'], {})
        self.assertTrue(any('model-evidence-expired' in g['reason'] for g in blocked['gaps']))

    def test_expired_incumbent_and_specialty_block(self):
        self.activate()
        self.d['now'] = 201
        plan = self.plan()
        self.assertEqual(plan['contracts'], {})
        self.assertEqual(plan['proposed'], self.c)


if __name__ == '__main__':
    unittest.main(verbosity=2)
