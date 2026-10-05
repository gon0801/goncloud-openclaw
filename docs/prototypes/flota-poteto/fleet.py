"""Pure fleet compiler and deliberately fake runtime boundary, Python stdlib only."""
from copy import deepcopy
from hashlib import sha256
import json


def digest(value):
    return sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def reconcile(current, desired, discovered, models, receipts):
    """Return proposed projections + explicit gaps; never mutate inputs or activate."""
    now = desired['now']
    proposed = deepcopy(current)
    gaps, contracts, inventory = [], {}, []
    def gap(key, reason):
        gaps.append({'executor': key, 'reason': reason})
    for executor in discovered:
        runtime, identity = executor['runtime'], executor['id']
        key = runtime + ':' + identity
        inventory.append(key)
        profile = desired['profiles'].get(key)
        if profile is None:
            gap(key, 'needs-profile')
            continue
        if profile['expires'] <= now:
            gap(key, 'specialty-expired')
            continue
        if runtime == 'native' and identity not in desired['publication_targets']:
            gap(key, 'publication-not-authorized')
            continue
        canonical = desired['poteto']
        mapping = desired['mappings'].get(runtime)
        skills = profile['skills']
        if not canonical or not mapping or any(not desired['skills'].get(s) for s in skills):
            gap(key, 'instruction-context-missing')
            continue
        bundle = {'poteto': canonical, 'mapping': mapping,
                  'specialty': profile['specialty'],
                  'skills': {s: desired['skills'][s] for s in skills}}
        bundle_hash = digest(bundle)
        table = proposed[runtime].setdefault('agents' if runtime == 'native' else 'workers', {})
        old = table.get(identity, {})
        incumbent = old.get('primary' if runtime == 'native' else 'model')
        candidates = []
        seen_families = set()
        for model in models:
            if model['runtime'] != runtime:
                continue
            seen_families.add(model['family'])
            if model['family'] != profile['family']:
                continue
            label = model['id']
            if not isinstance(model.get('order'), (tuple, list)) or not model['order'] or any(type(n) is not int for n in model['order']):
                gap(key, label + ':unknown-order')
                continue
            scope = ('runtime', 'account', 'host', 'revision', 'probe_revision')
            if any(model.get(f) != executor.get(f) for f in scope):
                gap(key, label + ':probe-scope-mismatch')
                continue
            if not model.get('stable') or not model.get('probe_ok') or not model.get('source'):
                gap(key, label + ':unverified')
                continue
            if model['expires'] <= now:
                gap(key, label + ':model-evidence-expired')
                continue
            if not set(profile['capabilities']) <= set(model['capabilities']) or profile['specialty'] not in model['specialties']:
                gap(key, label + ':capability-or-specialty-proof-missing')
                continue
            candidates.append(model)
        if not candidates:
            gap(key, 'no-verified-model')
            continue
        selected = max(candidates, key=lambda m: tuple(m['order']))
        old_evidence = next((m for m in models if m['id'] == incumbent and m['runtime'] == runtime and m['account'] == executor['account']), None)
        if incumbent and selected['id'] != incumbent:
            if not old_evidence or not old_evidence.get('order'):
                gap(key, 'incumbent-order-unknown')
                continue
            if tuple(selected['order']) <= tuple(old_evidence['order']):
                gap(key, 'no-verified-successor')
                continue
        entry = deepcopy(old)
        entry['bundle'] = bundle
        entry['bundle_digest'] = bundle_hash
        if runtime == 'native':
            entry['primary'] = selected['id']
            table[identity] = entry
            proposed[runtime].setdefault('models', {}).setdefault(selected['id'], {}).update(family=selected['family'])
            for delegator in profile['delegators']:
                requester = table.setdefault(delegator, {})
                allowed = requester.setdefault('allowAgents', [])
                if identity not in allowed:
                    allowed.append(identity)
            proposed[runtime].setdefault('routes', {})[profile['specialty']] = identity
        else:
            entry['model'] = selected['id']
            entry['argv'] = [arg.replace('{model}', selected['id']) for arg in profile['argv']]
        table[identity] = entry
        contracts[key] = {'runtime': runtime, 'id': identity, 'model': selected['id'],
                          'bundle': bundle, 'bundle_digest': bundle_hash,
                          'expires': min(profile['expires'], selected['expires'])}
        for family in sorted(seen_families - {profile['family']}):
            gap(key, family + ':outside-approved-family')
    generations = {r: digest(proposed[r]) for r in ('native', 'cli')}
    for contract in contracts.values():
        contract['generation'] = generations[contract['runtime']]
    return {'proposed': proposed, 'gaps': gaps, 'inventory': inventory,
            'contracts': contracts, 'generations': generations,
            'changes': [r for r in generations if proposed[r] != current[r]],
            'active': {r: receipts.get(r, {}).get('generation') == generations[r]
                       and receipts.get(r, {}).get('expires', 0) > now for r in generations}}


def apply_simulated(plan, current, receipts, now, fail_native=False):
    """Fake write + readback. Separate receipts expose partial activation."""
    state, observed = deepcopy(current), deepcopy(receipts)
    for runtime in ('cli', 'native'):
        if runtime == 'native' and fail_native:
            continue
        state[runtime] = deepcopy(plan['proposed'][runtime])
        observed[runtime] = {'generation': digest(state[runtime]), 'expires': now + 10}
    return state, observed


def dispatch(plan, key, receipts, now, delivered_bundle, session=None):
    """Simulation of start/direct/resume boundary; no process/session is launched."""
    contract = session if session is not None else plan['contracts'].get(key)
    if not contract or contract['runtime'] + ':' + contract['id'] != key:
        raise ValueError('missing-contract')
    if contract['expires'] <= now:
        raise ValueError('expired-contract')
    receipt = receipts.get(contract['runtime'], {})
    if receipt.get('generation') != contract['generation'] or receipt.get('expires', 0) <= now:
        raise ValueError('runtime-not-activated')
    if not delivered_bundle or digest(delivered_bundle) != contract['bundle_digest']:
        raise ValueError('instruction-delivery-missing')
    return deepcopy(contract)
