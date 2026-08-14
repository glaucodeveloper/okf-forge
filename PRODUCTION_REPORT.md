# OKF Forge production report

Date: 2026-08-14

## Scope

Validated the BNCC Lumira + Metis-4B package in the OKF Forge application using the GlaucoPlastic runtime from `F:/glaucoplastic/src`.

## Delivered

- BNCC catalog with 730 skills and 730 associated OKF files.
- Frontend flow: subject -> skill -> OKF context -> Metis study memory.
- Declarative GlaucoPlastic handlers for subject navigation, skill opening, study chat, tensor reload/rebuild, OKF, production and settings actions.
- Network Web bridge served by the application runtime, without a parallel HTTP backend.
- `okfforge.nimble` and `config.nims` configured for the current GlaucoPlastic source.
- Existing preview and visual assets retained.

## Validation

- `nim c -d:release -d:glaucoplasticHeadless --out:okfforge_bncc_nw.exe knowledge_studio_app.nim`: passed.
- `GET /`: HTTP 200, rendered HTML returned.
- `GET /__glaucoplastic/health`: `{"ok":true}`.
- `GET /__glaucoplastic/poll`: valid empty incremental payload.
- Rendered HTML contains `data-glauco-handler-click` identities for BNCC and study actions.
- `POST /__glaucoplastic/events`: HTTP 200 with structured bridge response.
- BNCC verifier: 730/730 OKFs present and valid.

## Real limitation

The 730 Metis safetensors are not prebuilt. The package correctly reports them as absent until the Metis-4B checkpoint/runtime and required Python dependencies are installed. No fake `.safetensors` files were generated.

## Startup note

The first validation found a malformed global runtime file at `%LOCALAPPDATA%/KnowledgeStudioApplication/data/orm.json`. It was preserved as `orm.json.invalid-20260814`; the application then initialized a fresh ORM store and started normally.

## Run

```powershell
nimble build
.\okfforge_bncc_nw.exe --nw --nw-port=8766 --nw-host=127.0.0.1
```

Open `http://127.0.0.1:8766/`.
