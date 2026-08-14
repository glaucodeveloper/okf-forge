# Relatório de Produção: OKF Forge BNCC

**Padrão:** relatório técnico de produção, com rastreabilidade de escopo, evidências de execução, riscos e pendências.

**Data da validação:** 2026-08-14  
**Produto:** OKF Forge 0.1.0  
**Runtime:** GlaucoPlastic em `--nw`  
**Fonte do framework:** `F:/glaucoplastic/src`  
**Repositório:** https://github.com/glaucodeveloper/okf-forge

## 1. Resumo executivo

O pacote BNCC Lumira + Metis-4B foi incorporado ao frontend existente do OKF Forge. A interface agora representa o fluxo:

```text
Matéria BNCC -> habilidade -> OKF da habilidade -> memória Metis -> estudo com IA
```

O aplicativo foi compilado com Nim, iniciado pelo runtime Network Web do GlaucoPlastic e validado nos endpoints nativos de renderização, health, polling e eventos. O projeto contém 730 habilidades e 730 OKFs associados.

## 2. Escopo entregue

### Aplicação e frontend

- Catálogo de matérias e habilidades BNCC.
- Abertura contextual de uma habilidade.
- Exibição do OKF associado à habilidade.
- Chat de estudo contextual por habilidade.
- Ações de carregar e reconstruir memória/tensor Metis.
- Navegação integrada com conversas, canvas, documentos OKF, produções e configurações.
- Preservação do preview HTML e das telas PNG existentes.
- O frontend anterior permanece como shell principal: conversa, chat contextual, mini canvas de processo, grafo de conhecimento e navegação original continuam na entrada `Início`.
- Os gatilhos BNCC/Metis foram incorporados à mesma shell, com acesso por `Habilidades BNCC` e um resumo BNCC no workspace inicial.

### Runtime e integração

- GlaucoPlastic permanece como runtime principal.
- Network Web usa `/`, `/__glaucoplastic/health`, `/__glaucoplastic/poll` e `/__glaucoplastic/events`.
- Eventos visuais usam handlers declarativos do GlaucoPlastic.
- Não foi criado servidor REST paralelo.
- `config.nims` aponta para `F:/glaucoplastic/src`.
- `okfforge.nimble` define o projeto Nim e suas dependências.

### Dados

- 730 habilidades BNCC no manifesto.
- 730 arquivos `.okf` materializados.
- 9 áreas: Língua Portuguesa, Matemática, História, Língua Inglesa, Geografia, Ciências, Educação Física, Arte e Ensino Religioso.
- Safetensors não são falsificados nem substituídos por JSON renomeado.

## 3. Alterações principais

| Arquivo ou diretório | Função |
|---|---|
| `knowledge_studio_app.nim` | Aplicação GlaucoPlastic, estado, ORM, UI, agentes e handlers BNCC/Metis |
| `config.nims` | Importação do GlaucoPlastic em `F:/glaucoplastic/src` |
| `okfforge.nimble` | Manifesto do projeto Nim |
| `data/lumira/` | Dados Lumira BNCC e progressão pedagógica |
| `knowledge-studio-data/bncc/` | Manifesto e 730 OKFs por habilidade |
| `scripts/metis_skill_service.py` | Serviço persistente de memória Metis por habilidade |
| `scripts/bootstrap_bncc_metis.py` | Inicialização/verificação do serviço Metis |
| `scripts/verify_bncc_assets.py` | Verificação de habilidades, OKFs e tensors |
| `scripts/build_bncc_okfs.py` | Geração dos OKFs BNCC |
| `preview.html` | Preview navegável da interface BNCC |
| `PRODUCTION_REPORT.md` | Este relatório |

## 4. Fluxo funcional

1. O usuário abre a aplicação em Network Web.
2. O frontend renderiza o catálogo BNCC por estado GlaucoPlastic.
3. Ao abrir uma habilidade, o handler `Shell.BnccSkillOpen` seleciona o código e solicita o carregamento da memória.
4. O serviço Metis verifica o OKF e o tensor correspondente.
5. O chat envia mensagens no contexto da habilidade selecionada.
6. O estado da memória é persistido no tensor correspondente quando o runtime Metis está disponível.
7. Ao trocar de habilidade, a memória ativa é substituída pelo contexto do novo tópico.

### Composição do frontend

O desenho anterior não foi substituído pelo catálogo BNCC. A composição final usa:

```text
Shell antiga
  ├── Conversas e chatbox
  ├── Mini canvas de processo
  ├── Grafo de conhecimento
  ├── Documentos OKF e Produções
  └── Habilidades BNCC
        ├── gatilho de abertura da habilidade
        ├── carregamento/reconstrução Metis
        └── chat de estudo vinculado ao OKF
```

`Início` voltou a ser a página inicial. O catálogo BNCC é acessado pela navegação `Habilidades BNCC` e também pelo card de integração no workspace inicial.

## 5. Handlers frontend/backend

Os handlers declarativos confirmados no HTML incluem:

- `Shell.Materias`
- `Shell.SubjectOpen`
- `Shell.BnccSkillOpen`
- `Shell.StudySend`
- `Shell.SkillTensorReload`
- `Shell.SkillTensorRebuild`
- `Shell.OpenOkf`
- `Shell.RequestSafetensors`
- `Shell.SaveSettings`

Os valores de eventos são capturados por estado GlaucoPlastic, usando o padrão suportado pelo framework: `states.Campo = eventValue`.

## 6. Evidências de validação

### Compilação

Comando executado:

```powershell
nim c -d:release -d:glaucoplasticHeadless `
  --out:okfforge_bncc_nw.exe knowledge_studio_app.nim
```

Resultado: **passou**. O executável foi gerado em `F:/okf forge/okfforge_bncc_nw.exe`.

### Network Web

| Verificação | Resultado |
|---|---|
| `GET /` | HTTP 200, HTML renderizado |
| Tamanho inicial do HTML | 45.954 bytes |
| `GET /__glaucoplastic/health` | `{"ok":true}` |
| `GET /__glaucoplastic/poll` | `{"ok":true,"properties":[]}` |
| `POST /__glaucoplastic/events` | HTTP 200, resposta estruturada |
| `data-glauco-handler-click` | Presente para BNCC e estudo |

### Dados BNCC

| Item | Resultado |
|---|---:|
| Habilidades no manifesto | 730 |
| OKFs válidos | 730 |
| OKFs ausentes | 0 |
| Safetensors pré-gerados | 0 |

## 7. Pendências reais

Os 730 tensors Metis ainda não estão incluídos no pacote. A geração depende do checkpoint Metis-4B, ambiente Python compatível, pacote `safetensors` e, para inferência prática, hardware adequado. A ausência é reportada como estado real e não impede a existência dos OKFs nem a execução do frontend.

Instalação prevista:

```powershell
pip install -r requirements-metis.txt
python scripts/bootstrap_bncc_metis.py
```

## 8. Recuperação de startup

Durante a primeira execução foi encontrado um `orm.json` inválido no armazenamento global do runtime:

```text
%LOCALAPPDATA%/KnowledgeStudioApplication/data/orm.json
```

O arquivo original foi preservado como `orm.json.invalid-20260814`. O runtime iniciou um armazenamento ORM novo e o servidor Network Web passou a responder normalmente.

## 9. Execução reproduzível

```powershell
cd 'F:/okf forge'
nimble build
./okfforge_bncc_nw.exe --nw --nw-port=8766 --nw-host=127.0.0.1
```

Acessar:

```text
http://127.0.0.1:8766/
```

Para verificar os assets:

```powershell
python scripts/verify_bncc_assets.py --root 'F:/okf forge'
```

## 10. Versionamento e publicação

Repositório criado e publicado:

```text
https://github.com/glaucodeveloper/okf-forge
```

Commits publicados:

- `eeac66e feat: add BNCC OKF Forge frontend`
- `40da265 chore: exclude generated Python cache`

A publicação foi concluída pelo credential helper oficial do `gh`, sem token exposto na URL. O SSH local está cadastrado na conta, mas o transporte SSH deste ambiente recusou a chave durante o push.

## 11. Critério de conclusão

O frontend BNCC está compilável, executável e conectado ao bridge Network Web do GlaucoPlastic. A etapa de inferência Metis permanece condicionada à instalação do checkpoint e do ambiente de execução correspondente.
