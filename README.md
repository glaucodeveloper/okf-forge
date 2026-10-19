# OKF Forge

Studio de conhecimento para estudos BNCC, com catálogo de habilidades, documentos Open Knowledge Format (OKF) associados e fluxo de estudo com IA.

## Escopo documentado

O relatório técnico registra 730 habilidades e 730 documentos OKF, integração do catálogo com memória Metis e uma interface contextual de estudo. Consulte [PRODUCTION_REPORT.md](PRODUCTION_REPORT.md) para escopo, validações, riscos e pendências registrados em 2026-08-14.

## Código e dados

- `knowledge_studio_app.nim`: aplicação principal.
- `data/`: dados de conhecimento e materiais do projeto.
- `scripts/`: preparação e manutenção de dados.
- `config.nims` e `okfforge.nimble`: configuração Nim.

O pacote requer Nim 2.2 ou superior e NimPy. A aplicação também depende do framework GlaucoPlastic e de serviços locais configurados; o relatório técnico descreve o runtime usado na validação.

## Estado

Projeto experimental. O relatório registra uma validação em runtime local, não uma instalação independente pronta para qualquer máquina.
