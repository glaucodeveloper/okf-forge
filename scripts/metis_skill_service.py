#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

MODEL_DEFAULT = "IAAR-Shanghai/Metis-4B"


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def model_source_from_env() -> str:
    for name in (
        "OKFFORGE_METIS_MODEL",
        "GLAUCOPLASTIC_METIS_MODEL_PATH",
        "GLAUCOPLASTIC_METIS_MODEL",
        "GLAUCOPLASTIC_MODEL_PATH",
    ):
        value = os.getenv(name, "").strip()
        if value:
            return value
    return MODEL_DEFAULT


class MetisSkillRuntime:
    def __init__(self, root: Path, device: str, dtype_name: str, quantization: str):
        self.root = root.resolve()
        self.manifest_path = self.root / "knowledge-studio-data" / "bncc" / "bncc_skill_manifest.json"
        self.manifest = read_json(self.manifest_path)
        self.skills = {item["code"]: item for item in self.manifest["skills"]}
        self.device_name = device
        self.dtype_name = dtype_name
        self.quantization = quantization
        self.model_source = model_source_from_env()
        self.model = None
        self.tokenizer = None
        self.torch = None
        self.save_file = None
        self.load_file = None
        self.safe_open = None
        self.current_code: str | None = None
        self.model_lock = threading.RLock()
        self.bootstrap_lock = threading.Lock()
        self.bootstrap_thread: threading.Thread | None = None
        self.bootstrap_state: dict[str, Any] = {
            "running": False,
            "checked": 0,
            "generated": 0,
            "valid": 0,
            "failed": 0,
            "total": len(self.skills),
            "current": "",
            "error": "",
        }

    def _dtype(self):
        torch = self.torch
        return {
            "bfloat16": torch.bfloat16,
            "bf16": torch.bfloat16,
            "float16": torch.float16,
            "fp16": torch.float16,
            "float32": torch.float32,
            "fp32": torch.float32,
        }.get(self.dtype_name.lower(), torch.bfloat16)

    def ensure_model(self):
        if self.model is not None:
            return
        with self.model_lock:
            if self.model is not None:
                return
            import torch
            from safetensors import safe_open
            from safetensors.torch import load_file, save_file
            from transformers import AutoModelForCausalLM, AutoTokenizer

            self.torch = torch
            self.save_file = save_file
            self.load_file = load_file
            self.safe_open = safe_open
            dtype = self._dtype()
            self.tokenizer = AutoTokenizer.from_pretrained(self.model_source, trust_remote_code=True)
            if self.tokenizer.pad_token is None:
                self.tokenizer.pad_token = self.tokenizer.eos_token

            kwargs: dict[str, Any] = {
                "trust_remote_code": True,
                "device_map": "auto",
                "low_cpu_mem_usage": True,
            }
            if self.quantization == "4bit":
                from transformers import BitsAndBytesConfig
                kwargs["quantization_config"] = BitsAndBytesConfig(
                    load_in_4bit=True,
                    bnb_4bit_compute_dtype=dtype,
                    bnb_4bit_quant_type="nf4",
                    bnb_4bit_use_double_quant=True,
                )
                kwargs["dtype"] = dtype
            else:
                kwargs["dtype"] = dtype
            try:
                self.model = AutoModelForCausalLM.from_pretrained(self.model_source, **kwargs)
            except TypeError:
                if "dtype" in kwargs:
                    kwargs["torch_dtype"] = kwargs.pop("dtype")
                self.model = AutoModelForCausalLM.from_pretrained(self.model_source, **kwargs)
            self.model.eval()

    def _skill(self, code: str) -> dict:
        try:
            return self.skills[code]
        except KeyError as exc:
            raise KeyError(f"Habilidade BNCC desconhecida: {code}") from exc

    def _paths(self, code: str) -> tuple[dict, Path, Path]:
        skill = self._skill(code)
        return skill, self.root / skill["okf_path"], self.root / skill["tensor_path"]

    def _current_okf_sha256(self, code: str) -> str:
        _, okf_path, _ = self._paths(code)
        return hashlib.sha256(okf_path.read_bytes()).hexdigest()

    def tensor_info(self, code: str) -> dict:
        skill, okf_path, tensor_path = self._paths(code)
        info = {
            "code": code,
            "okf_path": str(okf_path),
            "tensor_path": str(tensor_path),
            "exists": tensor_path.is_file(),
            "valid": False,
            "stale": True,
            "okf_sha256": self._current_okf_sha256(code),
        }
        if not tensor_path.is_file():
            return info
        try:
            from safetensors import safe_open
            with safe_open(str(tensor_path), framework="pt", device="cpu") as handle:
                metadata = dict(handle.metadata() or {})
                keys = list(handle.keys())
            info["metadata"] = metadata
            info["tensor_count"] = len(keys)
            info["stale"] = metadata.get("okf_sha256") != self._current_okf_sha256(code)
            info["valid"] = bool(keys) and not info["stale"]
        except Exception as exc:
            info["error"] = str(exc)
        return info

    def _apply_chat_template(self, messages: list[dict[str, str]], add_generation_prompt: bool) -> str:
        try:
            return self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=add_generation_prompt,
                enable_thinking=False,
            )
        except TypeError:
            return self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=add_generation_prompt,
            )

    def _input_device(self):
        torch = self.torch
        try:
            return next(self.model.parameters()).device
        except StopIteration:
            return torch.device(self.device_name)

    def _encode(self, messages: list[dict[str, str]], add_generation_prompt: bool):
        text = self._apply_chat_template(messages, add_generation_prompt)
        encoded = self.tokenizer(text, return_tensors="pt", add_special_tokens=False)
        device = self._input_device()
        return {key: value.to(device) for key, value in encoded.items()}

    def _metis_blocks(self):
        model = self.model
        if hasattr(model, "model") and hasattr(model.model, "metis_blocks"):
            return list(model.model.metis_blocks)
        if hasattr(model, "metis_blocks"):
            return list(model.metis_blocks)
        raise RuntimeError("O modelo carregado não expõe metis_blocks; verifique IAAR-Shanghai/Metis-4B + trust_remote_code=True.")

    def _save_memory(self, code: str, *, reason: str, extra_metadata: dict[str, str] | None = None) -> dict:
        skill, _, tensor_path = self._paths(code)
        tensor_path.parent.mkdir(parents=True, exist_ok=True)
        tensors = {}
        for index, layer in enumerate(self._metis_blocks()):
            memory = getattr(layer, "local_memory", None)
            if memory is None:
                continue
            state = getattr(memory, "state", None)
            if state is not None:
                tensors[f"layer.{index}.state"] = state.detach().to("cpu").contiguous()
            key_state = getattr(memory, "key_state", None)
            if key_state is not None:
                tensors[f"layer.{index}.key_state"] = key_state.detach().to("cpu").contiguous()
        if not tensors:
            raise RuntimeError("Metis não produziu nenhum tensor de memória local para a habilidade.")
        metadata = {
            "schema": "okfforge.metis.skill-memory.v1",
            "skill_code": code,
            "topic_key": skill["topic_key"],
            "subject": skill["subject"],
            "okf_sha256": self._current_okf_sha256(code),
            "model_id": self.model_source,
            "reason": reason,
            "saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        if extra_metadata:
            metadata.update({str(k): str(v) for k, v in extra_metadata.items()})
        tmp = tensor_path.with_suffix(tensor_path.suffix + ".tmp")
        self.save_file(tensors, str(tmp), metadata=metadata)
        tmp.replace(tensor_path)
        digest = hashlib.sha256(tensor_path.read_bytes()).hexdigest()
        return {
            "code": code,
            "tensor_path": str(tensor_path),
            "sha256": digest,
            "size_bytes": tensor_path.stat().st_size,
            "tensor_count": len(tensors),
            "metadata": metadata,
        }

    def _load_memory_file(self, code: str) -> dict:
        skill, _, tensor_path = self._paths(code)
        payload = self.load_file(str(tensor_path), device="cpu")
        blocks = self._metis_blocks()
        loaded = 0
        for index, layer in enumerate(blocks):
            memory = getattr(layer, "local_memory", None)
            if memory is None:
                continue
            state = payload.get(f"layer.{index}.state")
            if state is None:
                continue
            layer_device = self._input_device()
            try:
                layer_device = next(layer.parameters()).device
            except (StopIteration, AttributeError):
                pass
            state = state.to(layer_device)
            key_state = payload.get(f"layer.{index}.key_state")
            if key_state is not None:
                key_state = key_state.to(layer_device)
                try:
                    memory.write(state, key_state)
                except TypeError:
                    memory._state = state
                    memory._key_state = key_state
            else:
                memory.write(state)
            loaded += 1
        if loaded == 0:
            raise RuntimeError(f"Safetensor de {code} não contém estados compatíveis com o modelo atual.")
        self.current_code = code
        return {"code": code, "topic_key": skill["topic_key"], "loaded_layers": loaded, "tensor_path": str(tensor_path)}

    def rebuild(self, code: str) -> dict:
        with self.model_lock:
            self.ensure_model()
            skill, okf_path, _ = self._paths(code)
            okf = read_json(okf_path)
            self.model.reset()
            system = (
                "Você está convertendo um OKF BNCC em memória persistente Metis. "
                "Registre a habilidade, matéria, texto normativo, competências, eixos e relações exatamente como fornecidos. "
                "O texto normativo BNCC é imutável."
            )
            user = json.dumps(okf, ensure_ascii=False, sort_keys=True)
            encoded = self._encode([
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ], add_generation_prompt=False)
            with self.torch.no_grad():
                self.model(**encoded, commit_memory=True, use_cache=False)
            saved = self._save_memory(code, reason="okf-baseline")
            self.current_code = code
            return {"ok": True, "action": "rebuild", **saved, "topic_key": skill["topic_key"]}

    def ensure_tensor(self, code: str) -> dict:
        info = self.tensor_info(code)
        if info.get("valid"):
            return {"ok": True, "action": "verified", **info}
        return self.rebuild(code)

    def load_skill(self, code: str) -> dict:
        with self.model_lock:
            self.ensure_model()
            ensured = self.ensure_tensor(code)
            if self.current_code != code:
                self.model.reset()
                loaded = self._load_memory_file(code)
            else:
                loaded = {"code": code, "loaded_layers": "already-loaded", "tensor_path": self._paths(code)[2].as_posix()}
            return {"ok": True, "action": "load", "ensured": ensured, "loaded": loaded}

    def study_chat(self, code: str, prompt: str, max_new_tokens: int = 320) -> dict:
        prompt = prompt.strip()
        if not prompt:
            raise ValueError("Prompt de estudo vazio.")
        with self.model_lock:
            self.load_skill(code)
            _, okf_path, _ = self._paths(code)
            okf = read_json(okf_path)
            system = (
                "Você é o tutor de estudo deste tópico BNCC. Responda somente dentro da habilidade e dos eixos do OKF a seguir. "
                "Faça explicações, perguntas, exemplos e correções formativas. Preserve o texto normativo BNCC. "
                "A memória persistente desta conversa pertence exclusivamente a esta habilidade.\n\nOKF:\n" +
                json.dumps(okf, ensure_ascii=False)
            )
            encoded = self._encode([
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ], add_generation_prompt=True)
            generation_kwargs = dict(
                **encoded,
                max_new_tokens=max_new_tokens,
                do_sample=False,
                eos_token_id=self.tokenizer.eos_token_id,
                pad_token_id=self.tokenizer.pad_token_id,
            )
            with self.torch.no_grad():
                output = self.model.generate(**generation_kwargs)
            input_len = encoded["input_ids"].shape[-1]
            answer = self.tokenizer.decode(output[0, input_len:], skip_special_tokens=True).strip()

            commit_encoded = self._encode([
                {"role": "user", "content": prompt},
                {"role": "assistant", "content": answer},
            ], add_generation_prompt=False)
            with self.torch.no_grad():
                self.model(**commit_encoded, commit_memory=True, use_cache=False)
            saved = self._save_memory(code, reason="study-exchange", extra_metadata={"last_prompt_sha256": hashlib.sha256(prompt.encode()).hexdigest()})
            return {"ok": True, "code": code, "answer": answer, "tensor": saved}

    def bootstrap(self, generate_missing: bool = True) -> dict:
        if self.bootstrap_thread and self.bootstrap_thread.is_alive():
            return {"ok": True, "scheduled": False, "bootstrap": self.bootstrap_state}

        def worker():
            with self.bootstrap_lock:
                state = {
                    "running": True, "checked": 0, "generated": 0, "valid": 0,
                    "failed": 0, "total": len(self.skills), "current": "", "error": "",
                }
                self.bootstrap_state = state
                for code in self.skills:
                    state["current"] = code
                    try:
                        info = self.tensor_info(code)
                        state["checked"] += 1
                        if info.get("valid"):
                            state["valid"] += 1
                        elif generate_missing:
                            self.rebuild(code)
                            state["generated"] += 1
                    except Exception as exc:
                        state["failed"] += 1
                        state["error"] = f"{code}: {exc}"
                    self.bootstrap_state = dict(state)
                state["running"] = False
                state["current"] = ""
                self.bootstrap_state = dict(state)

        self.bootstrap_thread = threading.Thread(target=worker, name="okfforge-bncc-bootstrap", daemon=True)
        self.bootstrap_thread.start()
        return {"ok": True, "scheduled": True, "bootstrap": self.bootstrap_state}

    def health(self) -> dict:
        return {
            "ok": True,
            "service": "okfforge-metis-skill-service",
            "model_source": self.model_source,
            "model_loaded": self.model is not None,
            "current_code": self.current_code,
            "skills": len(self.skills),
            "bootstrap": self.bootstrap_state,
        }


class Handler(BaseHTTPRequestHandler):
    runtime: MetisSkillRuntime = None  # type: ignore

    def log_message(self, format, *args):
        print("[OKF Forge Metis]", format % args)

    def _send(self, status: int, payload: dict):
        body = json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict:
        size = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(size) if size else b"{}"
        return json.loads(raw.decode("utf-8")) if raw else {}

    def do_GET(self):
        try:
            if self.path == "/health":
                self._send(200, self.runtime.health())
                return
            if self.path == "/bootstrap/status":
                self._send(200, {"ok": True, "bootstrap": self.runtime.bootstrap_state})
                return
            self._send(404, {"ok": False, "error": "not-found"})
        except Exception as exc:
            self._send(500, {"ok": False, "error": str(exc)})

    def do_POST(self):
        try:
            data = self._body()
            if self.path == "/bootstrap":
                self._send(200, self.runtime.bootstrap(bool(data.get("generate_missing", True))))
            elif self.path == "/verify":
                self._send(200, {"ok": True, "tensor": self.runtime.tensor_info(str(data["code"]))})
            elif self.path == "/rebuild":
                self._send(200, self.runtime.rebuild(str(data["code"])))
            elif self.path == "/load":
                self._send(200, self.runtime.load_skill(str(data["code"])))
            elif self.path == "/chat":
                self._send(200, self.runtime.study_chat(str(data["code"]), str(data.get("prompt", "")), int(data.get("max_new_tokens", 320))))
            else:
                self._send(404, {"ok": False, "error": "not-found"})
        except Exception as exc:
            traceback.print_exc()
            self._send(500, {"ok": False, "error": str(exc), "type": type(exc).__name__})


def main() -> None:
    parser = argparse.ArgumentParser(description="Serviço Metis persistente por habilidade BNCC do OKF Forge.")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--host", default=os.getenv("OKFFORGE_METIS_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.getenv("OKFFORGE_METIS_PORT", "19193")))
    parser.add_argument("--device", default=os.getenv("OKFFORGE_METIS_DEVICE", "cuda:0"))
    parser.add_argument("--dtype", default=os.getenv("OKFFORGE_METIS_DTYPE", "bfloat16"))
    parser.add_argument("--quantization", choices=["4bit", "none"], default=os.getenv("OKFFORGE_METIS_QUANTIZATION", "4bit"))
    args = parser.parse_args()

    runtime = MetisSkillRuntime(Path(args.root), args.device, args.dtype, args.quantization)
    Handler.runtime = runtime
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(json.dumps({"service": "okfforge-metis-skill-service", "host": args.host, "port": args.port, "root": str(runtime.root), "model": runtime.model_source}, ensure_ascii=False))
    server.serve_forever()


if __name__ == "__main__":
    main()
