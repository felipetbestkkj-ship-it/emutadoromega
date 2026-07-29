#!/usr/bin/env python3
"""Gera um modelo estatistico agregado a partir de exports OMEGAS.
Nao reproduz sessoes; aprende faixas conjuntas por estado, combustivel, RPM e carga.
"""
from __future__ import annotations
import argparse, json, math, zipfile
from collections import defaultdict
from pathlib import Path

FIELDS = ['rpm','load_bar','petrol_ms','gas_ms_diagnostic','gas_pressure_abs_bar','pressure_diff_bar','water_c','gas_c','dynamic_correction']

def classify(d):
    fuel_text=str(d.get('fuel','')).upper()
    fuel='CNG' if fuel_text in ('GNV','CNG') else ('PETROL' if 'GASOL' in fuel_text else 'TRANSITION')
    rpm=float(d.get('rpm') or 0); load=float(d.get('load_bar') or 0); petrol=float(d.get('petrol_ms') or 0)
    if rpm < 200: state='OFF'
    elif rpm > 1200 and petrol < .8: state='CUTOFF'
    elif load < .38 and rpm < 1300: state='IDLE'
    elif load < .55 and rpm < 3200: state='CRUISE'
    elif load >= .70 or rpm >= 3200: state='ACCEL'
    else: state='LOAD'
    return fuel,state,min(7,int(rpm//750)),min(5,max(0,int(load/.2)))

def quantile(vals,p):
    vals=sorted(vals)
    return vals[min(len(vals)-1,int((len(vals)-1)*p))]

def iter_telemetry(paths):
    for path in paths:
        try:
            with zipfile.ZipFile(path) as z:
                for name in z.namelist():
                    if not name.endswith('.jsonl'): continue
                    for raw in z.read(name).decode('utf-8',errors='ignore').splitlines():
                        try: obj=json.loads(raw)
                        except json.JSONDecodeError: continue
                        if obj.get('type')=='telemetry':
                            d=obj.get('data',{})
                            if all(k in d for k in ('rpm','load_bar','petrol_ms')): yield d
        except zipfile.BadZipFile:
            continue

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('inputs',nargs='+')
    ap.add_argument('-o','--output',required=True)
    ns=ap.parse_args()
    buckets=defaultdict(list); count=0
    for d in iter_telemetry(ns.inputs): buckets[classify(d)].append(d); count+=1
    model={'schema':'omegas-behaviour-v1','source':'aggregated-patterns-no-replay','sampleCount':count,'buckets':[]}
    for (fuel,state,rb,lb),items in sorted(buckets.items()):
        if len(items)<8: continue
        out={'fuel':fuel,'state':state,'rpmBin':rb,'loadBin':lb,'count':len(items),'values':{}}
        for f in FIELDS:
            vals=[]
            for item in items:
                try: v=float(item.get(f))
                except (TypeError,ValueError): continue
                if math.isfinite(v): vals.append(v)
            if vals: out['values'][f]={'p10':round(quantile(vals,.1),5),'median':round(quantile(vals,.5),5),'p90':round(quantile(vals,.9),5)}
        model['buckets'].append(out)
    Path(ns.output).parent.mkdir(parents=True,exist_ok=True)
    Path(ns.output).write_text(json.dumps(model,ensure_ascii=False,indent=2),encoding='utf-8')
    print(f'{count} telemetrias -> {len(model["buckets"])} grupos em {ns.output}')
if __name__=='__main__': main()
