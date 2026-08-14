#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import unicodedata
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

SUBJECT_ORDER = [
    "Língua Portuguesa", "Matemática", "História", "Língua Inglesa",
    "Geografia", "Ciências", "Educação Física", "Arte", "Ensino Religioso",
]


def slug(text: str) -> str:
    normalized = unicodedata.normalize("NFKD", text)
    ascii_text = "".join(ch for ch in normalized if not unicodedata.combining(ch))
    return re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")


def canonical_json(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256_value(value) -> str:
    return hashlib.sha256(canonical_json(value)).hexdigest()


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def main() -> None:
    parser = argparse.ArgumentParser(description="Gera os 730 OKFs canônicos da BNCC/Lumira e o manifesto do OKF Forge.")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    args = parser.parse_args()

    root = Path(args.root).resolve()
    source_dir = root / "data" / "lumira"
    canonical_path = source_dir / "lumira_bncc_efii_habilidades_por_competencias.json"
    context_path = source_dir / "lumira_bncc_efii_habilidades_competencias_eixos_v5.json"
    axes_path = source_dir / "lumira_efii_eixos_por_area_serie_idade_niveis_v5.json"
    progression_path = source_dir / "lumira_okf_efii_progressao_v5.yaml"

    canonical = load_json(canonical_path)
    contextual = load_json(context_path)
    axes_doc = load_json(axes_path)

    contexts_by_code: dict[str, list[dict]] = defaultdict(list)
    for row in contextual.get("records", []):
        contexts_by_code[row["codigo"]].append({
            "series_age_id": row.get("series_age_id", ""),
            "serie": row.get("serie", ""),
            "idade_indicativa": row.get("idade_indicativa", ""),
            "axis_id": row.get("axis_id", ""),
            "axis_name": row.get("axis_name", ""),
            "competencia_primaria": row.get("competencia_primaria", ""),
            "competencias_desenvolvimento": row.get("competencias_desenvolvimento", ""),
            "vertentes_sociais": row.get("vertentes_sociais", ""),
            "axis_mapping_status": row.get("axis_mapping_status", ""),
        })

    axis_by_id = {axis.get("axis_id", ""): axis for axis in axes_doc.get("axes", []) if axis.get("axis_id")}
    output_root = root / "knowledge-studio-data" / "bncc"
    okf_root = output_root / "okf"
    tensor_root = output_root / "safetensors"
    okf_root.mkdir(parents=True, exist_ok=True)
    tensor_root.mkdir(parents=True, exist_ok=True)

    records = canonical.get("records", [])
    subject_counts = defaultdict(int)
    for row in records:
        subject_counts[row.get("componente_fonte", "Sem matéria")] += 1

    subjects = []
    for index, name in enumerate(SUBJECT_ORDER, start=1):
        subjects.append({
            "id": index,
            "name": name,
            "slug": slug(name),
            "skills_count": subject_counts[name],
        })
    subject_id = {subject["name"]: subject["id"] for subject in subjects}

    generated_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    manifest_skills = []

    for skill_id, row in enumerate(records, start=1):
        code = row["codigo"]
        subject = row.get("componente_fonte", "Sem matéria")
        subject_slug = slug(subject)
        contexts = contexts_by_code.get(code, [])
        axis_ids = []
        axis_details = []
        seen_axes = set()
        for context in contexts:
            aid = context.get("axis_id", "")
            if aid and aid not in seen_axes:
                seen_axes.add(aid)
                axis_ids.append(aid)
                if aid in axis_by_id:
                    axis = axis_by_id[aid]
                    axis_details.append({
                        "axis_id": aid,
                        "axis_name": axis.get("axis_name", context.get("axis_name", "")),
                        "academic_topics": axis.get("academic_topics", ""),
                        "formal_system": axis.get("formal_system", ""),
                        "transfer_field": axis.get("transfer_field", ""),
                        "supported_competences": axis.get("supported_competences", []),
                    })

        okf = {
            "schema": "okfforge.bncc.skill.v1",
            "id": f"bncc:{code}",
            "topic_key": f"{subject_slug}/{code}",
            "title": f"{code} — {subject}",
            "kind": "bncc_skill",
            "source": {
                "project": "Lumira",
                "stage": "Ensino Fundamental II",
                "canonical_dataset": canonical_path.name,
                "context_dataset": context_path.name,
                "progression_okf": progression_path.name,
                "mapping_status": row.get("mapeamento_status", ""),
                "bncc_page": row.get("pagina_pdf"),
            },
            "matter": {
                "id": subject_id.get(subject, 0),
                "name": subject,
                "slug": subject_slug,
                "bncc_area": row.get("area_bncc", ""),
            },
            "skill": {
                "code": code,
                "year_block": row.get("ano_bloco", ""),
                "statement": row.get("habilidade", ""),
                "verbs": [x.strip() for x in row.get("verbos_bncc", "").split("|") if x.strip()],
            },
            "development": {
                "primary_competence": row.get("competencia_primaria", ""),
                "competences": [x.strip() for x in row.get("competencias_desenvolvimento", "").split("|") if x.strip()],
                "social_axes": [x.strip() for x in row.get("vertentes_sociais", "").split("|") if x.strip()],
            },
            "curriculum_contexts": contexts,
            "learning_axes": axis_details,
            "study_contract": {
                "purpose": "Estudar, praticar e revisar esta habilidade BNCC com IA mantendo a memória Metis isolada por habilidade.",
                "assistant_scope": "Somente esta habilidade, seus eixos Lumira, relações pedagógicas e histórico de estudo persistido no tensor associado.",
                "evidence_rule": "Distinguir explicação, prática, evidência e progressão. Não alterar o texto normativo da habilidade BNCC.",
                "tensor_update": "Cada troca confirmada na interface de estudo é commitada na memória Metis da habilidade e sobrescreve somente o safetensor deste topic_key.",
            },
            "relations": {
                "matter_has_topic": f"matter:{subject_slug} HAS_TOPIC bncc:{code}",
                "topic_has_okf": f"bncc:{code} HAS_OKF okf:bncc:{code}",
                "okf_compiles_tensor": f"okf:bncc:{code} COMPILES_TO tensor:bncc:{code}",
            },
            "generated_at": generated_at,
        }
        okf_sha = sha256_value(okf)
        okf["source_hash"] = okf_sha

        relative_okf = Path("knowledge-studio-data") / "bncc" / "okf" / subject_slug / f"{code}.okf"
        relative_tensor = Path("knowledge-studio-data") / "bncc" / "safetensors" / subject_slug / f"{code}.safetensors"
        okf_path = root / relative_okf
        okf_path.parent.mkdir(parents=True, exist_ok=True)
        okf_path.write_text(json.dumps(okf, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        okf_file_sha = hashlib.sha256(okf_path.read_bytes()).hexdigest()
        (root / relative_tensor).parent.mkdir(parents=True, exist_ok=True)

        manifest_skills.append({
            "id": skill_id,
            "code": code,
            "topic_key": f"{subject_slug}/{code}",
            "subject_id": subject_id.get(subject, 0),
            "subject": subject,
            "subject_slug": subject_slug,
            "area_bncc": row.get("area_bncc", ""),
            "year_block": row.get("ano_bloco", ""),
            "statement": row.get("habilidade", ""),
            "primary_competence": row.get("competencia_primaria", ""),
            "competences": row.get("competencias_desenvolvimento", ""),
            "social_axes": row.get("vertentes_sociais", ""),
            "axis_ids": axis_ids,
            "axis_names": [a.get("axis_name", "") for a in axis_details],
            "okf_path": relative_okf.as_posix(),
            "tensor_path": relative_tensor.as_posix(),
            "okf_sha256": okf_file_sha,
        })

    manifest = {
        "schema": "okfforge.bncc.manifest.v1",
        "generated_at": generated_at,
        "stage": "Ensino Fundamental II",
        "total_skills": len(manifest_skills),
        "subjects": subjects,
        "skills": manifest_skills,
    }
    manifest_path = output_root / "bncc_skill_manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "ok": True,
        "manifest": str(manifest_path),
        "skills": len(manifest_skills),
        "subjects": subjects,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
