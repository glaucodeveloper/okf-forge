import std/[algorithm, httpclient, json, os, osproc, sequtils, strutils, tables, times]
import glaucoplastic, base64

const
  # Alteração controlada para validar o watcher hot reload do GlaucoPlastic.
  AppTitle = "Mentis — Studio de Hardening de Conhecimento"
  DefaultOwner = "glaucodeveloper"
  DefaultRepo = "conhecimentos-proto"
  DefaultBranch = "main"

let RootDir = getEnv("OKFFORGE_ROOT", currentSourcePath().parentDir)
let DataDir = RootDir / "knowledge-studio-data"
let OkfDir = DataDir / "okf"
let SafetensorsDir = DataDir / "safetensors"
let RepoDir = DataDir / "repository"
let BnccDir = DataDir / "bncc"
let BnccManifestPath = BnccDir / "bncc_skill_manifest.json"
let BnccOkfDir = BnccDir / "okf"
let BnccSafetensorsDir = BnccDir / "safetensors"
let ScriptsDir = RootDir / "scripts"
let MetisServiceEndpoint = getEnv("OKFFORGE_METIS_ENDPOINT", "http://127.0.0.1:19193")

proc markdownToolbarDataUrl(): string =
  let candidates = [
    getAppDir() / "vendor" / "markdown-toolbar-element" / "dist" / "index.js",
    RootDir / "vendor" / "markdown-toolbar-element" / "dist" / "index.js",
    RootDir / "vendor" / "markdown-toolbar-element" / "node_modules" / "@github" / "markdown-toolbar-element" / "dist" / "index.js",
    getCurrentDir() / "vendor" / "markdown-toolbar-element" / "node_modules" / "@github" / "markdown-toolbar-element" / "dist" / "index.js"
  ]
  for candidate in candidates:
    if fileExists(candidate):
      return "data:text/javascript;base64," & encode(readFile(candidate))
  ""

proc knowledgeWysiwygDataUrl(): string =
  let script = """
(() => {
  const escapeHtml = value => String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/\"/g, '&quot;');

  const inlineMarkdown = value => escapeHtml(value)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/__([^_]+)__/g, '<strong>$1</strong>')
    .replace(/\*([^*]+)\*/g, '<em>$1</em>')
    .replace(/_([^_]+)_/g, '<em>$1</em>')
    .replace(/~~([^~]+)~~/g, '<del>$1</del>');

  function markdownToHtml(markdown) {
    const lines = String(markdown ?? '').replace(/\r/g, '').split('\n');
    const html = [];
    let list = '';
    const closeList = () => {
      if (!list) return;
      html.push(`</${list}>`);
      list = '';
    };
    for (const line of lines) {
      if (!line.trim()) { closeList(); continue; }
      let match = line.match(/^(#{1,3})\s+(.+)$/);
      if (match) { closeList(); html.push(`<h${match[1].length}>${inlineMarkdown(match[2])}</h${match[1].length}>`); continue; }
      match = line.match(/^>\s?(.*)$/);
      if (match) { closeList(); html.push(`<blockquote>${inlineMarkdown(match[1])}</blockquote>`); continue; }
      match = line.match(/^[-*]\s+\[([ xX])\]\s+(.+)$/);
      if (match) { closeList(); html.push(`<p class="ks-task-line">${match[1].toLowerCase() === 'x' ? '☑' : '☐'} ${inlineMarkdown(match[2])}</p>`); continue; }
      match = line.match(/^[-*]\s+(.+)$/);
      if (match) { if (list !== 'ul') { closeList(); list = 'ul'; html.push('<ul>'); } html.push(`<li>${inlineMarkdown(match[1])}</li>`); continue; }
      match = line.match(/^\d+\.\s+(.+)$/);
      if (match) { if (list !== 'ol') { closeList(); list = 'ol'; html.push('<ol>'); } html.push(`<li>${inlineMarkdown(match[1])}</li>`); continue; }
      closeList();
      html.push(`<p>${inlineMarkdown(line)}</p>`);
    }
    closeList();
    return html.join('') || '<p><br></p>';
  }

  function nodeMarkdown(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.nodeValue || '';
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    const tag = node.tagName.toLowerCase();
    const children = () => Array.from(node.childNodes).map(nodeMarkdown).join('');
    if (tag === 'br') return '\n';
    if (tag === 'strong' || tag === 'b') return `**${children()}**`;
    if (tag === 'em' || tag === 'i') return `*${children()}*`;
    if (tag === 'del' || tag === 's') return `~~${children()}~~`;
    if (tag === 'code' && node.parentElement?.tagName.toLowerCase() !== 'pre') return `\`${children()}\``;
    if (tag === 'pre') return `\`\`\`\n${node.textContent || ''}\n\`\`\`\n\n`;
    if (/^h[1-3]$/.test(tag)) return `${'#'.repeat(Number(tag[1]))} ${children().trim()}\n\n`;
    if (tag === 'blockquote') return children().split('\n').filter(Boolean).map(line => `> ${line}`).join('\n') + '\n\n';
    if (tag === 'li') return children().trim();
    if (tag === 'ul') return Array.from(node.children).map(item => `- ${nodeMarkdown(item)}`).join('\n') + '\n\n';
    if (tag === 'ol') return Array.from(node.children).map((item, index) => `${index + 1}. ${nodeMarkdown(item)}`).join('\n') + '\n\n';
    if (tag === 'a') return `[${children()}](${node.getAttribute('href') || ''})`;
    if (tag === 'p' || tag === 'div') return `${children()}\n\n`;
    return children();
  }

  const htmlToMarkdown = editor => nodeMarkdown(editor).replace(/\n{3,}/g, '\n\n').trim();
  const setNativeValue = (element, value) => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    if (setter) setter.call(element, value); else element.value = value;
  };

  function wireEditor() {
    const editor = document.querySelector('#knowledge-wysiwyg-editor');
    const state = document.querySelector('#knowledge-markdown-state');
    const toolbar = document.querySelector('#knowledge-markdown-toolbar');
    if (!editor || !state || !toolbar || editor.dataset.wired === 'true') return;
    editor.dataset.wired = 'true';
    let lastSynced = state.value || editor.getAttribute('value') || '';
    editor.innerHTML = markdownToHtml(lastSynced);

    const syncState = () => {
      const markdown = htmlToMarkdown(editor);
      lastSynced = markdown;
      setNativeValue(state, markdown);
      state.dispatchEvent(new Event('change', {bubbles: true}));
    };
    editor.addEventListener('input', syncState);
    editor.addEventListener('blur', syncState);

    const command = (name, value = null) => {
      editor.focus();
      document.execCommand(name, false, value);
      syncState();
    };
    const bindCommand = (selector, name, value = null) => toolbar.querySelector(selector)?.addEventListener('click', event => {
      event.preventDefault();
      event.stopImmediatePropagation();
      command(name, value);
    }, true);
    bindCommand('md-bold', 'bold');
    bindCommand('md-italic', 'italic');
    bindCommand('md-header', 'formatBlock', 'h2');
    bindCommand('md-quote', 'formatBlock', 'blockquote');
    bindCommand('md-code', 'formatBlock', 'pre');
    bindCommand('md-unordered-list', 'insertUnorderedList');
    bindCommand('md-ordered-list', 'insertOrderedList');
    bindCommand('md-task-list', 'insertUnorderedList');
    bindCommand('md-link', 'createLink', 'https://');

    window.setInterval(() => {
      const next = state.value || '';
      if (next !== lastSynced && document.activeElement !== editor) {
        lastSynced = next;
        editor.innerHTML = markdownToHtml(next);
      }
    }, 250);
  }

  wireEditor();
  new MutationObserver(wireEditor).observe(document.documentElement, {childList: true, subtree: true});
})();
"""
  "data:text/javascript;base64," & encode(script)

var opCache = initTable[string, JsonNode]()

var appRef: PlasticApplication

# The ORM primitives are generated by the application macro below; forward
# declarations keep domain helpers defined before the declarative block.
proc ormInsert(orm: PlasticOrmRuntime; entity: string; value: JsonNode): JsonNode
proc ormDelete(orm: PlasticOrmRuntime; entity: string; id: int): bool
proc ormUpdate(orm: PlasticOrmRuntime; entity: string; id: int; patch: JsonNode): JsonNode
proc ormWhere(orm: PlasticOrmRuntime; entity, field: string; expected: JsonNode): JsonNode
proc stateGet(states: PlasticStateRuntime; name: string): JsonNode
proc persistOkf(okf: PlasticOkfRuntime; document: JsonNode): JsonNode
proc stateSet(states: PlasticStateRuntime; name: string; value: JsonNode)

proc nowIso(): string =
  result = utc(now()).format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc ensureDir(path: string) =
  if path.len > 0 and not dirExists(path):
    createDir(path)

proc jsonStr(node: JsonNode; key: string; fallback = ""): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr()
  else:
    fallback

proc jsonInt(node: JsonNode; key: string; fallback = 0): int =
  if node.kind != JObject or not node.hasKey(key):
    return fallback
  case node[key].kind
  of JInt: node[key].getInt()
  of JString:
    try: parseInt(node[key].getStr())
    except ValueError: fallback
  else: fallback

proc safeParseInt(value: string; fallback = 0): int =
  try: parseInt(value)
  except ValueError: fallback

proc jsonArrayJoin(node: JsonNode; key: string; sep = " | "): string =
  if node.kind != JObject or not node.hasKey(key) or node[key].kind != JArray:
    return ""
  var parts: seq[string] = @[]
  for item in node[key].items:
    if item.kind == JString and item.getStr().len > 0:
      parts.add item.getStr()
  parts.join(sep)

proc maskedKey(value: string): string =
  if value.len <= 4:
    return "****"
  "************" & value[^4..^1]

proc payload(value: string): JsonNode =
  if value.len == 0:
    return newJObject()
  try:
    parseJson(value)
  except CatchableError:
    newJObject()

proc opResponse(operation, entityId: string = ""; revision = 0): JsonNode =
  %*{"ok": true, "operation": operation, "entityId": entityId, "revision": revision}

proc opError(operation, code, message: string): JsonNode =
  %*{"ok": false, "operation": operation, "error": {"code": code, "message": message}}

proc responseStatus(response: JsonNode; okMessage, errorMessage: string): string =
  if response.kind == JObject and response.hasKey("ok") and response["ok"].getBool:
    okMessage
  else:
    errorMessage

proc appStateStr(name: string): string =
  let value = stateGet(appRef.statesValue, name)
  case value.kind
  of JString: value.getStr
  of JNull: ""
  else: $value

proc withOpId(operation, opId: string; compute: proc(): JsonNode): JsonNode =
  if opId.len == 0:
    return compute()
  let key = operation & ":" & opId
  if opCache.hasKey(key):
    return opCache[key]
  let value = compute()
  opCache[key] = value
  value

proc allRows(entity: string): seq[JsonNode] =
  result = @[]
  if appRef.ormValue.data.kind != JObject or not appRef.ormValue.data.hasKey(entity):
    return
  let bucket = appRef.ormValue.data[entity]
  if bucket.kind != JArray:
    return
  for item in bucket.items:
    result.add item

proc ormGetById(entity: string; id: int): JsonNode =
  for row in allRows(entity):
    if jsonInt(row, "id") == id:
      return row
  result = newJNull()

proc upsert(entity: string; node: JsonNode): JsonNode =
  result = ormInsert(appRef.ormValue, entity, node)

proc updateEntity(entity: string; id: int; patch: proc(row: var JsonNode)): JsonNode =
  result = ormGetById(entity, id)
  if result.kind == JNull:
    return
  patch(result)
  result = ormUpdate(appRef.ormValue, entity, id, result)

proc sessionList(): seq[JsonNode] =
  result = allRows("ConversationSession")
  result.sort(proc(a, b: JsonNode): int = cmp(jsonStr(b, "updatedAt"), jsonStr(a, "updatedAt")))

proc sessionMessages(sessionId: int): seq[JsonNode] =
  result = @[]
  for row in ormWhere(appRef.ormValue, "ConversationMessage", "sessionId", %sessionId).items:
    result.add row
  result.sort(proc(a, b: JsonNode): int = cmp(jsonInt(a, "sequence"), jsonInt(b, "sequence")))

proc processNodes(processId: int): seq[JsonNode] =
  result = @[]
  for row in ormWhere(appRef.ormValue, "WorkProcessNode", "processId", %processId).items:
    result.add row

proc processEdges(processId: int): seq[JsonNode] =
  result = @[]
  for row in ormWhere(appRef.ormValue, "WorkProcessEdge", "processId", %processId).items:
    result.add row

proc knowledgeList(): seq[JsonNode] =
  allRows("Knowledge")

proc knowledgeByTitle(title: string): JsonNode =
  for row in knowledgeList():
    if jsonStr(row, "title") == title:
      return row
  newJNull()

proc knowledgeRelations(): seq[JsonNode] =
  allRows("KnowledgeRelation")

proc activeSettings(): JsonNode =
  ormGetById("ApplicationSettings", 1)

proc activeSessionId(): int =
  result = stateGet(appRef.statesValue, "ActiveSessionId").getInt()
  if result <= 0 and sessionList().len > 0:
    result = jsonInt(sessionList()[0], "id")

proc activeSession(): JsonNode =
  let sid = activeSessionId()
  if sid > 0:
    result = ormGetById("ConversationSession", sid)
  else:
    result = newJNull()

proc activeProcess(): JsonNode =
  let session = activeSession()
  if session.kind == JNull:
    return newJNull()
  let pid = jsonInt(session, "activeProcessId")
  if pid > 0:
    result = ormGetById("WorkProcess", pid)
  else:
    result = newJNull()

proc activeKnowledge(): JsonNode =
  let session = activeSession()
  if session.kind == JNull:
    return newJNull()
  let kid = jsonInt(session, "graphKnowledgeId")
  if kid > 0:
    result = ormGetById("Knowledge", kid)
  else:
    result = newJNull()

proc nextSequence(sessionId: int): int =
  result = 1
  for row in sessionMessages(sessionId):
    result = max(result, jsonInt(row, "sequence") + 1)

proc ensureSeed() =
  ensureDir(DataDir)
  ensureDir(OkfDir)
  ensureDir(OkfDir / "KnowledgeStudio")
  ensureDir(SafetensorsDir)
  ensureDir(RepoDir)
  if activeSettings().kind == JNull:
    discard upsert("ApplicationSettings", %*{
      "id": 1,
      "applicationKey": getEnv("GLAUCOPLASTIC_APPLICATION_KEY", "ks-" & $epochTime().int64),
      "authorName": getEnv("GLAUCOPLASTIC_AUTHOR_NAME", "Glauco Developer"),
      "okfDirectory": OkfDir,
      "safetensorsDirectory": SafetensorsDir,
      "repositoryOwner": DefaultOwner,
      "repositoryName": DefaultRepo,
      "repositoryBranch": DefaultBranch,
      "repositoryDirectory": RepoDir,
      "createdAt": nowIso(),
      "updatedAt": nowIso()
    })
  if ormGetById("RepositoryTarget", 1).kind == JNull:
    discard upsert("RepositoryTarget", %*{
      "id": 1,
      "applicationSettingsId": 1,
      "owner": DefaultOwner,
      "repository": DefaultRepo,
      "branch": DefaultBranch,
      "directory": RepoDir,
      "lastSyncStatus": "configured",
      "lastSyncAt": nowIso(),
      "lastSyncError": "",
      "createdAt": nowIso(),
      "updatedAt": nowIso(),
      "revision": 1
    })
  if sessionList().len == 0:
    let session = upsert("ConversationSession", %*{
      "title": "Sessão inicial",
      "status": "active",
      "createdAt": nowIso(),
      "updatedAt": nowIso(),
      "author": jsonStr(activeSettings(), "authorName", "Glauco Developer"),
      "activeProcessId": 0,
      "graphKnowledgeId": 0,
      "lastCheckpointAt": ""
    })
    let sid = jsonInt(session, "id")
    let process = upsert("WorkProcess", %*{
      "sessionId": sid,
      "title": "Processo inicial",
      "description": "Fluxo base da conversa.",
      "status": "draft",
      "createdAt": nowIso(),
      "updatedAt": nowIso(),
      "revision": 1
    })
    let pid = jsonInt(process, "id")
    discard upsert("WorkProcessNode", %*{
      "processId": pid,
      "type": "start",
      "label": "Início",
      "description": "Gatilho inicial",
      "x": 60,
      "y": 120,
      "width": 132,
      "height": 60,
      "metadata": "{}",
      "createdAt": nowIso(),
      "updatedAt": nowIso(),
      "revision": 1
    })
    discard upsert("WorkProcessNode", %*{
      "processId": pid,
      "type": "task",
      "label": "Atividade",
      "description": "Tarefa principal",
      "x": 252,
      "y": 120,
      "width": 156,
      "height": 66,
      "metadata": "{}",
      "createdAt": nowIso(),
      "updatedAt": nowIso(),
      "revision": 1
    })
    discard upsert("WorkProcessNode", %*{
      "processId": pid,
      "type": "end",
      "label": "Fim",
      "description": "Encerramento",
      "x": 492,
      "y": 120,
      "width": 132,
      "height": 60,
      "metadata": "{}",
      "createdAt": nowIso(),
      "updatedAt": nowIso(),
      "revision": 1
    })
    discard updateEntity("ConversationSession", sid, proc(row: var JsonNode) =
      row["activeProcessId"] = %pid
      row["updatedAt"] = %nowIso()
    )
    discard upsert("Knowledge", %*{
      "title": "Processo inicial",
      "summary": "Card principal do processo.",
      "type": "process",
      "okfDocumentId": 0,
      "safetensorsPath": "",
      "safetensorsStatus": "missing",
      "safetensorsSha256": "",
      "safetensorsSizeBytes": 0,
      "processId": pid,
      "originSessionId": sid,
      "x": 112,
      "y": 112,
      "createdAt": nowIso(),
      "updatedAt": nowIso(),
      "author": jsonStr(activeSettings(), "authorName", "Glauco Developer"),
      "revision": 1
    })
    stateSet(appRef.statesValue, "ActiveSessionId", %sid)

proc createSession(title: string): JsonNode =
  let row = upsert("ConversationSession", %*{
    "title": if title.len > 0: title else: "Nova conversa",
    "status": "active",
    "createdAt": nowIso(),
    "updatedAt": nowIso(),
    "author": jsonStr(activeSettings(), "authorName", "Glauco Developer"),
    "activeProcessId": 0,
    "graphKnowledgeId": 0,
    "lastCheckpointAt": ""
  })
  let sid = jsonInt(row, "id")
  let process = upsert("WorkProcess", %*{
    "sessionId": sid,
    "title": "Processo de " & jsonStr(row, "title"),
    "description": "Fluxo detectado na conversa.",
    "status": "draft",
    "createdAt": nowIso(),
    "updatedAt": nowIso(),
    "revision": 1
  })
  let pid = jsonInt(process, "id")
  discard upsert("WorkProcessNode", %*{
    "processId": pid,
    "type": "start",
    "label": "Início",
    "description": "Gatilho inicial",
    "x": 60,
    "y": 120,
    "width": 132,
    "height": 60,
    "metadata": "{}",
    "createdAt": nowIso(),
    "updatedAt": nowIso(),
    "revision": 1
  })
  discard updateEntity("ConversationSession", sid, proc(session: var JsonNode) =
    session["activeProcessId"] = %pid
    session["updatedAt"] = %nowIso()
  )
  stateSet(appRef.statesValue, "ActiveSessionId", %sid)
  stateSet(appRef.statesValue, "SessionTitleDraft", %jsonStr(row, "title"))
  stateSet(appRef.statesValue, "SessionRenameDraft", %jsonStr(row, "title"))
  result = row

proc renameSession(sessionId: int; title: string): JsonNode =
  updateEntity("ConversationSession", sessionId, proc(row: var JsonNode) =
    row["title"] = %title
    row["updatedAt"] = %nowIso()
  )

proc archiveSession(sessionId: int): JsonNode =
  updateEntity("ConversationSession", sessionId, proc(row: var JsonNode) =
    row["status"] = %"archived"
    row["updatedAt"] = %nowIso()
  )

proc appendMessage(sessionId: int; role, content: string): JsonNode =
  let row = upsert("ConversationMessage", %*{
    "sessionId": sessionId,
    "role": role,
    "content": content,
    "createdAt": nowIso(),
    "sequence": nextSequence(sessionId)
  })
  discard updateEntity("ConversationSession", sessionId, proc(row: var JsonNode) =
    row["updatedAt"] = %nowIso()
  )
  row

proc createProcessNode(processId: int; nodeType, label, description: string; x, y: int): JsonNode =
  upsert("WorkProcessNode", %*{
    "processId": processId,
    "type": nodeType,
    "label": label,
    "description": description,
    "x": x,
    "y": y,
    "width": if nodeType == "decision": 150 else: 144,
    "height": if nodeType == "decision": 70 else: 62,
    "metadata": "{}",
    "createdAt": nowIso(),
    "updatedAt": nowIso(),
    "revision": 1
  })

proc moveProcessNode(processId, nodeId, x, y: int): JsonNode =
  updateEntity("WorkProcessNode", nodeId, proc(row: var JsonNode) =
    if jsonInt(row, "processId") != processId:
      return
    row["x"] = %x
    row["y"] = %y
    row["updatedAt"] = %nowIso()
    row["revision"] = %(jsonInt(row, "revision", 0) + 1)
  )

proc edgeExists(entity: string; fromId, toId: int): bool =
  for row in allRows(entity):
    if jsonInt(row, "fromNodeId") == fromId and jsonInt(row, "toNodeId") == toId:
      return true
  false

proc createProcessEdge(processId, fromNodeId, toNodeId: int): JsonNode =
  if fromNodeId == toNodeId:
    return opError("process.edge.create", "self-edge", "Não é permitido conectar um nó a ele mesmo.")
  if edgeExists("WorkProcessEdge", fromNodeId, toNodeId):
    return opError("process.edge.create", "duplicate", "Essa aresta já existe.")
  upsert("WorkProcessEdge", %*{
    "processId": processId,
    "fromNodeId": fromNodeId,
    "toNodeId": toNodeId,
    "label": "",
    "condition": "",
    "edgeType": "flow",
    "createdAt": nowIso(),
    "revision": 1
  })

proc createKnowledge(title, summary, kind: string; x, y: int; sessionId = 0; processId = 0; okfDocumentId = 0): JsonNode =
  upsert("Knowledge", %*{
    "title": title,
    "summary": summary,
    "type": kind,
    "okfDocumentId": okfDocumentId,
    "safetensorsPath": "",
    "safetensorsStatus": "missing",
    "safetensorsSha256": "",
    "safetensorsSizeBytes": 0,
    "processId": processId,
    "originSessionId": sessionId,
    "x": x,
    "y": y,
    "createdAt": nowIso(),
    "updatedAt": nowIso(),
    "author": jsonStr(activeSettings(), "authorName", "Glauco Developer"),
    "revision": 1
  })

proc moveKnowledge(knowledgeId, x, y: int): JsonNode =
  updateEntity("Knowledge", knowledgeId, proc(row: var JsonNode) =
    row["x"] = %x
    row["y"] = %y
    row["updatedAt"] = %nowIso()
    row["revision"] = %(jsonInt(row, "revision", 0) + 1)
  )

proc createKnowledgeRelation(fromId, toId: int; relationType = "related"; label = ""): JsonNode =
  if fromId == toId:
    return opError("knowledge.edge.create", "self-edge", "Não é permitido relacionar um nó a ele mesmo.")
  for row in allRows("KnowledgeRelation"):
    if jsonInt(row, "fromKnowledgeId") == fromId and jsonInt(row, "toKnowledgeId") == toId:
      return opError("knowledge.edge.create", "duplicate", "Essa relação já existe.")
  upsert("KnowledgeRelation", %*{
    "fromKnowledgeId": fromId,
    "toKnowledgeId": toId,
    "relationType": relationType,
    "label": label,
    "createdAt": nowIso()
  })

proc metisRequest(path: string; body: JsonNode; timeoutMs = 1_200_000): JsonNode
proc ensureMetisService(): bool

proc generateOkfFromMetis(context: JsonNode): JsonNode =
  if not ensureMetisService():
    return opError("okf.generate", "metis-service", "O serviço Metis não está disponível para produzir o OKF.")
  let response = metisRequest("/generate-okf", %*{
    "context": context,
     "max_new_tokens": 160
  }, 120_000)
  if response.kind == JObject and response.hasKey("ok") and response["ok"].getBool and response.hasKey("document"):
    return response["document"].copy
  opError("okf.generate", "generation-failed", jsonStr(response, "error", "O Metis não produziu um documento OKF válido."))

proc storedOkfForTitle(title: string): tuple[path: string, document: JsonNode]
proc importStoredOkf(knowledge: JsonNode; sessionId, processId: int): JsonNode

proc createOkfSnapshot(sessionId, processId, knowledgeId, untilSequence: int; forceRegenerate = false): JsonNode =
  let session = ormGetById("ConversationSession", sessionId)
  let knowledge = ormGetById("Knowledge", knowledgeId)
  let process = ormGetById("WorkProcess", processId)

  # No boot, forceRegenerate recompila o artefato completo pelo Metis. Em um
  # clique normal, o documento e a memória já consolidados são reutilizados.
  let existingId = jsonInt(knowledge, "okfDocumentId")
  if not forceRegenerate and existingId > 0:
    let existing = ormGetById("OkfDocument", existingId)
    if existing.kind == JObject and jsonStr(existing, "content", "").strip.len > 0:
      return existing

  # Também cobre uma sessão recém-reconstruída pelo ORM: o arquivo OKF local
  # continua sendo a fonte persistente e evita uma nova inferência no clique.
  let stored = storedOkfForTitle(jsonStr(knowledge, "title", ""))
  if not forceRegenerate and stored.document.kind == JObject:
    let imported = importStoredOkf(knowledge, sessionId, processId)
    if jsonInt(imported, "id") > 0:
      discard updateEntity("Knowledge", knowledgeId, proc(row: var JsonNode) =
        row["okfDocumentId"] = %jsonInt(imported, "id")
      )
      return imported

  let generationContext = %*{
    "space": "KnowledgeStudio",
    "title": jsonStr(knowledge, "title", "OKF"),
    "memory": {
      "title": jsonStr(knowledge, "title", "Conhecimento"),
      "summary": jsonStr(knowledge, "summary", ""),
      "type": jsonStr(knowledge, "type", "knowledge")
    },
    "sessionId": sessionId,
    "processId": processId,
    "knowledgeId": knowledgeId,
    "untilSequence": untilSequence,
    "timestamp": nowIso(),
    "author": jsonStr(session, "author", jsonStr(activeSettings(), "authorName", "Glauco Developer")),
    "process": process,
    "knowledge": knowledge,
    "messages": sessionMessages(sessionId)
  }
  let artifactResponse = metisRequest("/generate-knowledge-artifact", %*{
    "context": generationContext,
    "max_new_tokens": 1200
  }, 600_000)
  if artifactResponse.kind != JObject or
      not artifactResponse.hasKey("ok") or
      not artifactResponse["ok"].getBool or
      not artifactResponse.hasKey("document"):
    return opError("okf.create_from_session", "generation-failed", jsonStr(artifactResponse, "error", "O Metis não produziu o OKF e a memória."))
  let documentPayload = artifactResponse["document"].copy
  if documentPayload.kind != JObject or not documentPayload.hasKey("title"):
    return opError("okf.create_from_session", "invalid-document", "O Metis retornou um documento OKF inválido.")
  documentPayload["space"] = %"KnowledgeStudio"
  documentPayload["sessionId"] = %sessionId
  documentPayload["processId"] = %processId
  documentPayload["knowledgeId"] = %knowledgeId
  documentPayload["untilSequence"] = %untilSequence
  documentPayload["generatedBy"] = %"IAAR-Shanghai Metis-4B"
  documentPayload["memorySource"] = %"Metis inference: knowledge + conversation + structured OKF"
  documentPayload["messages"] = generationContext["messages"].copy
  if artifactResponse.hasKey("memory"):
    documentPayload["memoryArtifact"] = artifactResponse["memory"].copy
  let okfDoc = persistOkf(appRef.okfValue, documentPayload)
  let docId = if okfDoc.kind == JObject and okfDoc.hasKey("id") and okfDoc["id"].kind == JString:
    allRows("OkfDocument").len + 1
  else:
    jsonInt(okfDoc, "id", 0)
  if docId <= 0:
    return opError("okf.create_from_session", "persist-failed", "O runtime OKF não persistiu o documento.")
  let row = upsert("OkfDocument", %*{
    "id": docId,
    "knowledgeId": knowledgeId,
    "sessionId": sessionId,
    "processId": processId,
    "space": "KnowledgeStudio",
    "documentKey": jsonStr(okfDoc, "id", $docId),
    "title": jsonStr(documentPayload, "title", jsonStr(knowledge, "title", "OKF")),
    "content": $documentPayload,
    "filesystemPath": jsonStr(okfDoc, "path", OkfDir / "KnowledgeStudio"),
    "revision": jsonInt(okfDoc, "revision", 1),
    "createdAt": nowIso(),
    "updatedAt": nowIso(),
    "checkpointSequence": untilSequence,
    "checkpointTimestamp": nowIso(),
    "checkpointAuthor": jsonStr(activeSettings(), "authorName", "Glauco Developer")
  })
  if artifactResponse.hasKey("memory") and artifactResponse["memory"].kind == JObject:
    let memory = artifactResponse["memory"]
    discard updateEntity("Knowledge", knowledgeId, proc(item: var JsonNode) =
      item["safetensorsPath"] = %jsonStr(memory, "tensor_path", "")
      item["safetensorsStatus"] = %"loaded"
      item["safetensorsSha256"] = %jsonStr(memory, "sha256", "")
      item["safetensorsSizeBytes"] = %jsonInt(memory, "size_bytes", 0)
      item["updatedAt"] = %nowIso()
    )
  discard updateEntity("ConversationSession", sessionId, proc(row: var JsonNode) =
    row["lastCheckpointAt"] = %nowIso()
    row["graphKnowledgeId"] = %knowledgeId
    row["activeProcessId"] = %processId
    row["updatedAt"] = %nowIso()
  )
  row

proc okfDocumentMarkdown(document: JsonNode): string =
  if document.kind != JObject:
    return ""
  result = "# " & jsonStr(document, "title", "Documento OKF") & "\n\n"
  let summary = jsonStr(document, "summary", "")
  if summary.strip.len > 0:
    result &= summary.strip & "\n\n"
  if document.hasKey("elements") and document["elements"].kind == JArray and document["elements"].len > 0:
    result &= "## Elementos\n\n"
    for item in document["elements"].items:
      result &= "- **" & jsonStr(item, "name", "Elemento") & "** (" & jsonStr(item, "type", "conceito") & "): " & jsonStr(item, "description", "") & "\n"
    result &= "\n"
  if document.hasKey("properties") and document["properties"].kind == JArray and document["properties"].len > 0:
    result &= "## Propriedades\n\n"
    for item in document["properties"].items:
      result &= "- **" & jsonStr(item, "key", "Propriedade") & ":** " & jsonStr(item, "value", "") & "\n"
    result &= "\n"
  if document.hasKey("relations") and document["relations"].kind == JArray and document["relations"].len > 0:
    result &= "## Relações\n\n"
    for item in document["relations"].items:
      result &= "- " & jsonStr(item, "from", "") & " — **" & jsonStr(item, "label", jsonStr(item, "type", "relaciona")) & "** → " & jsonStr(item, "to", "") & "\n"
    result &= "\n"
  if document.hasKey("functions") and document["functions"].kind == JArray and document["functions"].len > 0:
    result &= "## Funções\n\n"
    for item in document["functions"].items:
      result &= "- **" & jsonStr(item, "name", "Função") & ":** " & jsonStr(item, "description", "") & "\n"
    result &= "\n"
  if document.hasKey("open_questions") and document["open_questions"].kind == JArray and document["open_questions"].len > 0:
    result &= "## Perguntas abertas\n\n"
    for item in document["open_questions"].items:
      if item.kind == JString:
        result &= "- " & item.getStr() & "\n"
      else:
        result &= "- " & $item & "\n"

proc okfDraftForDocument(docId: int): string =
  let row = ormGetById("OkfDocument", docId)
  let raw = jsonStr(row, "content", "")
  if raw.strip.len == 0:
    return ""
  try:
    okfDocumentMarkdown(parseJson(raw))
  except CatchableError:
    raw

proc storedOkfForTitle(title: string): tuple[path: string, document: JsonNode] =
  ## O ORM do protótipo é volátil, mas os documentos OKF são persistidos.
  ## Reidrata o último documento por título sem chamar o modelo durante o boot.
  var latestPath = ""
  var latestDocument = newJNull()
  var latestStamp = fromUnix(0)
  let roots = @[
    OkfDir / "KnowledgeStudio",
    getEnv("LOCALAPPDATA", "") / "OKF Forge" / "okf" / "KnowledgeStudio"
  ]
  for root in roots:
    if root.len == 0 or not dirExists(root):
      continue
    for candidate in walkFiles(root / "*.json"):
      try:
        let document = parseJson(readFile(candidate))
        if document.kind != JObject or jsonStr(document, "title", "") != title:
          continue
        let stamp = getLastModificationTime(candidate)
        if latestPath.len == 0 or stamp > latestStamp:
          latestPath = candidate
          latestDocument = document
          latestStamp = stamp
      except CatchableError:
        discard
  (latestPath, latestDocument)

proc importStoredOkf(knowledge: JsonNode; sessionId, processId: int): JsonNode =
  let stored = storedOkfForTitle(jsonStr(knowledge, "title", ""))
  if stored.path.len == 0 or stored.document.kind != JObject:
    return newJNull()
  let docId = allRows("OkfDocument").len + 1
  result = upsert("OkfDocument", %*{
    "id": docId,
    "knowledgeId": jsonInt(knowledge, "id"),
    "sessionId": sessionId,
    "processId": processId,
    "space": "KnowledgeStudio",
    "documentKey": jsonStr(stored.document, "id", extractFilename(stored.path)),
    "title": jsonStr(stored.document, "title", jsonStr(knowledge, "title", "OKF")),
    "content": $stored.document,
    "filesystemPath": stored.path,
    "revision": jsonInt(stored.document, "revision", 1),
    "createdAt": jsonStr(stored.document, "createdAt", nowIso()),
    "updatedAt": jsonStr(stored.document, "updatedAt", nowIso()),
    "checkpointSequence": jsonInt(stored.document, "untilSequence", 0),
    "checkpointTimestamp": jsonStr(stored.document, "timestamp", nowIso()),
    "checkpointAuthor": jsonStr(stored.document, "author", "Glauco Developer")
  })

proc ensureKnowledgeOkfs(knowledgeRows: seq[JsonNode]; sessionId, processId: int) =
  ## No boot, cada conhecimento passa pelo mesmo request que cria o OKF e a
  ## memória Safetensors. Isso evita documentos-resumo de um único parágrafo.
  for knowledge in knowledgeRows:
    let kid = jsonInt(knowledge, "id")
    if kid <= 0:
      continue
    let current = ormGetById("Knowledge", kid)
    var generated = createOkfSnapshot(sessionId, processId, kid, sessionMessages(sessionId).len, true)
    # Uma falha transitória do serviço (reinício do modelo, socket ou saída
    # JSON incompleta) não pode deixar o conhecimento sem artefato no boot.
    if jsonInt(generated, "id") <= 0:
      sleep(250)
      generated = createOkfSnapshot(sessionId, processId, kid, sessionMessages(sessionId).len, true)
    if jsonInt(generated, "id") > 0:
      discard updateEntity("Knowledge", kid, proc(row: var JsonNode) =
        row["okfDocumentId"] = %jsonInt(generated, "id")
        row["updatedAt"] = %nowIso()
      )

proc ensureDemoKnowledge() =
  ## Conteúdo inicial para o canvas do Study Studio, sem depender do catálogo BNCC.
  let sid = activeSessionId()
  let pid = jsonInt(activeProcess(), "id")
  if sid <= 0: return
  let seeds = @[
    ("Embeddings e busca semântica", "Representações vetoriais aproximam textos por significado. Útil para recuperar memórias relacionadas no canvas.", "conceito", 80, 90),
    ("RAG com contexto local", "Busca documentos OKF, seleciona trechos relevantes e entrega contexto ao modelo antes da resposta.", "arquitetura", 370, 210),
    ("Quantização e inferência", "Reduz precisão e custo de memória para executar modelos localmente, preservando um fluxo de inferência verificável.", "execução", 680, 90),
    ("Tokenização e contexto de linguagem", "O Metis transforma linguagem em unidades de contexto e preserva relações entre termos, intenção e assunto durante a inferência.", "linguagem", 80, 390),
    ("Instrução estruturada para o Metis", "Prompts com objetivo, contexto, restrições e formato de saída tornam o comportamento do Metis mais consistente e auditável.", "aprimoramento", 370, 510),
    ("Avaliação e refinamento de respostas", "O Metis compara respostas com critérios explícitos, identifica lacunas e refina a próxima instrução sem perder o contexto local.", "aprimoramento", 680, 390),
    ("Expressão semântica e composição de sentido", "O Metis combina termos, contexto e intenção para produzir significado além da sequência literal das palavras.", "semântica", 980, 90),
    ("Personalidade simbólica das conexões", "Padrões recorrentes entre conceitos dão ao grafo uma assinatura de associação observável, sem transformar o modelo em uma pessoa.", "semântica", 980, 390)
  ]
  var created: seq[JsonNode] = @[]
  for seed in seeds:
    var found = newJNull()
    for row in knowledgeList():
      if jsonStr(row, "title") == seed[0]:
        if found.kind == JNull:
          found = row
        else:
          discard ormDelete(appRef.ormValue, "Knowledge", jsonInt(row, "id"))
    var item = found
    if item.kind == JNull:
      item = createKnowledge(seed[0], seed[1], seed[2], seed[3], seed[4], sid, pid, 0)
    created.add item
  # Todo registro de Knowledge, inclusive o processo inicial já existente,
  # recebe um documento OKF independente produzido pelo Metis.
  ensureKnowledgeOkfs(knowledgeList(), sid, pid)
  if created.len >= 3:
    discard createKnowledgeRelation(jsonInt(created[0], "id"), jsonInt(created[1], "id"), "supports", "recupera contexto")
    discard createKnowledgeRelation(jsonInt(created[1], "id"), jsonInt(created[2], "id"), "enables", "prepara execução")
    discard createKnowledgeRelation(jsonInt(created[0], "id"), jsonInt(created[2], "id"), "converges", "otimiza memória")
  if created.len >= 6:
    discard createKnowledgeRelation(jsonInt(created[0], "id"), jsonInt(created[3], "id"), "grounds", "representa linguagem")
    discard createKnowledgeRelation(jsonInt(created[3], "id"), jsonInt(created[4], "id"), "structures", "organiza instrução")
    discard createKnowledgeRelation(jsonInt(created[4], "id"), jsonInt(created[5], "id"), "improves", "refina resposta")
    discard createKnowledgeRelation(jsonInt(created[5], "id"), jsonInt(created[2], "id"), "verifies", "valida inferência")
  if created.len >= 8:
    discard createKnowledgeRelation(jsonInt(created[3], "id"), jsonInt(created[6], "id"), "composes", "compõe sentido")
    discard createKnowledgeRelation(jsonInt(created[6], "id"), jsonInt(created[7], "id"), "patterns", "estabiliza símbolos")
    discard createKnowledgeRelation(jsonInt(created[7], "id"), jsonInt(created[1], "id"), "orients", "orienta contexto")

proc createSafetensorsJob(knowledgeId, okfDocumentId: int; modelId, configurationJson: string): JsonNode =
  upsert("SafetensorsProduction", %*{
    "knowledgeId": knowledgeId,
    "okfDocumentId": okfDocumentId,
    "status": "pending",
    "requestedAt": nowIso(),
    "startedAt": "",
    "finishedAt": "",
    "outputPath": "",
    "sha256": "",
    "sizeBytes": 0,
    "producerVersion": "python+safetensors-adapter-v1",
    "modelId": modelId,
    "configurationJson": configurationJson,
    "error": "",
    "revision": 1
  })

proc mainViewTitle(): string =
  let session = activeSession()
  if session.kind == JNull:
    result = "Nenhuma sessão"
  else:
    result = jsonStr(session, "title", "Sessão")

proc ensureActiveSelection() =
  if stateGet(appRef.statesValue, "ActiveSessionId").getInt() <= 0 and sessionList().len > 0:
    stateSet(appRef.statesValue, "ActiveSessionId", %jsonInt(sessionList()[0], "id"))
  let session = activeSession()
  if session.kind != JNull:
    stateSet(appRef.statesValue, "SessionTitleDraft", %jsonStr(session, "title"))
    stateSet(appRef.statesValue, "SessionRenameDraft", %jsonStr(session, "title"))


proc stateStr(name: string; fallback = ""): string =
  let value = stateGet(appRef.statesValue, name)
  if value.kind == JString: value.getStr() else: fallback

proc sessionKnowledgeReady(): bool =
  let value = stateGet(appRef.statesValue, "SessionKnowledgeReady")
  value.kind == JBool and value.getBool

proc conversationLooksComplete(text: string): bool =
  let normalized = text.toLowerAscii()
  var signals = 0
  for marker in ["objetivo", "processo", "entrada", "saída", "resultado", "passo"]:
    if marker in normalized:
      inc signals
  text.strip.len >= 100 and signals >= 2

proc materializeConversationKnowledge(text: string): JsonNode =
  let titleLine = text.strip.splitLines()[0].strip
  let title = if titleLine.len >= 8 and titleLine.len <= 80: titleLine else: "Conhecimento identificado na conversa"
  let knowledge = createKnowledge(title, text.strip, "conversation", 280, 180, activeSessionId(), jsonInt(activeProcess(), "id"), 0)
  let kid = jsonInt(knowledge, "id")
  discard updateEntity("ConversationSession", activeSessionId(), proc(row: var JsonNode) = row["graphKnowledgeId"] = %kid)
  let doc = createOkfSnapshot(activeSessionId(), jsonInt(activeProcess(), "id"), kid, sessionMessages(activeSessionId()).len)
  if jsonInt(doc, "id") > 0:
    discard updateEntity("Knowledge", kid, proc(row: var JsonNode) = row["okfDocumentId"] = %jsonInt(doc, "id"))
  ormGetById("Knowledge", kid)

proc bnccSubjects(): seq[JsonNode] =
  result = allRows("BnccSubject")
  result.sort(proc(a, b: JsonNode): int = cmp(jsonInt(a, "sortOrder"), jsonInt(b, "sortOrder")))

proc bnccSubjectBySlug(slug: string): JsonNode =
  for row in bnccSubjects():
    if jsonStr(row, "slug") == slug:
      return row
  newJNull()

proc bnccSkillsForSubject(slug: string): seq[JsonNode] =
  result = @[]
  for row in allRows("BnccSkill"):
    if jsonStr(row, "subjectSlug") == slug:
      result.add row
  result.sort(proc(a, b: JsonNode): int = cmp(jsonStr(a, "code"), jsonStr(b, "code")))

proc bnccSkillByCode(code: string): JsonNode =
  for row in allRows("BnccSkill"):
    if jsonStr(row, "code") == code:
      return row
  newJNull()

proc activeBnccSubject(): JsonNode =
  bnccSubjectBySlug(stateStr("ActiveSubjectSlug"))

proc activeBnccSkill(): JsonNode =
  bnccSkillByCode(stateStr("ActiveSkillCode"))

proc studyMessages(code: string): seq[JsonNode] =
  result = @[]
  if code.len == 0: return
  for row in ormWhere(appRef.ormValue, "StudyMessage", "skillCode", %code).items:
    result.add row
  result.sort(proc(a, b: JsonNode): int = cmp(jsonInt(a, "sequence"), jsonInt(b, "sequence")))

proc nextStudySequence(code: string): int =
  result = 1
  for row in studyMessages(code):
    result = max(result, jsonInt(row, "sequence") + 1)

proc appendStudyMessage(code, role, content: string): JsonNode =
  upsert("StudyMessage", %*{
    "skillCode": code,
    "role": role,
    "content": content,
    "createdAt": nowIso(),
    "sequence": nextStudySequence(code)
  })

proc seedBnccCatalog() =
  ensureDir(BnccDir)
  ensureDir(BnccOkfDir)
  ensureDir(BnccSafetensorsDir)
  if not fileExists(BnccManifestPath):
    return
  let manifest = parseJson(readFile(BnccManifestPath))
  if manifest.kind != JObject: return
  if manifest.hasKey("subjects") and manifest["subjects"].kind == JArray:
    for subject in manifest["subjects"].items:
      discard upsert("BnccSubject", %*{
        "id": jsonInt(subject, "id"),
        "name": jsonStr(subject, "name"),
        "slug": jsonStr(subject, "slug"),
        "skillsCount": jsonInt(subject, "skills_count"),
        "sortOrder": jsonInt(subject, "id")
      })
  if manifest.hasKey("skills") and manifest["skills"].kind == JArray:
    for skill in manifest["skills"].items:
      let code = jsonStr(skill, "code")
      let existing = bnccSkillByCode(code)
      let tensorPath = RootDir / jsonStr(skill, "tensor_path")
      discard upsert("BnccSkill", %*{
        "id": jsonInt(skill, "id"),
        "code": code,
        "topicKey": jsonStr(skill, "topic_key"),
        "subjectId": jsonInt(skill, "subject_id"),
        "subject": jsonStr(skill, "subject"),
        "subjectSlug": jsonStr(skill, "subject_slug"),
        "areaBncc": jsonStr(skill, "area_bncc"),
        "yearBlock": jsonStr(skill, "year_block"),
        "statement": jsonStr(skill, "statement"),
        "primaryCompetence": jsonStr(skill, "primary_competence"),
        "competences": jsonStr(skill, "competences"),
        "socialAxes": jsonStr(skill, "social_axes"),
        "axisNames": jsonArrayJoin(skill, "axis_names"),
        "okfPath": RootDir / jsonStr(skill, "okf_path"),
        "tensorPath": tensorPath,
        "okfSha256": jsonStr(skill, "okf_sha256"),
        "tensorStatus": if fileExists(tensorPath): "present" elif existing.kind != JNull: jsonStr(existing, "tensorStatus", "missing") else: "missing",
        "tensorUpdatedAt": if existing.kind != JNull: jsonStr(existing, "tensorUpdatedAt", "") else: "",
        "lastLoadedAt": if existing.kind != JNull: jsonStr(existing, "lastLoadedAt", "") else: ""
      })

proc pythonCommand(): string =
  let configured = getEnv("OKFFORGE_PYTHON", "").strip()
  if configured.len > 0: return configured
  when defined(windows): "python" else: "python3"

proc metisRequest(path: string; body: JsonNode; timeoutMs = 1_200_000): JsonNode =
  var client = newHttpClient(timeout = timeoutMs)
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  try:
    let response = client.request(MetisServiceEndpoint & path, httpMethod = HttpPost, body = $body)
    if response.code.int < 200 or response.code.int >= 300:
      return opError("metis.request", "http-" & $response.code.int, response.body)
    result = parseJson(response.body)
  except CatchableError as exc:
    result = opError("metis.request", "connection", exc.msg)
  finally:
    client.close()

proc metisHealth(): JsonNode =
  var client = newHttpClient(timeout = 1_500)
  try:
    let response = client.get(MetisServiceEndpoint & "/health")
    if response.code.int >= 200 and response.code.int < 300:
      return parseJson(response.body)
  except CatchableError:
    discard
  finally:
    client.close()
  newJNull()

proc ensureMetisService(): bool =
  if metisHealth().kind == JObject: return true
  let bootstrap = ScriptsDir / "bootstrap_bncc_metis.py"
  if not fileExists(bootstrap): return false
  try:
    discard execProcess(pythonCommand(), args = @[bootstrap, "--root", RootDir, "--no-generate-missing"], options = {poUsePath, poStdErrToStdOut})
  except CatchableError:
    return false
  for _ in 0..<40:
    if metisHealth().kind == JObject: return true
    sleep(200)
  false

proc scheduleInitialBnccTensorVerification() =
  let bootstrap = ScriptsDir / "bootstrap_bncc_metis.py"
  if not fileExists(bootstrap): return
  try:
    discard startProcess(pythonCommand(), args = @[bootstrap, "--root", RootDir], options = {poUsePath, poParentStreams})
  except CatchableError:
    discard

proc setSkillTensorState(code, status: string; loaded = false) =
  let skill = bnccSkillByCode(code)
  if skill.kind == JNull: return
  discard updateEntity("BnccSkill", jsonInt(skill, "id"), proc(row: var JsonNode) =
    row["tensorStatus"] = %status
    row["tensorUpdatedAt"] = %nowIso()
    if loaded: row["lastLoadedAt"] = %nowIso()
  )

proc loadBnccSkillMemory(code: string): JsonNode =
  if not ensureMetisService():
    setSkillTensorState(code, "service-unavailable")
    return opError("bncc.skill.load", "metis-service", "Serviço Metis não está disponível.")
  setSkillTensorState(code, "loading")
  let response = metisRequest("/load", %*{"code": code})
  if response.kind == JObject and response.hasKey("ok") and response["ok"].getBool:
    setSkillTensorState(code, "loaded", true)
  else:
    setSkillTensorState(code, "error")
  response

proc rebuildBnccSkillTensor(code: string): JsonNode =
  if not ensureMetisService():
    return opError("bncc.skill.rebuild", "metis-service", "Serviço Metis não está disponível.")
  setSkillTensorState(code, "rebuilding")
  let response = metisRequest("/rebuild", %*{"code": code})
  if response.kind == JObject and response.hasKey("ok") and response["ok"].getBool:
    setSkillTensorState(code, "ready", true)
  else:
    setSkillTensorState(code, "error")
  response

proc studyWithBnccSkill(code, prompt: string): JsonNode =
  if code.len == 0 or prompt.strip.len == 0:
    return opError("bncc.study.chat", "invalid", "Habilidade ou mensagem vazia.")
  discard appendStudyMessage(code, "user", prompt.strip)
  if not ensureMetisService():
    discard appendStudyMessage(code, "system", "Serviço Metis indisponível.")
    return opError("bncc.study.chat", "metis-service", "Serviço Metis não está disponível.")
  let response = metisRequest("/chat", %*{"code": code, "prompt": prompt.strip, "max_new_tokens": 320})
  if response.kind == JObject and response.hasKey("ok") and response["ok"].getBool:
    discard appendStudyMessage(code, "assistant", jsonStr(response, "answer"))
    setSkillTensorState(code, "updated", true)
  else:
    discard appendStudyMessage(code, "system", "Falha: " & jsonStr(response, "error", "erro do runtime Metis"))
    setSkillTensorState(code, "error")
  response

proc localContextSummary(reason: string): string =
  let knowledge = activeKnowledge()
  if knowledge.kind != JNull:
    return "Documento " & jsonStr(knowledge, "title", "OKF") & " aberto · sincronização edição ↔ conversa ativa."
  "Sessão ativa · aguardando um conhecimento ou processo para resumir."

proc refreshContextSummary(reason: string) =
  var messages = newJArray()
  let history = sessionMessages(activeSessionId())
  let start = max(0, history.len - 8)
  if start < history.len:
    for index in start ..< history.len:
      messages.add(history[index])
  let context = %*{
    "reason": reason,
    "page": stateStr("ActivePage", "inicio"),
    "session": activeSession(),
    "knowledge": activeKnowledge(),
    "messages": messages
  }
  stateSet(appRef.statesValue, "ContextSummary", %(localContextSummary(reason)))
  # O resumo inicial não pode bloquear o servidor antes de a interface abrir.
  # Atualizações de sessão, conversa e conhecimento continuam consultando o
  # Metis normalmente depois que o runtime já está disponível.
  if reason in ["inicialização", "conhecimento aberto", "nova sessão", "sessão carregada"]:
    return
  let response = metisRequest("/context-summary", %*{
    "context": context,
    "max_new_tokens": 160
  }, 30_000)
  if response.kind == JObject and response.hasKey("ok") and response["ok"].getBool:
    let answer = jsonStr(response, "answer", "").strip
    if answer.len > 0:
      stateSet(appRef.statesValue, "ContextSummary", %answer)

proc pageTitle(): string =
  case stateStr("ActivePage", "materias")
  of "materias": "Matérias · BNCC EF II"
  of "materia": jsonStr(activeBnccSubject(), "name", "Matéria")
  of "estudo":
    let skill = activeBnccSkill()
    jsonStr(skill, "code", "Habilidade") & " · " & jsonStr(skill, "subject", "BNCC")
  else: mainViewTitle()

glaucoplastic KnowledgeStudioApplication, application:
  product:
    title AppTitle
    description "Runtime OKF para conversas, processos, conhecimento e produção Safetensors."
    version "0.1.0"

  installation:
    windowsMsi:
      productName "OKF Forge"
      manufacturer "Glauco Developer"
      version "0.1.0"
      upgradeCode "B6B7F5AE-3A5A-4B0C-8F75-5D8A4A2F6E91"
      scope perUser
      executable "okfforge_bncc_nw.exe"

      installDirectory:
        root localAppDataPrograms
        path "OKF Forge"

      applicationData:
        root localAppData
        path "OKF Forge"
        createDirectory "data"
        createDirectory "okf"
        createDirectory "okf/KnowledgeStudio"
        createDirectory ".glauco/metis"
        createDirectory ".glauco/sessions"
        createDirectory ".glauco/cache/huggingface"

      package:
        tree "F:/metis4", destination = "models/metis/IAAR-Shanghai_Metis-4B"
        tree "F:/OKF Forge/vendor/markdown-toolbar-element/node_modules/@github/markdown-toolbar-element", destination = "vendor/markdown-toolbar-element"

      shortcut:
        desktop true
        startMenu true

  states:
    ActivePage = "inicio"
    ActiveSessionId = 0
    SessionTitleDraft = ""
    SessionRenameDraft = ""
    MessageDraft = ""
    SettingsAuthorDraft = ""
    SettingsApplicationKeyMasked = ""
    SettingsOkfDirectoryDraft = ""
    SettingsSafetensorsDirectoryDraft = ""
    SettingsRepositoryOwnerDraft = ""
    SettingsRepositoryNameDraft = ""
    SettingsRepositoryBranchDraft = ""
    SettingsRepositoryDirectoryDraft = ""
    StatusMessage = ""
    PendingPickerKind = ""
    PendingOperationJson = ""
    KnowledgeDraftTitle = ""
    KnowledgeDraftSummary = ""
    KnowledgeDocumentDraft = ""
    KnowledgeDraftType = "knowledge"
    SessionKnowledgeReady = false
    ProcessDraftTitle = ""
    ProcessDraftDescription = ""
    ActiveSubjectSlug = ""
    ActiveSkillCode = ""
    EventValueDraft = ""
    StudyPromptDraft = ""
    MarkdownToolbarModuleUrl = ""
    KnowledgeWysiwygModuleUrl = ""
    ContextSummary = "Inicializando o resumo contextual do Metis…"

  okfs:
    KnowledgeStudio:
      purpose "Persistir checkpoints, conhecimento estruturado e snapshots do trabalho."
      summary "Conversas, processos, relações, documentos e produções."

  orm:
    ApplicationSettings:
      id integer primary
      applicationKey string
      authorName string
      okfDirectory string
      safetensorsDirectory string
      repositoryOwner string
      repositoryName string
      repositoryBranch string
      repositoryDirectory string
      createdAt string
      updatedAt string
    ConversationSession:
      id integer primary
      title string
      status string
      createdAt string
      updatedAt string
      author string
      activeProcessId integer
      graphKnowledgeId integer
      lastCheckpointAt string
    ConversationMessage:
      id integer primary
      sessionId integer
      role string
      content string
      createdAt string
      sequence integer
    Knowledge:
      id integer primary
      title string
      summary string
      type string
      okfDocumentId integer
      safetensorsPath string
      safetensorsStatus string
      safetensorsSha256 string
      safetensorsSizeBytes integer
      processId integer
      originSessionId integer
      x integer
      y integer
      createdAt string
      updatedAt string
      author string
      revision integer
    KnowledgeRelation:
      id integer primary
      fromKnowledgeId integer
      toKnowledgeId integer
      relationType string
      label string
      createdAt string
    WorkProcess:
      id integer primary
      sessionId integer
      title string
      description string
      status string
      createdAt string
      updatedAt string
      revision integer
    WorkProcessNode:
      id integer primary
      processId integer
      type string
      label string
      description string
      x integer
      y integer
      width integer
      height integer
      metadata string
      createdAt string
      updatedAt string
      revision integer
    WorkProcessEdge:
      id integer primary
      processId integer
      fromNodeId integer
      toNodeId integer
      label string
      condition string
      edgeType string
      createdAt string
      revision integer
    OkfDocument:
      id integer primary
      knowledgeId integer
      sessionId integer
      processId integer
      space string
      documentKey string
      title string
      content string
      filesystemPath string
      revision integer
      createdAt string
      updatedAt string
      checkpointSequence integer
      checkpointTimestamp string
      checkpointAuthor string
    SafetensorsProduction:
      id integer primary
      knowledgeId integer
      okfDocumentId integer
      status string
      requestedAt string
      startedAt string
      finishedAt string
      outputPath string
      sha256 string
      sizeBytes integer
      producerVersion string
      modelId string
      configurationJson string
      error string
      revision integer
    BnccSubject:
      id integer primary
      name string
      slug string
      skillsCount integer
      sortOrder integer
    BnccSkill:
      id integer primary
      code string
      topicKey string
      subjectId integer
      subject string
      subjectSlug string
      areaBncc string
      yearBlock string
      statement string
      primaryCompetence string
      competences string
      socialAxes string
      axisNames string
      okfPath string
      tensorPath string
      okfSha256 string
      tensorStatus string
      tensorUpdatedAt string
      lastLoadedAt string
    StudyMessage:
      id integer primary
      skillCode string
      role string
      content string
      createdAt string
      sequence integer
    RepositoryTarget:
      id integer primary
      applicationSettingsId integer
      owner string
      repository string
      branch string
      directory string
      lastSyncStatus string
      lastSyncAt string
      lastSyncError string
      createdAt string
      updatedAt string
      revision integer
    ArtifactRevision:
      id integer primary
      knowledgeId integer
      okfDocumentId integer
      safetensorsProductionId integer
      artifactType string
      artifactPath string
      sha256 string
      sizeBytes integer
      revisionNumber integer
      sourceSequence integer
      sourceTimestamp string
      syncStatus string
      gitCommit string
      createdAt string
      updatedAt string
      notes string

  components:
    Shell:
      render:
        style """
          :host {
            all: initial;
            display: block;
            min-height: 100vh;
            color: #e8edf2;
            background:
              radial-gradient(circle at top left, rgba(112, 157, 255, .22), transparent 30%),
              radial-gradient(circle at 80% 0%, rgba(221, 146, 77, .16), transparent 28%),
              linear-gradient(180deg, #0b1020 0%, #090d16 100%);
            font-family: Inter, "Segoe UI", system-ui, sans-serif;
          }
          .ks-app {
            min-height: 100vh;
            display: grid;
            grid-template-columns: 238px minmax(0, 1fr) 348px;
            gap: 0;
            padding: 0;
            box-sizing: border-box;
            background: #0b0f0e;
          }
          .ks-sidebar, .ks-panel, .ks-main, .ks-card {
            border: 1px solid rgba(162, 178, 202, .18);
            background: rgba(12, 17, 28, .82);
            backdrop-filter: blur(18px);
            box-shadow: 0 20px 80px rgba(0, 0, 0, .28);
          }
          .ks-sidebar {
            border-radius: 0;
            border-width: 0 1px 0 0;
            padding: 28px 18px;
            display: flex;
            flex-direction: column;
            gap: 14px;
            min-height: 100vh;
            background: #101613;
          }
          .ks-sidebar-account { margin-top: auto; position: relative; }
          .ks-sidebar-account details { border-top: 1px solid rgba(162, 178, 202, .16); padding-top: 12px; }
          .ks-sidebar-account summary { cursor: pointer; color: #c8f36b; font-size: 12px; letter-spacing: .08em; text-transform: uppercase; }
          .ks-account-menu { display: grid; gap: 8px; margin-top: 10px; padding: 10px; border: 1px solid rgba(162, 178, 202, .16); border-radius: 16px; background: #151d19; }
          .ks-sidebar-properties { margin-top: 12px; padding-top: 14px; border-top: 1px solid #dfe3e8; }
          .ks-sidebar-properties .ks-toolbar { align-items: flex-start; }
          .ks-sidebar-properties .ks-toolbar-copy {
            display: flex;
            flex-direction: column;
            align-items: flex-start;
            gap: 4px;
            min-width: 0;
          }
          .ks-sidebar-properties .ks-toolbar-copy strong,
          .ks-sidebar-properties .ks-toolbar-copy small {
            display: block;
            line-height: 1.35;
          }
          .ks-sidebar-properties .ks-property { padding: 9px 0; }
          .ks-sidebar-properties .ks-property-value { font-size: 12px; line-height: 1.35; }
          .ks-sidebar-properties .ks-context-summary .ks-property-value { white-space: pre-wrap; }
          .ks-brand { display: grid; gap: 5px; }
          .ks-brand strong { display: block; font-size: 15px; line-height: 1.25; letter-spacing: .08em; color: #edf5ee; }
          .ks-brand small, .ks-muted { display: block; color: #7f9387; line-height: 1.4; }
          .ks-nav { display: grid; gap: 8px; }
          .ks-nav button, .ks-footer button, .ks-row button, .ks-picker button {
            border: 1px solid rgba(162, 178, 202, .16);
            background: rgba(255, 255, 255, .03);
            color: #e8edf2;
            border-radius: 16px;
            min-height: 42px;
            padding: 0 14px;
            cursor: pointer;
          }
          .ks-nav button[data-active="true"] { background: rgba(190, 239, 105, .13); color: #c8f36b; }
          .ks-main {
            border-radius: 0;
            padding: 30px 38px 70px;
            display: grid;
            gap: 16px;
            align-content: start;
            overflow: auto;
          }
          .ks-system-tabs { display: block; width: 100%; border-bottom: 1px solid rgba(162, 178, 202, .2); }
          .ks-system-tabs cds-tab { min-width: 132px; }
          .ks-toolbar, .ks-footer { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; justify-content: space-between; }
          .ks-toolbar > div { display: grid; min-width: 0; gap: 4px; }
          .ks-toolbar > div > strong, .ks-toolbar > div > small { display: block; line-height: 1.35; }
          .ks-stat-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; }
          .ks-stat, .ks-card { border-radius: 20px; padding: 16px; }
          .ks-stat strong { display: block; font-size: 22px; margin-top: 4px; }
          .ks-canvas {
            position: relative;
            min-height: 390px;
            border-radius: 24px;
            overflow: hidden;
            background:
              linear-gradient(rgba(255,255,255,.03) 1px, transparent 1px),
              linear-gradient(90deg, rgba(255,255,255,.03) 1px, transparent 1px),
              rgba(10, 16, 13, .92);
            background-size: 28px 28px, 28px 28px, auto;
          }
          .ks-node {
            position: absolute;
            border-radius: 18px;
            padding: 12px 14px;
            border: 1px solid rgba(180, 195, 222, .18);
            background: rgba(16, 23, 36, .96);
            width: 180px;
            box-shadow: 0 18px 44px rgba(0, 0, 0, .24);
          }
          .ks-node button { margin-top: 10px; }
          .ks-knowledge-canvas { display: flex; flex-wrap: wrap; align-content: flex-start; gap: 14px; padding: 22px; }
          .ks-knowledge-card { position: relative; width: min(250px, 100%); min-height: 150px; cursor: pointer; }
          .ks-knowledge-card:hover { border-color: #c8f36b; transform: translateY(-2px); }
          .ks-welcome { min-height: 250px; display: grid; align-content: center; gap: 12px; padding: 35px; background: radial-gradient(circle at 80% 20%, #263b27, transparent 40%), #141d18; }
          .ks-welcome h1 { max-width: 560px; font-size: clamp(34px, 5vw, 62px); line-height: .98; margin: 0; letter-spacing: -.06em; }
          .ks-welcome h1 em { color: #c8f36b; font-style: normal; }
          .ks-welcome p { max-width: 500px; color: #9bad9f; line-height: 1.6; }
          .ks-primary-button { background: #c8f36b !important; color: #172012 !important; border-color: #c8f36b !important; font-weight: 700; }
          .ks-editor-layout { display: grid; grid-template-columns: minmax(0, 1fr) minmax(300px, 360px); gap: 16px; align-items: stretch; min-height: calc(100vh - 96px); }
          .ks-editor { min-height: 580px; display: grid; gap: 14px; align-content: start; }
          .ks-editor textarea { min-height: 390px; resize: vertical; line-height: 1.65; }
          .ks-editor-main { display: grid; gap: 14px; align-content: start; }
          .ks-editor-toolbar { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
          .ks-editor-toolbar cds-button { --cds-button-size: 32px; }
          .ks-editor-toolbar .ks-muted { margin-left: auto; }
          .ks-editor-chat { height: calc(100vh - 64px); min-height: 560px; max-height: none; display: grid; grid-template-rows: auto minmax(0, 1fr) auto; gap: 12px; position: sticky; top: 24px; overflow: hidden; }
          .ks-editor-chat .ks-chat { min-height: 0; max-height: none; overflow-y: auto; align-content: start; padding-right: 4px; }
          .ks-editor-chat .ks-form { min-height: 0; }
          .ks-editor-chat .ks-form textarea { min-height: 92px; max-height: 180px; }
          .ks-new-session-invite {
            width: min(100%, 840px);
            min-height: 360px;
            align-content: start;
            gap: 18px;
          }
          .ks-new-session-invite .ks-invite-copy {
            display: grid;
            gap: 8px;
            max-width: 680px;
          }
          .ks-new-session-invite .ks-invite-copy h2 { margin: 0; }
          .ks-new-session-invite .ks-invite-description {
            max-width: 650px;
            color: #66717d;
            line-height: 1.6;
          }
          .ks-new-session-invite .ks-invite-prompt {
            margin: 0;
            padding: 12px 16px;
            border-left: 3px solid var(--cds-blue-60);
            background: var(--cds-gray-10);
            color: #4d5863;
            line-height: 1.5;
          }
          .ks-new-session-invite .ks-chat-composer {
            grid-template-columns: minmax(0, 1fr) auto;
            align-items: end;
          }
          .ks-new-session-invite .ks-chat-composer textarea { min-height: 104px; }
          .ks-new-session-invite .ks-chat-composer cds-button { min-height: 48px; }
          .ks-new-session-invite {
            width: 100%;
            min-height: calc(100vh - 74px);
            display: grid;
            grid-template-rows: auto minmax(0, 1fr) auto;
            align-content: stretch;
            overflow: hidden;
          }
          .ks-main:has(.ks-new-session-invite) { padding-bottom: 16px; }
          .ks-new-session-invite .ks-invite-header {
            display: grid;
            gap: 7px;
          }
          .ks-new-session-invite .ks-invite-header h2 { margin: 0; }
          .ks-new-session-invite .ks-invite-header small { color: #66717d; line-height: 1.5; }
          .ks-new-session-invite .ks-conversation-body {
            min-height: 0;
            display: grid;
            align-content: center;
            overflow-y: auto;
            padding: 10px 4px;
          }
          .ks-new-session-invite .ks-empty-conversation {
            display: grid;
            gap: 8px;
            justify-items: center;
            max-width: 560px;
            margin: 0 auto;
            text-align: center;
          }
          .ks-new-session-invite .ks-empty-conversation strong { font-size: 17px; }
          .ks-new-session-invite .ks-empty-conversation p {
            max-width: 500px;
            margin: 0;
            color: #66717d;
            line-height: 1.6;
          }
          .ks-new-session-invite .ks-chat {
            min-height: 0;
            max-height: none;
            overflow-y: auto;
            align-content: start;
            padding: 0 4px;
          }
          .ks-new-session-invite:has(.ks-message) .ks-empty-conversation { display: none; }
          .ks-new-session-invite .ks-chat-composer { min-height: 0; }
          .ks-canvas-heading {
            display: flex;
            flex-direction: column;
            align-items: flex-start;
            gap: 4px;
            min-width: 0;
          }
          .ks-canvas-heading strong,
          .ks-canvas-heading small {
            display: block;
            line-height: 1.35;
          }
          .ks-editor-main { background: #f4f4f4; }
          .ks-rich-editor { box-sizing: border-box; width: min(100%, 860px); min-height: 560px; margin: 20px auto; padding: 64px 76px; border: 1px solid #d8d8d8; background: #fff; color: #161616; line-height: 1.65; overflow: auto; box-shadow: 0 2px 8px rgba(0,0,0,.12); }
          .ks-rich-editor[contenteditable="true"]:focus { outline: 2px solid var(--cds-blue-60); outline-offset: -2px; }
          .ks-rich-editor p { margin: 0 0 12px; }
          .ks-rich-editor h1, .ks-rich-editor h2, .ks-rich-editor h3 { margin: 0 0 12px; color: #161616; }
          .ks-rich-editor blockquote { margin: 10px 0; padding: 8px 14px; border-left: 3px solid var(--cds-blue-60); background: var(--cds-gray-10); }
          .ks-rich-editor code { padding: 2px 4px; background: var(--cds-gray-10); font-family: "IBM Plex Mono", monospace; }
          .ks-rich-editor pre { padding: 12px; background: #262626; color: #f4f4f4; overflow: auto; }
          .ks-rich-editor ul, .ks-rich-editor ol { padding-left: 24px; }
          .ks-editor-sync-state { display: none; }
          .ks-markdown-toolbar { display: flex; flex-wrap: wrap; gap: 4px; padding: 6px; border: 1px solid var(--cds-gray-20); background: var(--cds-gray-10); }
          .ks-markdown-toolbar md-bold, .ks-markdown-toolbar md-header, .ks-markdown-toolbar md-italic,
          .ks-markdown-toolbar md-quote, .ks-markdown-toolbar md-code, .ks-markdown-toolbar md-link,
          .ks-markdown-toolbar md-unordered-list, .ks-markdown-toolbar md-ordered-list,
          .ks-markdown-toolbar md-task-list, .ks-markdown-toolbar md-strikethrough {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            min-height: 32px;
            padding: 0 9px;
            border: 1px solid var(--cds-gray-30);
            border-radius: 4px;
            background: #fff;
            color: var(--cds-gray-100);
            font: 600 12px/1 "IBM Plex Sans", "Segoe UI", sans-serif;
            cursor: pointer;
            user-select: none;
            transition: background .12s ease, border-color .12s ease, color .12s ease;
          }
          .ks-markdown-toolbar md-bold { min-width: 32px; font-weight: 700; }
          .ks-markdown-toolbar md-italic { min-width: 32px; font-style: italic; }
          .ks-markdown-toolbar md-quote,
          .ks-markdown-toolbar md-code { margin-left: 6px; padding-left: 14px; border-left: 1px solid var(--cds-gray-30); border-radius: 0; }
          .ks-markdown-toolbar md-code { font-family: "IBM Plex Mono", monospace; }
          .ks-markdown-toolbar md-link { min-width: 48px; }
          .ks-markdown-toolbar md-unordered-list,
          .ks-markdown-toolbar md-ordered-list,
          .ks-markdown-toolbar md-task-list { min-width: 62px; }
          .ks-markdown-toolbar md-bold:hover, .ks-markdown-toolbar md-header:hover,
          .ks-markdown-toolbar md-italic:hover, .ks-markdown-toolbar md-quote:hover,
          .ks-markdown-toolbar md-code:hover, .ks-markdown-toolbar md-link:hover,
          .ks-markdown-toolbar md-unordered-list:hover, .ks-markdown-toolbar md-ordered-list:hover,
          .ks-markdown-toolbar md-task-list:hover { border-color: var(--cds-blue-60); background: var(--cds-gray-10); color: var(--cds-blue-70); }
          .ks-context-properties { display: grid; gap: 14px; align-content: start; }
          .ks-property-grid { display: grid; gap: 8px; }
          .ks-property { display: grid; gap: 4px; padding: 10px 0; border-bottom: 1px solid var(--cds-gray-20); }
          .ks-property:last-child { border-bottom: 0; }
          .ks-property-label { color: #6f6f6f; font-size: 10px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; }
          .ks-property-value { color: #161616; font-size: 13px; }
          .ks-session-list { display: grid; gap: 6px; max-height: 260px; overflow: auto; border-top: 1px solid #29342e; padding-top: 14px; }
          .ks-session-list button { border: 0; background: transparent; color: #9bad9f; text-align: left; padding: 9px; border-radius: 8px; cursor: pointer; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .ks-session-list button:hover { color: #c8f36b; background: #202a25; }
          .ks-node strong { display: block; font-size: 14px; margin-bottom: 4px; }
          .ks-node small { color: #94a1b8; display: block; }
          .ks-list { display: grid; gap: 10px; }
          .ks-row {
            display: grid;
            gap: 8px;
            padding: 12px;
            border-radius: 18px;
            background: rgba(255,255,255,.03);
            border: 1px solid rgba(162, 178, 202, .12);
          }
          .ks-chat { display: grid; gap: 10px; max-height: 320px; overflow: auto; }
          .ks-message {
            padding: 10px 12px;
            border-radius: 16px;
            background: rgba(255,255,255,.04);
            border: 1px solid rgba(162, 178, 202, .10);
          }
          .ks-message b { display: block; margin-bottom: 4px; }
          .ks-form { display: grid; gap: 8px; }
          .ks-form input, .ks-form textarea {
            width: 100%;
            min-height: 42px;
            border: 1px solid rgba(162, 178, 202, .16);
            border-radius: 14px;
            background: rgba(255,255,255,.03);
            color: #e8edf2;
            padding: 10px 12px;
            font: inherit;
          }
          .ks-form textarea { min-height: 110px; resize: vertical; }
          .ks-panel {
            border-radius: 24px;
            padding: 16px;
            display: grid;
            gap: 12px;
            align-content: start;
          }
          .ks-pill {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            padding: 8px 12px;
            border-radius: 999px;
            background: rgba(255,255,255,.04);
            border: 1px solid rgba(162, 178, 202, .12);
          }
          .ks-empty { color: #8e9ab0; padding: 12px 0; }
          .ks-hidden { display: none !important; }
          .ks-picker {
            position: fixed;
            left: 50%;
            top: 50%;
            transform: translate(-50%, -50%);
            border-radius: 22px;
            padding: 16px;
            display: grid;
            gap: 10px;
            width: min(460px, calc(100vw - 28px));
            z-index: 40;
            border: 1px solid rgba(162, 178, 202, .18);
            background: rgba(12, 17, 28, .96);
          }
          .ks-subject-grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:12px; }
          .ks-subject-card { min-height:150px; display:grid; align-content:space-between; gap:12px; }
          .ks-subject-card h3 { margin:0; font-size:17px; }
          .ks-subject-card button { justify-self:start; }
          .ks-skill-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:10px; }
          .ks-skill-card { display:grid; gap:9px; min-height:190px; }
          .ks-skill-code { font-size:12px; letter-spacing:.08em; color:#7fbfff; }
          .ks-skill-text { color:#d9e2ed; line-height:1.5; }
          .ks-study-layout { display:grid; grid-template-columns:minmax(0,1fr) 320px; gap:14px; }
          .ks-study-chat { min-height:440px; max-height:62vh; overflow:auto; display:grid; align-content:start; gap:10px; }
          .ks-okf-source { max-height:58vh; overflow:auto; word-break:break-word; }
          .ks-path { font-family:ui-monospace,Consolas,monospace; font-size:11px; color:#8ea1ba; word-break:break-all; }
          .ks-status-ready { color:#72e6ae; }
          .ks-status-warn { color:#f0be6a; }
          /* Glaucoplastic base surface: neutral, readable, component-first. */
          :host { color-scheme: light; color: #1e2329; background: #f4f6f8; }
          .ks-app { background: #f4f6f8; grid-template-columns: 248px minmax(0, 1fr) 340px; }
          .ks-sidebar, .ks-panel, .ks-main, .ks-card, .ks-stat {
            border-color: #dfe3e8;
            background: #ffffff;
            color: #1e2329;
            box-shadow: 0 10px 28px rgba(31,35,41,.06);
            backdrop-filter: none;
          }
          .ks-app:has(.ks-editor-layout) { grid-template-columns: 248px minmax(0, 1fr); }
          .ks-app:has(.ks-editor-layout) .ks-panel { display: none !important; }
          .ks-sidebar { background: #ffffff; padding: 22px 16px; }
          .ks-sidebar-properties { border-top-color: #dfe3e8; }
          .ks-sidebar-account { width: 100%; }
          .ks-sidebar-account details { border-top-color: #cbd2d9; padding-top: 10px; }
          .ks-sidebar-account summary { display: flex; align-items: center; justify-content: space-between; min-height: 40px; padding: 0 8px; color: #1e2329; }
          .ks-brand strong { color: #1e2329; }
          .ks-brand small, .ks-muted, .ks-empty { color: #66717d; }
          .ks-nav button, .ks-footer button, .ks-row button, .ks-picker button {
            border-color: #dfe3e8; background: #ffffff; color: #1e2329; border-radius: 9px;
          }
          .ks-nav button:hover, .ks-footer button:hover, .ks-row button:hover, .ks-picker button:hover { background: #f0f2f4; }
          .ks-nav button[data-active="true"] { background: #eef0f3; color: #1e2329; border-color: #cbd2d9; }
          .ks-main { padding: 24px 28px 48px; }
          .ks-system-tabs { margin: -24px -28px 0; width: calc(100% + 56px); border-bottom-color: #dfe3e8; }
          .ks-system-tabs cds-tab { --cds-tab-color: #525252; --cds-tab-selected-color: #161616; }
          .ks-canvas { background: linear-gradient(#e9edf0 1px, transparent 1px), linear-gradient(90deg, #e9edf0 1px, transparent 1px), #f8f9fa; background-size: 28px 28px, 28px 28px, auto; border-color: #dfe3e8; }
          .ks-node, .ks-knowledge-card { background: #ffffff; border-color: #dfe3e8; color: #1e2329; box-shadow: 0 8px 22px rgba(31,35,41,.08); }
          .ks-node small, .ks-path { color: #66717d; }
          .ks-knowledge-card:hover { border-color: #8a949e; }
          .ks-welcome { background: #ffffff; }
          .ks-welcome h1 { color: #1e2329; }
          .ks-welcome h1 em { color: #1e2329; }
          .ks-welcome p, .ks-skill-text { color: #66717d; }
          .ks-primary-button { background: #1e2329 !important; color: #ffffff !important; border-color: #1e2329 !important; }
          .ks-session-list { border-top-color: #dfe3e8; }
          .ks-session-list button { color: #4d5863; }
          .ks-session-list button:hover { color: #1e2329; background: #f0f2f4; }
          .ks-row, .ks-message, .ks-pill { background: #f8f9fa; border-color: #dfe3e8; }
          .ks-form input, .ks-form textarea { border-color: #cbd2d9; background: #ffffff; color: #1e2329; border-radius: 9px; }
          .ks-picker { border-color: #dfe3e8; background: #ffffff; box-shadow: 0 18px 50px rgba(31,35,41,.18); }
          .ks-skill-code { color: #52606d; }
          .ks-status-ready { color: #237a4b; }
          .ks-status-warn { color: #8a5a00; }
          .ks-knowledge-canvas { display: block; position: relative; min-height: 520px; overflow: auto; }
          .ks-knowledge-canvas [data-diagram-svg] { position: absolute; inset: 0; width: 980px; height: 560px; pointer-events: none; z-index: 0; }
          .ks-knowledge-canvas .ks-knowledge-card { position: absolute; width: 230px; min-height: 135px; }
          .ks-knowledge-canvas .ks-knowledge-card { z-index: 1; touch-action: none; user-select: none; }
          .ks-knowledge-canvas { height: 720px; overflow: auto; cursor: grab; touch-action: none; background-color: #f7f9fc; background-image: radial-gradient(#cbd7e5 1px, transparent 1px); background-size: 19px 19px; }
          .ks-knowledge-canvas.ks-panning { cursor: grabbing; }
          .ks-knowledge-canvas .ks-knowledge-card.ks-dragging { cursor: grabbing; border-color: #0f62fe; box-shadow: 0 12px 28px rgba(15,98,254,.24); }
          .ks-graph-layer { position: absolute; inset: 0; width: 1600px; height: 1000px; pointer-events: none; z-index: 0; }
          .ks-graph-layer svg { width: 1600px; height: 1000px; overflow: visible; }
          .ks-knowledge-canvas .ks-diagram-edge { fill: none; stroke: #0f62fe; stroke-width: 2.4; stroke-linecap: round; opacity: .84; pointer-events: stroke; }
          .ks-knowledge-canvas .ks-diagram-edge-preview { fill: none; stroke: #8a3ffc; stroke-width: 2.4; stroke-dasharray: 7 6; pointer-events: none; }
          .ks-knowledge-canvas .ks-edge-port { position: absolute; right: -13px; top: 50%; z-index: 3; width: 24px; height: 24px; padding: 0; transform: translateY(-50%); border: 2px solid #fff; border-radius: 50%; background: #0f62fe; color: #fff; cursor: crosshair; }
          .ks-knowledge-canvas .ks-edge-target { outline: 3px solid #8a3ffc; outline-offset: 4px; }
          .ks-knowledge-canvas.ks-creating-edge { cursor: crosshair; }
          .ks-knowledge-canvas > svg, .ks-knowledge-canvas > [data-node-layer] { position: absolute; inset: auto; top: 0; left: 0; width: 1600px; height: 1000px; min-width: 1600px; min-height: 1000px; }
          .ks-knowledge-canvas > svg { pointer-events: none; }
          .ks-knowledge-canvas .interactive-node { position: absolute; width: 278px; min-height: 190px; display: grid; gap: 9px; padding: 14px; background: #fff; border: 1px solid #aebed1; border-left: 5px solid #0f62fe; border-radius: 4px; box-shadow: 0 8px 20px rgba(23,58,106,.12); user-select: none; }
          .ks-knowledge-canvas .interactive-node.dragging { z-index: 20; box-shadow: 0 18px 40px rgba(23,58,106,.22); }
          .ks-knowledge-canvas .interactive-node header { display: grid; gap: 4px; }
          .ks-knowledge-canvas .interactive-node header small { color: #0f62fe; font-size: 9px; font-weight: 800; text-transform: uppercase; }
          .ks-knowledge-canvas .interactive-node header strong { color: #0043ce; font-size: 12px; line-height: 1.35; }
          .ks-knowledge-canvas .interactive-node p { margin: 0; color: #525252; font-size: 10px; }
          .ks-knowledge-canvas .edge-port { position: absolute; top: 50%; width: 18px; height: 18px; transform: translateY(-50%); border-radius: 50%; }
          .ks-knowledge-canvas .edge-port.in { left: -12px; background: #fff; border: 3px solid #90a6bf; }
          .ks-knowledge-canvas .edge-port.out { right: -13px; display: grid; place-items: center; padding: 0; color: #fff; background: #0f62fe; border: 2px solid #fff; border-radius: 50%; }
          .ks-knowledge-canvas .diagram-edge { fill: none; stroke: #5b6d85; stroke-width: 2.2; }
          .ks-knowledge-canvas .diagram-edge-label { position: absolute; z-index: 10; width: 154px; padding: 5px 8px; transform: translate(-50%, -50%); color: #0043ce; text-align: center; background: #fff; border: 1px solid #9fb2c9; border-radius: 999px; box-shadow: 0 4px 10px rgba(23,58,106,.1); font-size: 9px; font-weight: 700; }
          .ks-knowledge-canvas [data-diagram-node].ks-dragging { cursor: grabbing; border-color: #0f62fe; box-shadow: 0 8px 24px rgba(15,98,254,.24); }
          .ks-relation-list { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
          .ks-relation-label { padding: 5px 8px; border: 1px solid #dfe3e8; border-radius: 999px; background: #f8f9fa; color: #52606d; font-size: 11px; }
          /* Carbon Design System tokens and component surfaces. */
          :host {
            --cds-blue-60: #0f62fe;
            --cds-blue-70: #0043ce;
            --cds-gray-10: #f4f4f4;
            --cds-gray-20: #e0e0e0;
            --cds-gray-30: #c6c6c6;
            --cds-gray-70: #525252;
            --cds-gray-100: #161616;
            font-family: "IBM Plex Sans", "Segoe UI", sans-serif;
          }
          .ks-card, .ks-panel, .ks-stat { border-radius: 0; border-color: var(--cds-gray-20); box-shadow: none; }
          .ks-sidebar { border-right-color: var(--cds-gray-20); }
          .ks-nav button, .ks-footer button, .ks-row button, .ks-picker button,
          .ks-account-menu button { border-radius: 0; min-height: 40px; font-family: inherit; }
          .ks-nav button:hover, .ks-footer button:hover, .ks-row button:hover,
          .ks-picker button:hover, .ks-account-menu button:hover { background: var(--cds-gray-10); }
          .ks-primary-button { background: var(--cds-blue-60) !important; color: #ffffff !important; border-color: var(--cds-blue-60) !important; border-radius: 0 !important; }
          .ks-primary-button:hover { background: var(--cds-blue-70) !important; }
          .ks-form input, .ks-form textarea { border-radius: 0; border-color: var(--cds-gray-70); }
          .ks-message { border-radius: 0; border-left: 3px solid var(--cds-blue-60); }
          .ks-session-list button { border-radius: 0; }
          .ks-sidebar-account details, .ks-session-accordion { border-radius: 0; }
          .ks-sidebar-account summary, .ks-session-accordion summary { font-family: "IBM Plex Sans", sans-serif; font-weight: 600; }
          .ks-pill, .ks-relation-label { border-radius: 999px; background: var(--cds-gray-10); border-color: var(--cds-gray-30); }
          .ks-node, .ks-knowledge-card { border-radius: 0; box-shadow: 0 1px 2px rgba(0,0,0,.16); }
          .ks-knowledge-card:hover { border-color: var(--cds-blue-60); transform: none; }
          /* Knowledge editor: viewport fixa; somente a folha WYSIWYG rola. */
          .ks-app { height: 100vh; min-height: 0; overflow: hidden; }
          .ks-sidebar, .ks-panel { min-height: 0; overflow: hidden; }
          .ks-main:has(.ks-editor-layout) {
            min-height: 0;
            height: 100vh;
            overflow: hidden;
            grid-template-rows: auto minmax(0, 1fr);
          }
          .ks-main:has(.ks-editor-layout) .ks-editor-layout {
            min-height: 0;
            height: 100%;
            overflow: hidden;
          }
          .ks-main:has(.ks-editor-layout) .ks-editor,
          .ks-main:has(.ks-editor-layout) .ks-editor-main {
            min-height: 0;
            height: 100%;
            overflow: hidden;
            grid-template-rows: auto auto auto minmax(0, 1fr) auto;
          }
          .ks-main:has(.ks-editor-layout) .ks-rich-editor {
            min-height: 0;
            height: 100%;
            max-height: 100%;
            margin: 0 auto;
            overflow-x: hidden;
            overflow-y: auto;
          }
          .ks-main:has(.ks-editor-layout) .ks-editor-chat {
            min-height: 0;
            height: 100%;
            position: relative;
            top: auto;
          }
          @media (max-width: 1180px) {
            .ks-app { grid-template-columns: 210px minmax(0, 1fr); }
            .ks-panel { grid-column: 2; }
            .ks-stat-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
            .ks-subject-grid, .ks-skill-grid, .ks-study-layout { grid-template-columns: 1fr; }
          }
          @media (max-width: 700px) {
            .ks-app { grid-template-columns: 1fr; }
            .ks-sidebar, .ks-panel { grid-column: 1; }
            .ks-stat-grid { grid-template-columns: 1fr; }
            .ks-new-session-invite .ks-chat-composer { grid-template-columns: 1fr; }
            .ks-new-session-invite .ks-chat-composer cds-button { justify-self: stretch; }
          }
        """
        when states.MarkdownToolbarModuleUrl:
          script type = "module", src = states.MarkdownToolbarModuleUrl
        when states.KnowledgeWysiwygModuleUrl:
          script type = "module", src = states.KnowledgeWysiwygModuleUrl
        main class = "ks-app":
          aside class = "ks-sidebar":
            divi class = "ks-brand":
              strong "Mentis — Studio de Hardening de Conhecimento"
              small "Conversa → Processo → OKF → Safetensors"
            divi class = "ks-pill":
              text "Chave"
              span maskedKey(jsonStr(activeSettings(), "applicationKey"))
            details class = "cds--accordion__item" open:
              summary "Sessões"
              divi class = "ks-session-list":
                button SessionOpen(value = $jsonInt(activeSession(), "id")):
                  span SessionTitleValue states.SessionTitleDraft
              divi class = "ks-footer":
                CdsButton SessionCreate(class = "ks-primary-button", "kind" = "primary", value = "Nova sessão"):
                  text "+  Nova sessão"
            when states.ActivePage == "okf":
              article class = "ks-sidebar-properties":
                divi class = "ks-toolbar ks-properties-toolbar":
                  divi class = "ks-toolbar-copy":
                    strong "Propriedades"
                    small "Documento ativo"
                  CdsTag type = "blue":
                    text "OKF"
                divi class = "ks-property-grid":
                  divi class = "ks-property":
                    span class = "ks-property-label":
                      text "Documento"
                    span class = "ks-property-value":
                      text "Documento OKF aberto"
                  divi class = "ks-property":
                    span class = "ks-property-label":
                      text "Estado"
                    span class = "ks-property-value":
                      text "Edição ↔ conversa ↔ memória"
                  divi class = "ks-property":
                    span class = "ks-property-label":
                      text "Runtime"
                    span class = "ks-property-value":
                      text "Metis 4B · CUDA"
                  divi class = "ks-property ks-context-summary":
                    span class = "ks-property-label":
                      text "Contexto do modelo"
                    span class = "ks-property-value":
                      span ContextSummaryValue states.ContextSummary
            divi class = "ks-sidebar-account":
              details class = "cds--accordion__item":
                summary "Conta"
                divi class = "ks-account-menu":
                  button Configuracoes:
                    text "Conta e configurações"
                  button AppExit:
                    text "Sair"

          section class = "ks-main":
            CdsTabs class = "ks-system-tabs":
              CdsTab SessionTab:
                text "Sessões"
              CdsTab KnowledgeTab:
                text "Conhecimentos"
            when states.ActivePage == "materias":
              article class = "ks-card":
                divi class = "ks-toolbar":
                  divi:
                    strong "Habilidades BNCC em OKF"
                    small "Cada cartão abre uma matéria. Cada habilidade carrega seu OKF e seu safetensor Metis isolado."
                  span class = "ks-pill":
                    text $allRows("BnccSkill").len & " habilidades"
                divi class = "ks-subject-grid":
                  for subject in bnccSubjects():
                    article class = "ks-card ks-subject-card":
                      divi:
                        h3 jsonStr(subject, "name")
                        small $jsonInt(subject, "skillsCount") & " habilidades · Ensino Fundamental II"
                      divi class = "ks-footer":
                        span class = "ks-pill":
                          text "OKF + Metis"
                        button SubjectOpen(value = jsonStr(subject, "slug")):
                          text "Abrir matéria"

            when states.ActivePage == "materia":
              article class = "ks-card":
                divi class = "ks-toolbar":
                  divi:
                    strong $jsonStr(activeBnccSubject(), "name", "Matéria")
                    small $bnccSkillsForSubject(states.ActiveSubjectSlug).len & " tópicos/habilidades relacionados a OKF e tensor"
                  button Materias:
                    text "← Matérias"
                divi class = "ks-skill-grid":
                  for skill in bnccSkillsForSubject(states.ActiveSubjectSlug):
                    article class = "ks-card ks-skill-card":
                      span class = "ks-skill-code":
                        text $jsonStr(skill, "code") & " · " & $jsonStr(skill, "yearBlock")
                      strong $jsonStr(skill, "primaryCompetence", "Competência")
                      p class = "ks-skill-text":
                        text $jsonStr(skill, "statement")
                      small $jsonStr(skill, "axisNames", jsonStr(skill, "competences"))
                      divi class = "ks-footer":
                        span class = "ks-pill":
                          text $jsonStr(skill, "tensorStatus", "missing")
                        button BnccSkillOpen(value = jsonStr(skill, "code")):
                          text "Estudar com IA"

            when states.ActivePage == "estudo":
              let skill = activeBnccSkill()
              divi class = "ks-study-layout":
                article class = "ks-card":
                  divi class = "ks-toolbar":
                    divi:
                      span class = "ks-skill-code":
                        text $jsonStr(skill, "code") & " · " & $jsonStr(skill, "yearBlock")
                      h2 jsonStr(skill, "subject", "BNCC")
                    divi class = "ks-footer":
                      button SubjectOpen(value = jsonStr(skill, "subjectSlug")):
                        text "← Tópicos"
                      button SkillTensorReload(value = jsonStr(skill, "code")):
                        text "Recarregar tensor"
                  p class = "ks-skill-text":
                    text $jsonStr(skill, "statement")
                  divi class = "ks-footer":
                    span class = "ks-pill":
                      text "Competência: " & jsonStr(skill, "primaryCompetence")
                    span class = "ks-pill":
                      text "Tensor: " & jsonStr(skill, "tensorStatus", "missing")
                  divi class = "ks-study-chat":
                    for message in studyMessages(jsonStr(skill, "code")):
                      divi class = "ks-message":
                        b $jsonStr(message, "role")
                        text $jsonStr(message, "content")
                  divi class = "ks-form":
                    textarea StudyPromptDraft(value = binds states.StudyPromptDraft, placeholder = "Pergunte, pratique ou peça uma explicação desta habilidade…")
                    CdsButton StudySend("kind" = "primary", value = states.StudyPromptDraft):
                      text "Enviar e atualizar memória da habilidade"
                aside class = "ks-card ks-okf-source":
                  strong "Artefatos do tópico"
                  small "A página relaciona diretamente a habilidade ao OKF e ao estado Metis."
                  h4 "OKF"
                  divi class = "ks-path":
                    text $jsonStr(skill, "okfPath")
                  h4 "Safetensors"
                  divi class = "ks-path":
                    text $jsonStr(skill, "tensorPath")
                  h4 "Relações"
                  small "Matéria HAS_TOPIC Habilidade"
                  small "Habilidade HAS_OKF Documento"
                  small "OKF COMPILES_TO Safetensors"
                  h4 "Eixos Lumira"
                  small $jsonStr(skill, "axisNames", "Sem eixo adicional")
                  h4 "Competências"
                  small $jsonStr(skill, "competences")
                  divi class = "ks-footer":
                    button SkillTensorRebuild(value = jsonStr(skill, "code")):
                      text "Regerar do OKF"

            when states.ActivePage == "inicio":
              when states.SessionKnowledgeReady == false:
                article class = "ks-card ks-session-chat ks-new-session-invite":
                  divi class = "ks-invite-header":
                    span class = "ks-skill-code":
                      text "NOVA CONVERSA"
                    h2 "Comece uma nova conversa"
                  divi class = "ks-conversation-body":
                    divi class = "ks-empty-conversation":
                      strong "O que você quer transformar em conhecimento?"
                      p "Comece contando uma ideia, um processo ou uma pergunta. A primeira mensagem será a entrada desta sessão; quando objetivo, entradas, processo e resultado estiverem claros, ela se torna um conhecimento estruturado com documento OKF e memória relacionável."
                    divi class = "ks-chat ks-chat-rich":
                      for message in sessionMessages(activeSessionId()):
                        divi class = "ks-message":
                          b $jsonStr(message, "role", "user")
                          text $jsonStr(message, "content", "")
                  divi class = "ks-form ks-chat-composer":
                    textarea MessageDraft(value = binds states.MessageDraft, placeholder = "Conte por onde começamos…")
                    CdsButton MessageSend(class = "ks-primary-button", "kind" = "primary", value = states.MessageDraft):
                      text "Iniciar conversa →"

            when states.ActivePage == "canvas":
              article class = "ks-card":
                divi class = "ks-toolbar":
                  divi class = "ks-canvas-heading":
                    strong "Canvas de memórias"
                    small "Conecte documentos OKF como um grafo de conhecimento."
                  span class = "ks-pill":
                    text $knowledgeList().len & " cards"
                divi class = "ks-canvas ks-knowledge-canvas":
                  divi class = "ks-graph-layer":
                    text ""
                  article class = "ks-node ks-knowledge-card", id = "Embeddings e busca semântica", "data-diagram-node" = "true", "data-node-id" = "Embeddings e busca semântica", style = "left:80px;top:90px;":
                    span class = "ks-skill-code":
                      text "CONCEITO"
                    strong "Embeddings e busca semântica"
                    small "Representações vetoriais aproximam textos por significado."
                    button class = "ks-edge-port", title = "Criar ou conectar card", "data-edge-handle" = "true":
                      text "+"
                    button KnowledgeOpen(value = "Embeddings e busca semântica"):
                      text "Abrir OKF →"
                  article class = "ks-node ks-knowledge-card", id = "RAG com contexto local", "data-diagram-node" = "true", "data-node-id" = "RAG com contexto local", style = "left:370px;top:210px;":
                    span class = "ks-skill-code":
                      text "ARQUITETURA"
                    strong "RAG com contexto local"
                    small "Busca documentos OKF e entrega contexto ao modelo."
                    button class = "ks-edge-port", title = "Criar ou conectar card", "data-edge-handle" = "true":
                      text "+"
                    button KnowledgeOpen(value = "RAG com contexto local"):
                      text "Abrir OKF →"
                  article class = "ks-node ks-knowledge-card", id = "Quantização e inferência", "data-diagram-node" = "true", "data-node-id" = "Quantização e inferência", style = "left:680px;top:90px;":
                    span class = "ks-skill-code":
                      text "EXECUÇÃO"
                    strong "Quantização e inferência"
                    small "Reduz custo de memória para execução local."
                    button class = "ks-edge-port", title = "Criar ou conectar card", "data-edge-handle" = "true":
                      text "+"
                    button KnowledgeOpen(value = "Quantização e inferência"):
                      text "Abrir OKF →"
                  article class = "ks-node ks-knowledge-card", id = "Tokenização e contexto de linguagem", "data-diagram-node" = "true", "data-node-id" = "Tokenização e contexto de linguagem", style = "left:80px;top:390px;":
                    span class = "ks-skill-code":
                      text "LINGUAGEM"
                    strong "Tokenização e contexto de linguagem"
                    small "O Metis preserva relações entre termos, intenção e assunto durante a inferência."
                    button class = "ks-edge-port", title = "Criar ou conectar card", "data-edge-handle" = "true":
                      text "+"
                    button KnowledgeOpen(value = "Tokenização e contexto de linguagem"):
                      text "Abrir OKF →"
                  article class = "ks-node ks-knowledge-card", id = "Instrução estruturada para o Metis", "data-diagram-node" = "true", "data-node-id" = "Instrução estruturada para o Metis", style = "left:370px;top:510px;":
                    span class = "ks-skill-code":
                      text "APRIMORAMENTO"
                    strong "Instrução estruturada para o Metis"
                    small "Objetivo, contexto, restrições e saída tornam o comportamento mais consistente e auditável."
                    button class = "ks-edge-port", title = "Criar ou conectar card", "data-edge-handle" = "true":
                      text "+"
                    button KnowledgeOpen(value = "Instrução estruturada para o Metis"):
                      text "Abrir OKF →"
                  article class = "ks-node ks-knowledge-card", id = "Avaliação e refinamento de respostas", "data-diagram-node" = "true", "data-node-id" = "Avaliação e refinamento de respostas", style = "left:680px;top:390px;":
                    span class = "ks-skill-code":
                      text "APRIMORAMENTO"
                    strong "Avaliação e refinamento de respostas"
                    small "Critérios explícitos ajudam o Metis a identificar lacunas e refinar a próxima instrução."
                    button class = "ks-edge-port", title = "Criar ou conectar card", "data-edge-handle" = "true":
                      text "+"
                    button KnowledgeOpen(value = "Avaliação e refinamento de respostas"):
                      text "Abrir OKF →"
                  article class = "ks-node ks-knowledge-card", id = "Expressão semântica e composição de sentido", "data-diagram-node" = "true", "data-node-id" = "Expressão semântica e composição de sentido", style = "left:980px;top:90px;":
                    span class = "ks-skill-code":
                      text "SEMÂNTICA"
                    strong "Expressão semântica e composição de sentido"
                    small "Combina termos, contexto e intenção para produzir significado além da sequência literal."
                    button class = "ks-edge-port", title = "Criar ou conectar card", "data-edge-handle" = "true":
                      text "+"
                    button KnowledgeOpen(value = "Expressão semântica e composição de sentido"):
                      text "Abrir OKF →"
                  article class = "ks-node ks-knowledge-card", id = "Personalidade simbólica das conexões", "data-diagram-node" = "true", "data-node-id" = "Personalidade simbólica das conexões", style = "left:980px;top:390px;":
                    span class = "ks-skill-code":
                      text "SEMÂNTICA"
                    strong "Personalidade simbólica das conexões"
                    small "Padrões recorrentes entre conceitos dão ao grafo uma assinatura de associação observável."
                    button class = "ks-edge-port", title = "Criar ou conectar card", "data-edge-handle" = "true":
                      text "+"
                    button KnowledgeOpen(value = "Personalidade simbólica das conexões"):
                      text "Abrir OKF →"
                  divi class = "ks-relation-list":
                    span class = "ks-relation-label":
                      text "Embeddings → RAG · recupera contexto"
                    span class = "ks-relation-label":
                      text "RAG → Quantização · prepara execução"
                    span class = "ks-relation-label":
                      text "Embeddings → Quantização · otimiza memória"
                    span class = "ks-relation-label":
                      text "Linguagem → Expressão · compõe sentido"
                    span class = "ks-relation-label":
                      text "Expressão → Personalidade · estabiliza símbolos"
                    span class = "ks-relation-label":
                      text "Personalidade → RAG · orienta contexto"
                    span class = "ks-relation-label":
                      text "Tokenização → Instrução · organiza contexto"
                    span class = "ks-relation-label":
                      text "Instrução → Avaliação · refina resposta"
                divi class = "ks-footer":
                  CdsButton KnowledgeCreate(class = "ks-primary-button", "kind" = "primary"):
                    text "+ Novo card"

            when states.ActivePage == "okf":
              when activeKnowledge().kind != JNull:
                divi class = "ks-editor-layout":
                  article class = "ks-card ks-editor ks-editor-main":
                    divi class = "ks-toolbar":
                      divi:
                        span class = "ks-skill-code":
                          text "OKF / DOCUMENTO"
                        h2 "Documento OKF"
                      CdsButton BackToCanvas(class = "ks-secondary-button", "kind" = "tertiary"):
                        text "← Canvas"
                    small class = "ks-muted":
                      text "A edição é compartilhada com o Metis por eventos de sessão."
                    MarkdownToolbar class = "ks-markdown-toolbar", id = "knowledge-markdown-toolbar", "for" = "knowledge-wysiwyg-editor":
                      MdBold:
                        text "B"
                      MdHeader:
                        text "H"
                      MdItalic:
                        text "I"
                      MdQuote:
                        text "❝"
                      MdCode:
                        text "</>"
                      MdLink:
                        text "Link"
                      MdUnorderedList:
                        text "• Lista"
                      MdOrderedList:
                        text "1. Lista"
                      MdTaskList:
                        text "☑ Tarefa"
                    divi KnowledgeWysiwygEditor(class = "ks-rich-editor", id = "knowledge-wysiwyg-editor", contenteditable = "true", role = "textbox", aria-label = "Editor visual do documento OKF", spellcheck = "true", "aria-multiline" = "true")
                    divi class = "ks-editor-sync-state":
                      input KnowledgeDocumentDraft(id = "knowledge-markdown-state", type = "hidden", value = binds states.KnowledgeDocumentDraft, bindOn = "change")
                    divi class = "ks-footer":
                      span class = "ks-pill":
                        text "Revisão " & $jsonInt(activeKnowledge(), "revision", 1)
                      CdsButton KnowledgeSave(class = "ks-primary-button", "kind" = "primary", value = states.KnowledgeDocumentDraft):
                        text "Salvar e sincronizar"
                  aside class = "ks-card ks-editor-chat":
                    divi class = "ks-toolbar":
                      divi:
                        strong "Metis · conversa contextual"
                        small "O chat lê o documento atual e pode atualizá-lo."
                      span class = "ks-pill":
                        text "ciente do OKF"
                    divi class = "ks-chat":
                      for message in sessionMessages(activeSessionId()):
                        divi class = "ks-message":
                          b $jsonStr(message, "role", "user")
                          text $jsonStr(message, "content", "")
                    divi class = "ks-form":
                      textarea MessageDraft(value = binds states.MessageDraft, placeholder = "Peça revisão, síntese ou alteração no documento…")
                      CdsButton MessageSend(class = "ks-primary-button", "kind" = "primary", value = states.MessageDraft):
                        text "Enviar ao Metis →"
              when activeKnowledge().kind == JNull:
                article class = "ks-card":
                  strong "Documentos OKF"
                  divi class = "ks-list":
                    for doc in allRows("OkfDocument"):
                      divi class = "ks-row":
                        strong $jsonStr(doc, "title", "OKF")
                        small "rev " & $jsonInt(doc, "revision", 1)
                        small $jsonStr(doc, "filesystemPath", "")
                  divi class = "ks-footer":
                    button Canvas:
                      text "Abrir canvas"

            when states.ActivePage == "producoes":
              article class = "ks-card":
                strong "Produções Safetensors"
                divi class = "ks-list":
                  for job in allRows("SafetensorsProduction"):
                    divi class = "ks-row":
                      strong "Job #" & $jsonInt(job, "id")
                      small $jsonStr(job, "status", "pending")
                      small $jsonStr(job, "outputPath", jsonStr(job, "error", ""))
                      small $jsonStr(job, "sha256", "")
                divi class = "ks-footer":
                  button RequestSafetensors:
                    text "Novo job"

            when states.ActivePage == "configuracoes":
              article class = "ks-card":
                strong "Configurações"
                divi class = "ks-form":
                  input SettingsAuthorDraft(value = binds states.SettingsAuthorDraft, placeholder = "Autor")
                  input SettingsOkfDirectoryDraft(value = binds states.SettingsOkfDirectoryDraft, placeholder = "Pasta OKF")
                  input SettingsSafetensorsDirectoryDraft(value = binds states.SettingsSafetensorsDirectoryDraft, placeholder = "Pasta Safetensors")
                  input SettingsRepositoryOwnerDraft(value = binds states.SettingsRepositoryOwnerDraft, placeholder = "Owner")
                  input SettingsRepositoryNameDraft(value = binds states.SettingsRepositoryNameDraft, placeholder = "Repositório")
                  input SettingsRepositoryBranchDraft(value = binds states.SettingsRepositoryBranchDraft, placeholder = "Branch")
                  input SettingsRepositoryDirectoryDraft(value = binds states.SettingsRepositoryDirectoryDraft, placeholder = "Diretório")
                  input PendingOperationJson(value = binds states.PendingOperationJson, placeholder = "Chave mascarada")
                  button SaveSettings:
                    text "Salvar"
              article class = "ks-card":
                strong "Status"
                small states.StatusMessage

          aside class = "ks-panel":
            when states.ActivePage == "estudo":
              strong "Memória Metis ativa"
              small states.ActiveSkillCode
              small "O tensor é carregado ao abrir o tópico e salvo após cada troca de estudo."
              when activeBnccSkill().kind != JNull:
                divi class = "ks-row":
                  strong $jsonStr(activeBnccSkill(), "tensorStatus", "missing")
                  small $jsonStr(activeBnccSkill(), "tensorPath", "")
                  small "Último carregamento: " & jsonStr(activeBnccSkill(), "lastLoadedAt", "—")
            article class = "ks-context-properties":
              divi class = "ks-toolbar":
                divi:
                  strong "Propriedades"
                  small "Contexto da superfície ativa"
                CdsTag type = "blue":
                  text "contexto"
              divi class = "ks-property-grid":
                divi class = "ks-property":
                  span class = "ks-property-label":
                    text "Sessão"
                  span class = "ks-property-value":
                    text "Sessão ativa · eventos habilitados"
                when states.ActivePage == "okf":
                  divi class = "ks-property":
                    span class = "ks-property-label":
                      text "Documento"
                    span class = "ks-property-value":
                      text "OKF aberto no editor Markdown"
                  divi class = "ks-property":
                    span class = "ks-property-label":
                      text "Sincronização"
                    span class = "ks-property-value":
                      text "Edição ↔ conversa ↔ memória"
                when states.ActivePage == "canvas":
                  divi class = "ks-property":
                    span class = "ks-property-label":
                      text "Canvas"
                    span class = "ks-property-value":
                      text "Cards relacionáveis por arraste"
                  divi class = "ks-property":
                    span class = "ks-property-label":
                      text "Relações"
                    span class = "ks-property-value":
                      text "Linhas com labels e persistência"
                divi class = "ks-property":
                  span class = "ks-property-label":
                    text "Runtime"
                  span class = "ks-property-value":
                    text "Metis 4B · CUDA · GlaucoPlastic"

          when states.PendingPickerKind.len > 0:
            divi class = "ks-picker":
              strong if states.PendingPickerKind == "knowledge": "Selecionar tipo do card" else: "Selecionar tipo do nó"
              small "Use o seletor para materializar a conexão no vazio."
              divi class = "ks-footer":
                button ProcessPickerChoose(value = "start"):
                  text "Início"
                button ProcessPickerChoose(value = "task"):
                  text "Atividade"
                button ProcessPickerChoose(value = "decision"):
                  text "Decisão"
                button ProcessPickerChoose(value = "end"):
                  text "Fim"


          divi class = "ks-hidden":
            button Materias(value = "", id = "materias-handler") text ""
            button Inicio(value = "", id = "inicio-handler") text ""
            button Conversas(value = "", id = "conversas-handler") text ""
            button Canvas(value = "", id = "canvas-handler") text ""
            button BackToCanvas(value = "", id = "back-to-canvas-handler") text ""
            button DocumentosOkf(value = "", id = "okf-handler") text ""
            button Producoes(value = "", id = "producoes-handler") text ""
            button Configuracoes(value = "", id = "config-handler") text ""
            button SubjectOpen(value = "", id = "subject-open-handler") text ""
            button BnccSkillOpen(value = "", id = "bncc-skill-open-handler") text ""
            button StudySend(value = "", id = "study-send-handler") text ""
            button SkillTensorReload(value = "", id = "skill-reload-handler") text ""
            button SkillTensorRebuild(value = "", id = "skill-rebuild-handler") text ""
            button SessionCreate(value = "", id = "session-create-handler") text ""
            button SessionOpen(value = "", id = "session-open-handler") text ""
            button SessionRename(value = "", id = "session-rename-handler") text ""
            button SessionArchive(value = "", id = "session-archive-handler") text ""
            button MessageSend(value = "", id = "message-send-handler") text ""
            button KnowledgeCreate(value = "", id = "knowledge-create-handler") text ""
            button KnowledgeOpen(value = "", id = "knowledge-open-handler") text ""
            button KnowledgeFormatHeading(value = "", id = "knowledge-format-heading-handler") text ""
            button KnowledgeFormatBold(value = "", id = "knowledge-format-bold-handler") text ""
            button KnowledgeFormatBullet(value = "", id = "knowledge-format-bullet-handler") text ""
            button KnowledgeMove(value = "", id = "knowledge-move-handler") text ""
            button KnowledgeRelate(value = "", id = "knowledge-relate-handler") text ""
            button KnowledgeSave(value = "", id = "knowledge-save-handler") text ""
            button ProcessConfirm(value = "", id = "process-confirm-handler") text ""
            button OpenOkf(value = "", id = "open-okf-handler") text ""
            button RequestSafetensors(value = "", id = "request-safetensors-handler") text ""
            button SaveSettings(value = "", id = "settings-save-handler") text ""

      when Materias clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        stateSet(appRef.statesValue, "ActivePage", %("materias"))
        stateSet(appRef.statesValue, "StatusMessage", %("Catálogo BNCC"))
      when Inicio clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        stateSet(appRef.statesValue, "ActivePage", %("inicio"))
      when SessionTab clicks:
        states.EventValueDraft = eventValue
        stateSet(appRef.statesValue, "ActivePage", %("inicio"))
        stateSet(appRef.statesValue, "StatusMessage", %("Sessões"))
      when Canvas clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        stateSet(appRef.statesValue, "ActivePage", %("canvas"))
      when BackToCanvas clicks:
        states.EventValueDraft = eventValue
        stateSet(appRef.statesValue, "ActivePage", %("canvas"))
      when KnowledgeTab clicks:
        states.EventValueDraft = eventValue
        stateSet(appRef.statesValue, "ActivePage", %("canvas"))
        stateSet(appRef.statesValue, "StatusMessage", %("Conhecimentos"))
      when DocumentosOkf clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        stateSet(appRef.statesValue, "ActivePage", %("okf"))
      when Producoes clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        stateSet(appRef.statesValue, "ActivePage", %("producoes"))
      when Configuracoes clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        stateSet(appRef.statesValue, "ActivePage", %("configuracoes"))
      when AppExit clicks:
        quit(0)
      when SubjectOpen clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        stateSet(appRef.statesValue, "ActiveSubjectSlug", %(eventText))
        stateSet(appRef.statesValue, "ActivePage", %("materia"))
        stateSet(appRef.statesValue, "StatusMessage", %("Matéria aberta"))
      when BnccSkillOpen clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        stateSet(appRef.statesValue, "ActiveSkillCode", %(eventText))
        let skill = bnccSkillByCode(eventText)
        if skill.kind != JNull:
          stateSet(appRef.statesValue, "ActiveSubjectSlug", %(jsonStr(skill, "subjectSlug")))
          stateSet(appRef.statesValue, "ActivePage", %("estudo"))
          stateSet(appRef.statesValue, "StatusMessage", %("Carregando memória Metis de " & eventText))
          let response = loadBnccSkillMemory(eventText)
          stateSet(appRef.statesValue, "StatusMessage", %(responseStatus(response, "Tensor carregado: " & eventText, "Falha ao carregar tensor: " & jsonStr(response, "error", "erro"))))
      when StudySend clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let code = appStateStr("ActiveSkillCode")
        if code.len > 0:
          stateSet(appRef.statesValue, "StatusMessage", %("Estudando " & code & "…"))
          let response = studyWithBnccSkill(code, eventText)
          stateSet(appRef.statesValue, "StudyPromptDraft", %(""))
          stateSet(appRef.statesValue, "StatusMessage", %(responseStatus(response, "Memória da habilidade atualizada", "Falha no estudo: " & jsonStr(response, "error", "erro"))))
      when SkillTensorReload clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let code = if eventText.len > 0: eventText else: appStateStr("ActiveSkillCode")
        let response = loadBnccSkillMemory(code)
        stateSet(appRef.statesValue, "StatusMessage", %(responseStatus(response, "Tensor recarregado", "Falha ao recarregar tensor")))
      when SkillTensorRebuild clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let code = if eventText.len > 0: eventText else: appStateStr("ActiveSkillCode")
        let response = rebuildBnccSkillTensor(code)
        stateSet(appRef.statesValue, "StatusMessage", %(responseStatus(response, "Safetensor regerado a partir do OKF", "Falha ao regerar safetensor")))
      when SessionCreate clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let row = createSession(if eventText.len > 0: eventText else: "Nova conversa")
        stateSet(appRef.statesValue, "ActiveSessionId", %(jsonInt(row, "id")))
        stateSet(appRef.statesValue, "SessionKnowledgeReady", %false)
        stateSet(appRef.statesValue, "ActivePage", %("inicio"))
        stateSet(appRef.statesValue, "StatusMessage", %("Conversa criada"))
        refreshContextSummary("nova sessão")
      when SessionOpen clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let sid = safeParseInt(eventText)
        if sid > 0:
          stateSet(appRef.statesValue, "ActiveSessionId", %(sid))
          stateSet(appRef.statesValue, "SessionKnowledgeReady", %false)
          ensureActiveSelection()
          stateSet(appRef.statesValue, "ActivePage", %("inicio"))
          refreshContextSummary("sessão carregada")
      when SessionRename clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let sid = safeParseInt(eventText, activeSessionId())
        if sid > 0:
          if appStateStr("SessionRenameDraft").len > 0:
            discard renameSession(sid, appStateStr("SessionRenameDraft"))
      when SessionArchive clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let sid = safeParseInt(eventText)
        if sid > 0: discard archiveSession(sid)
      when MessageSend clicks:
        states.EventValueDraft = eventValue
        var eventText = appStateStr("EventValueDraft")
        if eventText.strip.len == 0:
          eventText = appStateStr("MessageDraft")
        if activeSessionId() > 0 and eventText.strip.len > 0:
          discard appendMessage(activeSessionId(), "user", eventText)
          if sessionKnowledgeReady() == false:
            if conversationLooksComplete(eventText):
              let knowledge = materializeConversationKnowledge(eventText)
              stateSet(appRef.statesValue, "SessionKnowledgeReady", %true)
              stateSet(appRef.statesValue, "KnowledgeDraftSummary", %jsonStr(knowledge, "summary", eventText.strip))
              stateSet(appRef.statesValue, "KnowledgeDocumentDraft", %(okfDraftForDocument(jsonInt(knowledge, "okfDocumentId"))))
              if jsonInt(knowledge, "okfDocumentId") > 0:
                discard appendMessage(activeSessionId(), "assistant", "Conhecimento identificado. O documento OKF produzido pelo Metis foi aberto para revisão.")
                stateSet(appRef.statesValue, "ActivePage", %("okf"))
              else:
                discard appendMessage(activeSessionId(), "assistant", "Conhecimento identificado. A memória foi registrada; o OKF será aberto assim que o Metis concluir a geração do documento.")
            else:
              discard appendMessage(activeSessionId(), "assistant", "Continue descrevendo o objetivo, o processo, as entradas e o resultado para eu identificar um conhecimento completo.")
          else:
            let knowledge = activeKnowledge()
            if knowledge.kind != JNull:
              let previousDraft = appStateStr("KnowledgeDraftSummary")
              let nextDraft = if previousDraft.strip.len > 0:
                previousDraft & "\n\n> Conversa: " & eventText.strip
              else:
                "> Conversa: " & eventText.strip
              stateSet(appRef.statesValue, "KnowledgeDraftSummary", %nextDraft)
              discard updateEntity("Knowledge", jsonInt(knowledge, "id"), proc(row: var JsonNode) =
                let previous = jsonStr(row, "summary", "")
                row["summary"] = %(previous & "\n\n> Conversa: " & eventText.strip)
                row["updatedAt"] = %nowIso()
                row["revision"] = %(jsonInt(row, "revision", 1) + 1)
              )
              discard appendMessage(activeSessionId(), "assistant", "Memória do conhecimento atualizada a partir do documento.")
          stateSet(appRef.statesValue, "MessageDraft", %(""))
          refreshContextSummary("conversa atualizada")
      when KnowledgeCreate clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let knowledge = createKnowledge(if eventText.len > 0: eventText else: "Novo conhecimento", "Card criado no canvas.", "knowledge", 280, 180, activeSessionId(), jsonInt(activeProcess(), "id"), 0)
        discard updateEntity("ConversationSession", activeSessionId(), proc(row: var JsonNode) = row["graphKnowledgeId"] = %jsonInt(knowledge, "id"))
        stateSet(appRef.statesValue, "SessionKnowledgeReady", %true)
        stateSet(appRef.statesValue, "ActivePage", %("canvas"))
        refreshContextSummary("novo conhecimento criado")
      when KnowledgeOpen clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let kid = safeParseInt(eventText)
        let knowledge = if kid > 0: ormGetById("Knowledge", kid) else: knowledgeByTitle(eventText)
        if knowledge.kind != JNull:
          let selectedKid = jsonInt(knowledge, "id")
          discard updateEntity("ConversationSession", activeSessionId(), proc(row: var JsonNode) = row["graphKnowledgeId"] = %selectedKid)
          let doc = createOkfSnapshot(activeSessionId(), jsonInt(activeProcess(), "id"), selectedKid, sessionMessages(activeSessionId()).len)
          if jsonInt(doc, "id") > 0:
            discard updateEntity("Knowledge", selectedKid, proc(row: var JsonNode) = row["okfDocumentId"] = %jsonInt(doc, "id"))
            stateSet(appRef.statesValue, "KnowledgeDocumentDraft", %(okfDraftForDocument(jsonInt(doc, "id"))))
          else:
            stateSet(appRef.statesValue, "StatusMessage", %("OKF ainda não produzido pelo Metis: " & jsonStr(doc, "error", "falha de geração")))
          stateSet(appRef.statesValue, "KnowledgeDraftSummary", %jsonStr(knowledge, "summary", ""))
          stateSet(appRef.statesValue, "SessionKnowledgeReady", %true)
          stateSet(appRef.statesValue, "StatusMessage", %("Memória safetensors/OKF carregada: " & jsonStr(knowledge, "title")))
          stateSet(appRef.statesValue, "ActivePage", %("okf"))
          refreshContextSummary("conhecimento aberto")
      when KnowledgeFormatHeading clicks:
        states.EventValueDraft = eventValue
        let draft = appStateStr("KnowledgeDocumentDraft")
        stateSet(appRef.statesValue, "KnowledgeDocumentDraft", %(if draft.strip.startsWith("# "): draft else: "# " & draft.strip))
      when KnowledgeFormatBold clicks:
        states.EventValueDraft = eventValue
        let draft = appStateStr("KnowledgeDocumentDraft")
        stateSet(appRef.statesValue, "KnowledgeDocumentDraft", %(if draft.strip.len > 0: draft & "\n\n**Trecho destacado**" else: "**Trecho destacado**"))
      when KnowledgeFormatBullet clicks:
        states.EventValueDraft = eventValue
        let draft = appStateStr("KnowledgeDocumentDraft")
        stateSet(appRef.statesValue, "KnowledgeDocumentDraft", %(if draft.strip.len > 0: draft & "\n\n- Novo item" else: "- Novo item"))
      when KnowledgeDocumentDraft changes:
        states.EventValueDraft = eventValue
        let draft = appStateStr("EventValueDraft")
        let docId = jsonInt(activeKnowledge(), "okfDocumentId")
        if docId > 0 and draft.strip.len > 0:
          discard updateEntity("OkfDocument", docId, proc(row: var JsonNode) =
            row["content"] = %draft
            row["updatedAt"] = %nowIso()
            row["revision"] = %(jsonInt(row, "revision", 1) + 1)
          )
          stateSet(appRef.statesValue, "StatusMessage", %("Edição do OKF sincronizada com o documento"))
      when KnowledgeMove changes:
        states.EventValueDraft = eventValue
        let move = payload(appStateStr("EventValueDraft"))
        var kid = safeParseInt(jsonStr(move, "id"))
        if kid <= 0:
          let byTitle = knowledgeByTitle(jsonStr(move, "id"))
          kid = jsonInt(byTitle, "id")
        if kid > 0:
          discard moveKnowledge(kid, jsonInt(move, "x"), jsonInt(move, "y"))
      when KnowledgeRelate changes:
        states.EventValueDraft = eventValue
        let relation = payload(appStateStr("EventValueDraft"))
        let fromKnowledge = knowledgeByTitle(jsonStr(relation, "from"))
        let toKnowledge = knowledgeByTitle(jsonStr(relation, "to"))
        let fromId = jsonInt(fromKnowledge, "id")
        let toId = jsonInt(toKnowledge, "id")
        if fromId > 0 and toId > 0:
          discard createKnowledgeRelation(fromId, toId, "related", jsonStr(relation, "label", "relaciona"))
      when KnowledgeSave clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let docId = jsonInt(activeKnowledge(), "okfDocumentId")
        if docId > 0:
          discard updateEntity("OkfDocument", docId, proc(row: var JsonNode) =
            row["content"] = %(if eventText.len > 0: eventText else: appStateStr("KnowledgeDocumentDraft"))
            row["updatedAt"] = %nowIso()
            row["revision"] = %(jsonInt(row, "revision", 1) + 1)
          )
          discard appendMessage(activeSessionId(), "assistant", "Documento OKF salvo; a memória do card permaneceu separada.")
          stateSet(appRef.statesValue, "StatusMessage", %("Documento OKF salvo separadamente"))
          refreshContextSummary("documento salvo")
      when ProcessConfirm clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let sid = activeSessionId()
        let pid = jsonInt(activeProcess(), "id")
        var knowledge = activeKnowledge()
        if sid > 0:
          if pid > 0:
            if knowledge.kind == JNull:
              knowledge = createKnowledge(jsonStr(activeProcess(), "title", "Processo"), jsonStr(activeProcess(), "description", ""), "process", 180, 180, sid, pid, 0)
            let doc = createOkfSnapshot(sid, pid, jsonInt(knowledge, "id"), sessionMessages(sid).len)
            if doc.kind != JNull:
              discard updateEntity("Knowledge", jsonInt(knowledge, "id"), proc(row: var JsonNode) = row["okfDocumentId"] = %jsonInt(doc, "id"))
              stateSet(appRef.statesValue, "StatusMessage", %("Processo confirmado em OKF"))
      when OpenOkf clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        stateSet(appRef.statesValue, "ActivePage", %("okf"))
      when RequestSafetensors clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        let knowledge = activeKnowledge()
        if knowledge.kind != JNull:
          if jsonInt(knowledge, "okfDocumentId") > 0:
            discard createSafetensorsJob(jsonInt(knowledge, "id"), jsonInt(knowledge, "okfDocumentId"), "IAAR-Shanghai/Metis-4B", "{}")
            stateSet(appRef.statesValue, "StatusMessage", %("Job registrado"))
      when SaveSettings clicks:
        states.EventValueDraft = eventValue
        let eventText = appStateStr("EventValueDraft")
        discard updateEntity("ApplicationSettings", 1, proc(row: var JsonNode) =
          row["authorName"] = %appStateStr("SettingsAuthorDraft")
          row["okfDirectory"] = %appStateStr("SettingsOkfDirectoryDraft")
          row["safetensorsDirectory"] = %appStateStr("SettingsSafetensorsDirectoryDraft")
          row["repositoryOwner"] = %appStateStr("SettingsRepositoryOwnerDraft")
          row["repositoryName"] = %appStateStr("SettingsRepositoryNameDraft")
          row["repositoryBranch"] = %appStateStr("SettingsRepositoryBranchDraft")
          row["repositoryDirectory"] = %appStateStr("SettingsRepositoryDirectoryDraft")
          row["updatedAt"] = %nowIso()
        )
        stateSet(appRef.statesValue, "StatusMessage", %("Configurações salvas"))
    
  agents:
    SessionArchitect("knowledge-architect", modo = "session"):
      purpose "Construir com o usuário uma descrição operacional completa de um processo de trabalho."
      when states.ActiveSessionId changed:
        discard

  render:
    Shell()

proc persistOkf(okf: PlasticOkfRuntime; document: JsonNode): JsonNode =
  okf.persist(document)

proc stateSet(states: PlasticStateRuntime; name: string; value: JsonNode) =
  states.set(name, value)

proc ormInsert(orm: PlasticOrmRuntime; entity: string; value: JsonNode): JsonNode =
  orm.insertRow(entity, value)

proc ormDelete(orm: PlasticOrmRuntime; entity: string; id: int): bool =
  orm.deleteById(entity, id)

proc ormUpdate(orm: PlasticOrmRuntime; entity: string; id: int; patch: JsonNode): JsonNode =
  orm.updateById(entity, id, patch)

proc ormWhere(orm: PlasticOrmRuntime; entity, field: string; expected: JsonNode): JsonNode =
  orm.whereEq(entity, field, expected)

proc stateGet(states: PlasticStateRuntime; name: string): JsonNode =
  states.get(name)

when isMainModule:
  appRef = application
  ensureDir(appRef.okfValue.rootPath / "KnowledgeStudio")
  ensureSeed()
  ensureDemoKnowledge()
  # O catálogo BNCC é opcional; o Study Studio inicia apenas com a estrutura
  # de sessões, canvas, processos, documentos OKF e chat contextual.
  stateSet(appRef.statesValue, "SettingsApplicationKeyMasked", %maskedKey(jsonStr(activeSettings(), "applicationKey")))
  stateSet(appRef.statesValue, "SettingsAuthorDraft", %jsonStr(activeSettings(), "authorName", ""))
  stateSet(appRef.statesValue, "SettingsOkfDirectoryDraft", %jsonStr(activeSettings(), "okfDirectory", OkfDir))
  stateSet(appRef.statesValue, "SettingsSafetensorsDirectoryDraft", %jsonStr(activeSettings(), "safetensorsDirectory", SafetensorsDir))
  stateSet(appRef.statesValue, "SettingsRepositoryOwnerDraft", %jsonStr(activeSettings(), "repositoryOwner", DefaultOwner))
  stateSet(appRef.statesValue, "SettingsRepositoryNameDraft", %jsonStr(activeSettings(), "repositoryName", DefaultRepo))
  stateSet(appRef.statesValue, "SettingsRepositoryBranchDraft", %jsonStr(activeSettings(), "repositoryBranch", DefaultBranch))
  stateSet(appRef.statesValue, "SettingsRepositoryDirectoryDraft", %jsonStr(activeSettings(), "repositoryDirectory", RepoDir))
  stateSet(appRef.statesValue, "MarkdownToolbarModuleUrl", %markdownToolbarDataUrl())
  stateSet(appRef.statesValue, "KnowledgeWysiwygModuleUrl", %knowledgeWysiwygDataUrl())
  ensureActiveSelection()
  refreshContextSummary("inicialização")
  stateSet(appRef.statesValue, "ActivePage", %"inicio")
  appRef.run(startModel = false)
















