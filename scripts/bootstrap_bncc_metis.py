#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, os, subprocess, sys, time, urllib.request
from pathlib import Path


def request(url: str, path: str, payload=None, timeout=3):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url + path, data=data, headers={"Content-Type": "application/json"} if data else {}, method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main():
    ap=argparse.ArgumentParser(description="Verifica e gera os safetensors BNCC por habilidade via serviço Metis persistente.")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    ap.add_argument("--host", default=os.getenv("OKFFORGE_METIS_HOST","127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.getenv("OKFFORGE_METIS_PORT","19193")))
    ap.add_argument("--no-generate-missing", action="store_true")
    ap.add_argument("--wait", action="store_true", help="Aguarda a varredura completa; sem esta opção apenas agenda a geração.")
    args=ap.parse_args()
    root=Path(args.root).resolve(); url=f"http://{args.host}:{args.port}"
    try:
        health=request(url,"/health")
    except Exception:
        script=root/"scripts"/"metis_skill_service.py"
        cmd=[sys.executable,str(script),"--root",str(root),"--host",args.host,"--port",str(args.port)]
        kwargs={"cwd":str(root)}
        if os.name=="nt":
            kwargs["creationflags"]=subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
            kwargs["stdout"]=subprocess.DEVNULL; kwargs["stderr"]=subprocess.DEVNULL
        else:
            kwargs["start_new_session"]=True; kwargs["stdout"]=subprocess.DEVNULL; kwargs["stderr"]=subprocess.DEVNULL
        subprocess.Popen(cmd,**kwargs)
        last=None
        for _ in range(50):
            try:
                health=request(url,"/health"); break
            except Exception as exc:
                last=exc; time.sleep(.2)
        else: raise SystemExit(f"Serviço Metis não iniciou: {last}")
    result=request(url,"/bootstrap",{"generate_missing":not args.no_generate_missing},timeout=10)
    print(json.dumps(result,ensure_ascii=False))
    if args.wait:
        while True:
            status=request(url,"/bootstrap/status",timeout=10)["bootstrap"]
            print(json.dumps(status,ensure_ascii=False))
            if not status.get("running"): break
            time.sleep(2)

if __name__=="__main__": main()
