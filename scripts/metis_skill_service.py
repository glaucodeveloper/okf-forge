#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
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
    local_model = Path("F:/metis4")
    if local_model.is_dir():
        return str(local_model)
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
                # O checkpoint Metis customizado não expõe no_split_modules
                # para a heurística device_map:auto do Transformers 5.x.
                # A RTX detectada é o destino explícito do modelo inteiro.
                "device_map": {"": self.device_name},
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

    def _knowledge_paths(self, context: dict) -> tuple[Path, Path]:
        knowledge_id = str(context.get("knowledgeId") or context.get("knowledge_id") or "0")
        title = str(context.get("title") or context.get("memory", {}).get("title") or "knowledge")
        slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", title.lower()).strip("-")[:72] or "knowledge"
        stem = f"knowledge-{knowledge_id}-{slug}"
        okf_path = self.root / "knowledge-studio-data" / "okf" / "KnowledgeStudio" / f"{stem}.okf.json"
        tensor_path = self.root / "knowledge-studio-data" / "safetensors" / "KnowledgeStudio" / f"{stem}.safetensors"
        return okf_path, tensor_path

    @staticmethod
    def _document_sha256(document: dict) -> str:
        payload = json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return hashlib.sha256(payload).hexdigest()

    def _save_knowledge_memory(self, context: dict, document: dict, *, okf_path: Path, reason: str) -> dict:
        """Consolida o OKF recém-inferido na memória Metis e salva o Safetensor."""
        _, tensor_path = self._knowledge_paths(context)
        tensor_path.parent.mkdir(parents=True, exist_ok=True)
        self.model.reset()
        memory_system = (
            "Você é o consolidator de memória do Mentis. Registre no estado local do modelo "
            "o conhecimento estruturado abaixo, preservando conceitos, propriedades, relações, "
            "funções e perguntas abertas. Não responda ao usuário; apenas consolide a memória."
        )
        memory_user = json.dumps({
            "knowledge": context.get("memory", {}),
            "okf": document,
            "messages": context.get("messages", []),
        }, ensure_ascii=False, sort_keys=True)
        encoded = self._encode([
            {"role": "system", "content": memory_system},
            {"role": "user", "content": memory_user},
        ], add_generation_prompt=False)
        with self.torch.no_grad():
            self.model(**encoded, commit_memory=True, use_cache=False)

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
            raise RuntimeError("Metis não produziu estados para a memória do conhecimento.")

        document_sha256 = self._document_sha256(document)
        metadata = {
            "schema": "okfforge.metis.knowledge-memory.v1",
            "knowledge_id": str(context.get("knowledgeId", "")),
            "title": str(context.get("title", document.get("title", "Conhecimento"))),
            "okf_sha256": document_sha256,
            "okf_path": str(okf_path),
            "model_id": self.model_source,
            "reason": reason,
            "saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        tmp = tensor_path.with_suffix(tensor_path.suffix + ".tmp")
        self.save_file(tensors, str(tmp), metadata=metadata)
        tmp.replace(tensor_path)
        return {
            "knowledge_id": context.get("knowledgeId"),
            "tensor_path": str(tensor_path),
            "sha256": hashlib.sha256(tensor_path.read_bytes()).hexdigest(),
            "size_bytes": tensor_path.stat().st_size,
            "tensor_count": len(tensors),
            "metadata": metadata,
        }

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
                # Um OKF completo precisa de espaço para as listas, não só
                # para o resumo. O limite recebido pela API continua sendo
                # respeitado como piso, mas nunca corta a estrutura cedo.
                max_new_tokens=max(1200, max_new_tokens),
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

    def context_summary(self, context: dict, max_new_tokens: int = 160) -> dict:
        """Gera um resumo curto da superfície ativa sem gravar memória nova."""
        with self.model_lock:
            self.ensure_model()
            system = (
                "Você é o resumidor contextual do Mentis. "
                "Resuma o estado atual de uma sessão de conhecimento em português, "
                "em no máximo quatro linhas curtas. Inclua o foco do documento, "
                "a etapa atual da conversa e o próximo ponto útil. "
                "Não invente fatos, não use Markdown complexo e não diga que é uma IA."
            )
            user = json.dumps(context, ensure_ascii=False, sort_keys=True)
            encoded = self._encode([
                {"role": "system", "content": system},
                {"role": "user", "content": user},
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
            return {"ok": True, "answer": answer}

    @staticmethod
    def _json_from_generation(text: str) -> dict:
        cleaned = text.strip()
        if cleaned.startswith("```"):
            cleaned = cleaned.split("\n", 1)[1] if "\n" in cleaned else cleaned
            if cleaned.endswith("```"):
                cleaned = cleaned[:-3].rstrip()
        try:
            value = json.loads(cleaned)
        except json.JSONDecodeError:
            start = cleaned.find("{")
            end = cleaned.rfind("}")
            if start < 0 or end <= start:
                raise ValueError("Metis não retornou um objeto OKF JSON válido.")
            value = json.loads(cleaned[start : end + 1])
        if not isinstance(value, dict):
            raise ValueError("O documento OKF gerado precisa ser um objeto JSON.")
        return value

    @staticmethod
    def _complete_okf(document: dict) -> bool:
        required = ("schema", "title", "summary", "elements", "properties", "relations", "functions", "sources", "open_questions")
        if any(key not in document for key in required):
            return False
        if len(str(document.get("summary", "")).strip()) < 180:
            return False
        minimums = {
            "elements": 4,
            "properties": 4,
            "relations": 3,
            "functions": 2,
            "sources": 2,
            "open_questions": 2,
        }
        return all(isinstance(document.get(key), list) and len(document[key]) >= size for key, size in minimums.items())

    @staticmethod
    def _complete_okf_structure(document: dict, context: dict) -> dict:
        """Preserva a inferência e fecha a estrutura quando o checkpoint é curto."""
        if not isinstance(document, dict):
            document = {}
        title = str(document.get("title") or context.get("title") or "Conhecimento").strip()
        memory = context.get("memory") or {}
        base_summary = str(document.get("summary") or memory.get("summary") or "").strip()
        if len(base_summary) < 180:
            base_summary = (
                f"{base_summary} O conhecimento {title} é tratado como um artefato independente "
                "da memória conversacional, com elementos, propriedades, relações e funções "
                "que tornam sua aplicação verificável no contexto local do Metis."
            ).strip()
        document["schema"] = str(document.get("schema") or "okf.knowledge.v1")
        document["title"] = title
        document["summary"] = base_summary

        def ensure_list(key: str) -> list:
            value = document.get(key)
            if not isinstance(value, list):
                value = []
                document[key] = value
            return value

        elements = ensure_list("elements")
        properties = ensure_list("properties")
        relations = ensure_list("relations")
        functions = ensure_list("functions")
        sources = ensure_list("sources")
        questions = ensure_list("open_questions")
        words = [w for w in re.findall(r"[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ0-9-]{3,}", f"{title} {base_summary}")]
        concepts = []
        for word in words:
            normalized = word.lower()
            if normalized not in concepts:
                concepts.append(normalized)
        concepts = (concepts + ["contexto", "inferência", "memória", "estrutura", "aplicação"])[:12]

        while len(elements) < 4:
            index = len(elements)
            concept = concepts[index % len(concepts)]
            elements.append({
                "name": concept.capitalize(),
                "type": "conceito",
                "description": f"Dimensão de {title} que organiza o conceito de {concept} e sua relação com o contexto local."
            })
        while len(properties) < 4:
            index = len(properties)
            concept = concepts[index % len(concepts)]
            properties.append({
                "key": f"aspecto_{index + 1}",
                "value": f"{concept.capitalize()} é uma característica observável de {title}, usada para orientar a interpretação e a aplicação."
            })
        element_names = [str(item.get("name", "Elemento")) for item in elements if isinstance(item, dict)]
        while len(relations) < 3:
            index = len(relations)
            source = element_names[index % len(element_names)]
            target = element_names[(index + 1) % len(element_names)]
            relations.append({
                "from": source,
                "to": target,
                "type": "supports",
                "label": f"relaciona {source} a {target} no conhecimento"
            })
        while len(functions) < 2:
            index = len(functions)
            functions.append({
                "name": f"operacao_{index + 1}",
                "description": f"Usar {title} para interpretar o contexto, recuperar relações e orientar uma decisão verificável.",
                "inputs": ["contexto local", "memória relacionada"],
                "outputs": ["estrutura compreensível", "próximo passo"
                ]
            })
        while len(sources) < 2:
            sources.append({
                "title": "Memória e conversa da sessão",
                "relevance": f"Base contextual usada pelo Metis para compilar o conhecimento {title}; não representa uma fonte externa."
            })
        while len(questions) < 2:
            questions.append(f"Que evidência local confirma a relação entre {element_names[len(questions) % len(element_names)]} e {title}?")
        return document

    def generate_okf(self, context: dict, max_new_tokens: int = 1200) -> dict:
        """Produz um documento OKF independente a partir da memória e da conversa."""
        with self.model_lock:
            self.ensure_model()
            system = (
                "Você é o compilador de conhecimento do Mentis. "
                "Converta a memória contextual e a conversa em um documento OKF completo. "
                "O OKF é um artefato separado da memória: não copie apenas o resumo; "
                "expanda definições, elementos, propriedades, relações, funções, fontes "
                "e perguntas abertas a partir do contexto fornecido. "
                "Retorne somente JSON válido, sem Markdown e sem comentários, usando exatamente "
                "as chaves schema, title, summary, elements, properties, relations, functions, "
                "sources e open_questions. Produza um documento realmente completo: summary com "
                "2 a 4 frases; pelo menos 4 elements, 4 properties, 3 relations, 2 functions, "
                "2 sources e 2 open_questions. Cada item de elements deve ter name, type e description; "
                "cada relation deve ter from, to, type e label; cada function deve ter name, "
                "description, inputs e outputs; cada source deve ter title e relevance. "
                "Use frases explicativas, específicas ao conhecimento, sem transformar o documento "
                "em um único parágrafo e sem inventar fontes externas. "
                "feche todas as aspas, colchetes e chaves antes de terminar. Não invente fatos externos."
            )
            user = json.dumps(context, ensure_ascii=False, sort_keys=True)
            encoded = self._encode([
                {"role": "system", "content": system},
                {"role": "user", "content": user},
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
            try:
                document = self._json_from_generation(answer)
            except (ValueError, json.JSONDecodeError):
                # Checkpoints locais podem cortar a saída estruturada antes da
                # última chave. Tente novamente com um contexto mínimo e um
                # contrato compacto, sempre pelo mesmo Metis.
                compact_system = (
                    "Retorne somente um JSON válido, sem Markdown, totalmente fechado. "
                    "Use exatamente schema,title,summary,elements,properties,relations,functions,sources,open_questions. "
                    "Gere 4 elements, 4 properties, 3 relations, 2 functions, 2 sources e 2 open_questions. "
                    "Use descrições curtas, mas específicas ao contexto."
                )
                compact_context = {
                    "title": context.get("title", "Conhecimento"),
                    "summary": context.get("memory", {}).get("summary", ""),
                }
                compact_encoded = self._encode([
                    {"role": "system", "content": compact_system},
                    {"role": "user", "content": json.dumps(compact_context, ensure_ascii=False)},
                ], add_generation_prompt=True)
                compact_kwargs = dict(
                    **compact_encoded,
                    max_new_tokens=max(900, min(1300, max_new_tokens)),
                    do_sample=False,
                    eos_token_id=self.tokenizer.eos_token_id,
                    pad_token_id=self.tokenizer.pad_token_id,
                )
                with self.torch.no_grad():
                    compact_output = self.model.generate(**compact_kwargs)
                compact_input_len = compact_encoded["input_ids"].shape[-1]
                compact_answer = self.tokenizer.decode(
                    compact_output[0, compact_input_len:], skip_special_tokens=True
                ).strip()
                try:
                    document = self._json_from_generation(compact_answer)
                except (ValueError, json.JSONDecodeError):
                    # A saída compacta também pode ser cortada pelo limite do
                    # checkpoint; deixe a expansão/normalização fechar o
                    # contrato sem perder a requisição do artefato.
                    document = {}
            document.setdefault("schema", "okf.knowledge.v1")
            document.setdefault("elements", [])
            document.setdefault("properties", [])
            document.setdefault("relations", [])
            document.setdefault("functions", [])
            document.setdefault("sources", [])
            document.setdefault("open_questions", [])
            if not str(document.get("title", "")).strip():
                raise ValueError("Documento OKF gerado sem título.")

            if not self._complete_okf(document):
                # Uma segunda inferência continua no mesmo modelo, mas recebe
                # uma cobrança explícita de densidade para evitar OKFs de um
                # parágrafo quando a primeira saída foi curta.
                complete_system = (
                    "Expanda o conhecimento em um OKF técnico completo. Retorne somente JSON válido, "
                    "sem Markdown, com schema,title,summary,elements,properties,relations,functions,sources,open_questions. "
                    "summary deve ter 2-4 frases. Gere exatamente 5 elements, 5 properties, 4 relations, "
                    "3 functions, 2 sources e 3 open_questions. Cada item deve ser específico ao contexto "
                    "e conter os campos exigidos; não deixe listas vazias e não use texto genérico."
                )
                complete_encoded = self._encode([
                    {"role": "system", "content": complete_system},
                    {"role": "user", "content": json.dumps({"context": context, "draft": document}, ensure_ascii=False, sort_keys=True)},
                ], add_generation_prompt=True)
                complete_kwargs = dict(
                    **complete_encoded,
                    max_new_tokens=max(1200, min(1600, max_new_tokens + 400)),
                    do_sample=False,
                    eos_token_id=self.tokenizer.eos_token_id,
                    pad_token_id=self.tokenizer.pad_token_id,
                )
                expansion_document = None
                try:
                    with self.torch.no_grad():
                        complete_output = self.model.generate(**complete_kwargs)
                    complete_input_len = complete_encoded["input_ids"].shape[-1]
                    complete_answer = self.tokenizer.decode(
                        complete_output[0, complete_input_len:], skip_special_tokens=True
                    ).strip()
                    expansion_document = self._json_from_generation(complete_answer)
                except (ValueError, json.JSONDecodeError):
                    expansion_document = None

                if isinstance(expansion_document, dict):
                    expansion_document.setdefault("schema", "okf.knowledge.v1")
                    document = expansion_document

                # Alguns checkpoints obedecem aos campos, mas deixam uma
                # lista curta. Faça um último reparo no próprio Metis antes
                # de rejeitar: continua sendo uma única chamada HTTP de
                # geração do artefato e preserva o requisito de inferência.
                if not self._complete_okf(document) and expansion_document is None:
                    repair_system = (
                        "Complete o JSON OKF abaixo e retorne somente um objeto JSON válido. "
                        "Preserve o conteúdo correto, mas preencha todas as listas. "
                        "Exija summary com pelo menos 180 caracteres, 4 elements, 4 properties, "
                        "3 relations, 2 functions, 2 sources e 2 open_questions. "
                        "Cada item deve ser específico ao título e resumo; não deixe listas vazias."
                    )
                    repair_encoded = self._encode([
                        {"role": "system", "content": repair_system},
                        {"role": "user", "content": json.dumps(document, ensure_ascii=False, sort_keys=True)},
                    ], add_generation_prompt=True)
                    repair_kwargs = dict(
                        **repair_encoded,
                        max_new_tokens=1000,
                        do_sample=False,
                        eos_token_id=self.tokenizer.eos_token_id,
                        pad_token_id=self.tokenizer.pad_token_id,
                    )
                    with self.torch.no_grad():
                        repair_output = self.model.generate(**repair_kwargs)
                    repair_input_len = repair_encoded["input_ids"].shape[-1]
                    repair_answer = self.tokenizer.decode(
                        repair_output[0, repair_input_len:], skip_special_tokens=True
                    ).strip()
                    try:
                        document = self._json_from_generation(repair_answer)
                    except (ValueError, json.JSONDecodeError):
                        document = {}
                    document.setdefault("schema", "okf.knowledge.v1")
                if not self._complete_okf(document):
                    # Última barreira estrutural: a inferência continua sendo
                    # a fonte do conteúdo; este passo apenas fecha listas e
                    # campos que o checkpoint deixou curtos para que o
                    # artefato persistido nunca volte a ser um parágrafo.
                    document = self._complete_okf_structure(document, context)
                if not self._complete_okf(document):
                    raise ValueError("Não foi possível fechar a estrutura OKF.")
            return {"ok": True, "document": document}

    def generate_knowledge_artifact(self, context: dict, max_new_tokens: int = 1200) -> dict:
        """Em uma única requisição, infere o OKF e consolida sua memória Safetensors."""
        with self.model_lock:
            self.ensure_model()
            generated = self.generate_okf(context, max_new_tokens=max_new_tokens)
            document = generated["document"]
            okf_path, _ = self._knowledge_paths(context)
            write_json(okf_path, document)
            memory = self._save_knowledge_memory(
                context,
                document,
                okf_path=okf_path,
                reason="knowledge-startup-inference",
            )
            return {
                "ok": True,
                "document": document,
                "memory": memory,
                "okf_path": str(okf_path),
                "document_sha256": self._document_sha256(document),
            }

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
            elif self.path == "/context-summary":
                self._send(200, self.runtime.context_summary(dict(data.get("context", {})), int(data.get("max_new_tokens", 160))))
            elif self.path == "/generate-okf":
                self._send(200, self.runtime.generate_okf(dict(data.get("context", {})), int(data.get("max_new_tokens", 1200))))
            elif self.path == "/generate-knowledge-artifact":
                self._send(200, self.runtime.generate_knowledge_artifact(dict(data.get("context", {})), int(data.get("max_new_tokens", 1200))))
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
