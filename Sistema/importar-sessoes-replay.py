#!/usr/bin/env python3
"""Importa telemetrias de sessoes/exportacoes para replay no Omegas Lab."""
from __future__ import annotations

import argparse
import json
import zipfile
from datetime import datetime, timezone
from pathlib import Path


def number(obj, *names, default=0.0):
    for name in names:
        value = obj.get(name)
        if value is not None:
            try:
                return float(value)
            except (TypeError, ValueError):
                pass
    return default


def fuel(value: object) -> str:
    text = str(value or '').upper()
    if text in ('GNV', 'CNG'):
        return 'CNG'
    if 'GASOL' in text or text == 'PETROL':
        return 'PETROL'
    return 'TRANSITION'


def normalize(raw: dict, source: str, timestamp: str | None = None) -> dict | None:
    rpm = int(round(number(raw, 'rpm')))
    map_bar = number(raw, 'mapBar', 'map_bar', 'load_bar')
    petrol = number(raw, 'petrolMs', 'petrol_ms')
    gas = number(raw, 'gasMs', 'gas_ms_diagnostic', 'gas_ms')
    if rpm < 0 or map_bar < 0 or petrol < 0 or gas < 0:
        return None
    selected_fuel = fuel(raw.get('fuel'))
    cutoff = bool(raw.get('cutoff', rpm > 1200 and petrol < .8))
    if rpm < 200:
        state = 'OFF'
    elif cutoff:
        state = 'CUTOFF'
    elif map_bar < .38 and rpm < 1300:
        state = 'IDLE'
    elif map_bar < .55 and rpm < 3200:
        state = 'CRUISE'
    elif map_bar >= .70 or rpm >= 3200:
        state = 'ACCEL'
    else:
        state = 'LOAD'
    return {
        'rpm': rpm,
        'petrolMs': round(petrol, 3),
        'gasMs': round(0 if selected_fuel == 'PETROL' else gas, 3),
        'mapBar': round(map_bar, 4),
        'pressureBar': round(number(raw, 'pressureBar', 'gas_pressure_abs_bar', default=1.1), 4),
        'waterC': int(round(number(raw, 'waterC', 'water_c', default=25))),
        'gasC': int(round(number(raw, 'gasC', 'gas_c', default=25))),
        'levelPercent': int(round(number(raw, 'levelPercent', 'level_percent', default=68))),
        'dynamicCorrection': int(round(number(raw, 'dynamicCorrection', 'dynamic_correction'))),
        'fuel': selected_fuel,
        'cutoff': cutoff,
        'stable': bool(raw.get('stable', selected_fuel == 'CNG' and state in ('CRUISE', 'LOAD'))),
        'behaviorState': state,
        'source': source,
        'sourceTimestamp': timestamp or '',
    }


def samples_from_jsonl(text: str, source: str):
    for line in text.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get('type') == 'telemetry':
            candidate = event.get('data', {})
        elif event.get('type') == 'state-snapshot':
            candidate = event.get('state', {})
        elif {'rpm', 'mapBar'} <= event.keys() or {'rpm', 'load_bar'} <= event.keys():
            candidate = event
        else:
            continue
        if isinstance(candidate, dict):
            sample = normalize(candidate, source, event.get('timestamp'))
            if sample:
                yield sample


def samples_from_json(text: str, source: str):
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return
    values = value if isinstance(value, list) else [value]
    for candidate in values:
        if isinstance(candidate, dict):
            sample = normalize(candidate, source, candidate.get('timestamp') or candidate.get('publishedAt'))
            if sample:
                yield sample


def import_path(path: Path):
    if path.is_dir():
        for child in sorted(path.rglob('*')):
            if child.suffix.lower() in ('.jsonl', '.json'):
                yield from import_path(child)
        return
    suffix = path.suffix.lower()
    if suffix == '.zip':
        try:
            with zipfile.ZipFile(path) as archive:
                for name in archive.namelist():
                    if name.lower().endswith('.jsonl'):
                        yield from samples_from_jsonl(archive.read(name).decode('utf-8', errors='ignore'), f'{path.name}:{name}')
                    elif name.lower().endswith('.json'):
                        yield from samples_from_json(archive.read(name).decode('utf-8', errors='ignore'), f'{path.name}:{name}')
        except zipfile.BadZipFile:
            return
    elif suffix in ('.jsonl', '.log', '.txt'):
        yield from samples_from_jsonl(path.read_text(encoding='utf-8', errors='ignore'), path.name)
    elif suffix == '.json':
        yield from samples_from_json(path.read_text(encoding='utf-8', errors='ignore'), path.name)


def main():
    parser = argparse.ArgumentParser(description='Importa sessoes/logs de telemetria para replay no Omegas Lab.')
    parser.add_argument('inputs', nargs='+')
    parser.add_argument('-o', '--output', required=True)
    args = parser.parse_args()
    inputs = [Path(item) for item in args.inputs]
    samples = []
    seen = set()
    for path in inputs:
        for sample in import_path(path):
            key = tuple(sample[name] for name in ('rpm', 'petrolMs', 'gasMs', 'mapBar', 'pressureBar', 'fuel', 'sourceTimestamp'))
            if key not in seen:
                seen.add(key)
                samples.append(sample)
    result = {
        'schema': 'omegas-replay-v1',
        'createdAt': datetime.now(timezone.utc).isoformat(),
        'sources': [str(path) for path in inputs],
        'sampleCount': len(samples),
        'samples': samples,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'{len(samples)} amostras importadas em {output}')


if __name__ == '__main__':
    main()
