#!/usr/bin/env python3
from __future__ import annotations
import argparse, json
from pathlib import Path


def main():
    ap=argparse.ArgumentParser(description="Verifica a relação matéria → habilidade → OKF → safetensor no OKF Forge.")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    ap.add_argument("--strict-tensors", action="store_true", help="Retorna código 2 se algum safetensor estiver ausente ou desatualizado.")
    args=ap.parse_args(); root=Path(args.root).resolve()
    manifest=json.load(open(root/'knowledge-studio-data/bncc/bncc_skill_manifest.json',encoding='utf-8'))
    try:
        from safetensors import safe_open
    except Exception:
        safe_open=None
    report={"skills":len(manifest['skills']),"okf_ok":0,"okf_missing":[],"tensor_ok":0,"tensor_missing":[],"tensor_stale":[],"tensor_invalid":[]}
    for skill in manifest['skills']:
        op=root/skill['okf_path']; tp=root/skill['tensor_path']
        if op.is_file(): report['okf_ok']+=1
        else: report['okf_missing'].append(skill['code'])
        if not tp.is_file(): report['tensor_missing'].append(skill['code']); continue
        if safe_open is None:
            report['tensor_invalid'].append({"code":skill['code'],"error":"safetensors não instalado; conteúdo não validado"}); continue
        try:
            with safe_open(str(tp),framework='pt',device='cpu') as f:
                md=dict(f.metadata() or {}); keys=list(f.keys())
            if not keys:
                report['tensor_invalid'].append({"code":skill['code'],"error":"arquivo sem tensores"})
            elif md.get('okf_sha256') != skill['okf_sha256']:
                report['tensor_stale'].append(skill['code'])
            elif md.get('skill_code') != skill['code']:
                report['tensor_invalid'].append({"code":skill['code'],"error":"metadata skill_code divergente"})
            else: report['tensor_ok']+=1
        except Exception as exc:
            report['tensor_invalid'].append({"code":skill['code'],"error":str(exc)})
    report['all_okfs']=report['okf_ok']==report['skills']
    report['all_tensors']=report['tensor_ok']==report['skills']
    print(json.dumps(report,ensure_ascii=False,indent=2))
    if not report['all_okfs']: raise SystemExit(1)
    if args.strict_tensors and not report['all_tensors']: raise SystemExit(2)

if __name__=='__main__': main()
