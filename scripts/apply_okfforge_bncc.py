#!/usr/bin/env python3
from __future__ import annotations
import argparse, shutil, time
from pathlib import Path


def copytree_merge(src: Path, dst: Path):
    for item in src.rglob('*'):
        rel=item.relative_to(src); target=dst/rel
        if item.is_dir(): target.mkdir(parents=True,exist_ok=True)
        else:
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(item,target)


def main():
    ap=argparse.ArgumentParser(description='Aplica a integração BNCC/Metis do OKF Forge a um projeto existente.')
    ap.add_argument('target', nargs='?', default='.')
    ap.add_argument('--app-name', default='knowledge_studio_app.nim')
    args=ap.parse_args()
    package=Path(__file__).resolve().parents[1]; target=Path(args.target).resolve(); target.mkdir(parents=True,exist_ok=True)
    app_target=target/args.app_name
    if app_target.exists():
        stamp=time.strftime('%Y%m%d-%H%M%S'); backup=app_target.with_suffix(app_target.suffix+f'.before-bncc-{stamp}')
        shutil.copy2(app_target,backup); print('backup:',backup)
    shutil.copy2(package/'okf_forge_bncc_app.nim',app_target)
    copytree_merge(package/'scripts',target/'scripts')
    copytree_merge(package/'data',target/'data')
    copytree_merge(package/'knowledge-studio-data'/'bncc',target/'knowledge-studio-data'/'bncc')
    shutil.copy2(package/'requirements-metis.txt',target/'requirements-metis.txt')
    print('aplicado:',target)
    print('app:',app_target)

if __name__=='__main__': main()
