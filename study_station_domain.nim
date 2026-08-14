## Study Station — modelo de domínio
##
## Tipos fortes usados pelo consumer GlaucoPlastic. O ORM persiste os mesmos
## elementos usando `uid` estável e JSON para estruturas variáveis.
##
## Relação central:
##
## Subject -> Topic -> TopicDocumentRef(OKF)
## Student -> StudentTopicProgress -> Topic
## StudentTopicProgress -> Activity -> Questionnaire -> Question -> Answer
## Activity -> ActivityEvent
## ReportDefinition -> ReportRun -> ReportInsight
##
## Progressos e questionários não são módulos globais: pertencem ao caminho
## do aluno dentro do mapa de matérias.

import std/[json, options, strutils, times]

type
  Uid* = string

  AccountRole* = enum
    arAdministrator
    arTeacher
    arObserver

  RecordStatus* = enum
    rsDraft
    rsActive
    rsArchived

  StudentStatus* = enum
    ssActive
    ssInactive
    ssArchived

  PresenceState* = enum
    psOffline
    psOnline
    psStudying
    psAnswering

  TopicRelationKind* = enum
    trkParent
    trkPrerequisite
    trkRelated
    trkSpecialization
    trkApplication
    trkContrast
    trkComplement

  TopicDocumentStatus* = enum
    tdsDraft
    tdsPublished
    tdsArchived

  SuggestionStatus* = enum
    sgsOpen
    sgsApplied
    sgsRejected

  MasteryBand* = enum
    mbLow       ## < 40
    mbBasic     ## 40 .. 59
    mbMedium    ## 60 .. 79
    mbHigh      ## >= 80

  ActivityKind* = enum
    akQuestionnaire
    akExercise
    akStudySession
    akSimulation
    akAiIntervention
    akReading
    akReview

  ActivityStatus* = enum
    asPlanned
    asAvailable
    asInProgress
    asCompleted
    asAbandoned
    asCancelled

  DifficultyLevel* = enum
    dlEasy
    dlMedium
    dlHard
    dlAdaptive

  QuestionKind* = enum
    qkSingleChoice
    qkMultipleChoice
    qkShortText
    qkLongText
    qkNumeric
    qkBoolean
    qkOrdering
    qkMatching

  AnswerState* = enum
    ansEditing
    ansConfirmed
    ansEvaluated

  ActivityEventKind* = enum
    aekOpened
    aekQuestionOpened
    aekAnswerChanged
    aekAnswerConfirmed
    aekAnswerEvaluated
    aekQuestionAdvanced
    aekQuestionReturned
    aekChatMessage
    aekPaused
    aekResumed
    aekCompleted
    aekAbandoned

  ReportDimension* = enum
    rdStudent
    rdClass
    rdSubject
    rdTopic
    rdPeriod
    rdActivityKind
    rdDifficulty
    rdMasteryBand

  ReportMetric* = enum
    rmStudentCount
    rmActiveStudentCount
    rmAverageMastery
    rmAverageConfidence
    rmAnswerAccuracy
    rmActivityCount
    rmCompletionRate
    rmStudyTime
    rmAnswerRevisionCount
    rmAverageResponseTime
    rmMasteryGain
    rmQuestionErrorRate

  ReportVisualization* = enum
    rvTable
    rvCards
    rvLine
    rvBars
    rvStackedBars
    rvDonut
    rvHeatmap
    rvKnowledgeMap

  InsightKind* = enum
    ikDifficulty
    ikRecurringError
    ikCorrelation
    ikMasteryGain
    ikRecommendation
    ikRisk
    ikOpportunity

  ChatRole* = enum
    crAdministrator
    crAssistant
    crSystem


type
  MetisRuntimeConfig* = object
    enabled*: bool
    managed*: bool
    host*: string
    port*: int
    modelId*: string
    device*: string
    dtypeName*: string
    quantization*: string
    queryTokens*: int
    workerMaxTokens*: int

  TunnelRuntimeConfig* = object
    enabled*: bool
    provider*: string
    targetHost*: string
    targetPort*: int

  StudyStationConfig* = object
    webHost*: string
    webPort*: int
    metis*: MetisRuntimeConfig
    tunnel*: TunnelRuntimeConfig


# ---------------------------------------------------------------------------
# Administração
# ---------------------------------------------------------------------------

type
  Account* = object
    uid*: Uid
    role*: AccountRole
    displayName*: string
    email*: string
    status*: RecordStatus
    createdAt*: string
    updatedAt*: string


# ---------------------------------------------------------------------------
# Matérias e mapa de conhecimento
# ---------------------------------------------------------------------------

type
  Subject* = object
    uid*: Uid
    key*: string
    title*: string
    description*: string
    status*: RecordStatus
    order*: int
    createdAt*: string
    updatedAt*: string

  Topic* = object
    uid*: Uid
    subjectUid*: Uid
    parentTopicUid*: Option[Uid]
    key*: string
    slug*: string
    title*: string
    summary*: string
    level*: int
    order*: int
    status*: RecordStatus
    createdAt*: string
    updatedAt*: string

  TopicRelation* = object
    uid*: Uid
    fromTopicUid*: Uid
    toTopicUid*: Uid
    kind*: TopicRelationKind
    weight*: float
    description*: string
    createdAt*: string

  TopicDocumentRef* = object
    ## O corpo corrente pertence ao OKF; este registro somente o referencia.
    uid*: Uid
    topicUid*: Uid
    okfSpace*: string
    okfId*: string
    status*: TopicDocumentStatus
    currentVersion*: int
    checksum*: string
    updatedByAccountUid*: Uid
    updatedAt*: string

  TopicDocumentVersion* = object
    uid*: Uid
    topicDocumentUid*: Uid
    topicUid*: Uid
    version*: int
    okfSnapshotId*: string
    checksum*: string
    changeSummary*: string
    createdByAccountUid*: Uid
    createdAt*: string

  TopicChatThread* = object
    uid*: Uid
    topicUid*: Uid
    topicDocumentUid*: Uid
    createdByAccountUid*: Uid
    metisSession*: string
    createdAt*: string
    updatedAt*: string

  TopicChatMessage* = object
    uid*: Uid
    threadUid*: Uid
    role*: ChatRole
    content*: string
    documentVersion*: int
    createdAt*: string

  TopicDocumentSuggestion* = object
    uid*: Uid
    threadUid*: Uid
    topicUid*: Uid
    topicDocumentUid*: Uid
    baseVersion*: int
    title*: string
    explanation*: string
    patch*: JsonNode
    status*: SuggestionStatus
    createdAt*: string
    resolvedAt*: string


# ---------------------------------------------------------------------------
# Alunos e matrícula
# ---------------------------------------------------------------------------

type
  Student* = object
    uid*: Uid
    code*: string
    name*: string
    className*: string
    status*: StudentStatus
    createdAt*: string
    updatedAt*: string

  Enrollment* = object
    uid*: Uid
    studentUid*: Uid
    subjectUid*: Uid
    enrolledAt*: string
    completedAt*: string
    active*: bool

  StudentMemoryProfile* = object
    ## O checkpoint Metis é compartilhado. A memória do aluno é identificada
    ## por sessão/perfil, e não por uma cópia do modelo.
    uid*: Uid
    studentUid*: Uid
    profileKey*: string
    metisSession*: string
    memoryStateRef*: string
    lastRecordedAt*: string
    updatedAt*: string


# ---------------------------------------------------------------------------
# Compreensão do aluno dentro do mapa
# ---------------------------------------------------------------------------

type
  StudentTopicProgress* = object
    uid*: Uid
    studentUid*: Uid
    subjectUid*: Uid
    topicUid*: Uid

    mastery*: float
    confidence*: float
    band*: MasteryBand

    activityCount*: int
    completedActivityCount*: int
    questionCount*: int
    correctAnswerCount*: int
    answerRevisionCount*: int
    studySeconds*: int

    lastActivityUid*: Option[Uid]
    lastActivityAt*: string

    ## Síntese explicável e pequena. A memória cognitiva completa permanece
    ## no Metis; este texto serve ao dashboard e relatórios.
    learningSummary*: string
    difficultySummary*: string

    updatedAt*: string

  StudentTopicProgressSample* = object
    ## Série temporal utilizada pelos gráficos de evolução.
    uid*: Uid
    studentTopicProgressUid*: Uid
    studentUid*: Uid
    topicUid*: Uid
    activityUid*: Option[Uid]

    mastery*: float
    confidence*: float
    correctRate*: float
    studySeconds*: int

    measuredAt*: string


# ---------------------------------------------------------------------------
# Atividades dentro de Student -> Subject -> Topic
# ---------------------------------------------------------------------------

type
  Activity* = object
    uid*: Uid

    studentUid*: Uid
    subjectUid*: Uid
    topicUid*: Uid

    kind*: ActivityKind
    status*: ActivityStatus
    difficulty*: DifficultyLevel

    title*: string
    description*: string

    generatedBy*: string
    sourceTopicDocumentVersion*: int

    startedAt*: string
    completedAt*: string
    durationSeconds*: int

    questionCount*: int
    answerCount*: int
    correctAnswerCount*: int
    answerRevisionCount*: int

    score*: float
    masteryBefore*: float
    masteryAfter*: float
    masteryGain*: float

    createdAt*: string
    updatedAt*: string

  Questionnaire* = object
    uid*: Uid
    activityUid*: Uid
    studentUid*: Uid
    subjectUid*: Uid
    topicUid*: Uid

    title*: string
    instructions*: string
    generatedByAgent*: string

    requestedQuestionCount*: int
    actualQuestionCount*: int
    passingScore*: float

    createdAt*: string

  QuestionOption* = object
    uid*: Uid
    value*: string
    label*: string
    order*: int

  Question* = object
    uid*: Uid
    questionnaireUid*: Uid
    activityUid*: Uid
    topicUid*: Uid

    position*: int
    kind*: QuestionKind
    difficulty*: DifficultyLevel

    prompt*: string
    options*: seq[QuestionOption]

    ## `expected` é JSON para comportar escolha, conjunto, número ou texto.
    expected*: JsonNode
    explanation*: string

    generatedByAgent*: string
    sourceEvidence*: JsonNode
    createdAt*: string

  Answer* = object
    uid*: Uid
    activityUid*: Uid
    questionnaireUid*: Uid
    questionUid*: Uid
    studentUid*: Uid
    topicUid*: Uid

    state*: AnswerState
    value*: JsonNode

    revision*: int
    correct*: bool
    score*: float
    confidence*: float

    firstChangedAt*: string
    confirmedAt*: string
    evaluatedAt*: string

  ActivityEvent* = object
    ## Log semântico usado pelo monitoramento em tempo real.
    uid*: Uid
    activityUid*: Uid
    studentUid*: Uid
    topicUid*: Uid
    kind*: ActivityEventKind
    sequence*: int
    payload*: JsonNode
    at*: string


# ---------------------------------------------------------------------------
# Acesso remoto e presença
# ---------------------------------------------------------------------------

type
  StudyAccessToken* = object
    uid*: Uid
    activityUid*: Uid
    studentUid*: Uid
    tokenHash*: string
    expiresAt*: string
    revokedAt*: string
    createdAt*: string

  ClientPresence* = object
    uid*: Uid
    clientId*: string
    role*: string
    studentUid*: Option[Uid]
    activityUid*: Option[Uid]
    state*: PresenceState
    connectedAt*: string
    lastSeenAt*: string


# ---------------------------------------------------------------------------
# Relatórios — leitura cruzada dos dados acima
# ---------------------------------------------------------------------------

type
  ReportFilter* = object
    field*: string
    op*: string
    value*: JsonNode

  ReportDefinition* = object
    uid*: Uid
    title*: string
    description*: string

    dimensions*: seq[ReportDimension]
    metrics*: seq[ReportMetric]
    filters*: seq[ReportFilter]

    groupBy*: Option[ReportDimension]
    visualization*: ReportVisualization

    createdByAccountUid*: Uid
    createdAt*: string
    updatedAt*: string

  ReportRun* = object
    uid*: Uid
    reportUid*: Uid

    periodStart*: string
    periodEnd*: string

    ## Snapshot é intencional: um relatório histórico não deve mudar quando
    ## o aluno realiza uma nova atividade depois da execução.
    resultSnapshot*: JsonNode
    generatedAt*: string

  ReportInsight* = object
    uid*: Uid
    reportRunUid*: Uid
    kind*: InsightKind

    title*: string
    description*: string
    evidence*: JsonNode
    confidence*: float

    generatedBy*: string
    createdAt*: string


# ---------------------------------------------------------------------------
# Views agregadas — runtime/UI, não precisam ser persistidas
# ---------------------------------------------------------------------------

type
  TopicNodeView* = object
    topic*: Topic
    relationKind*: Option[TopicRelationKind]
    children*: seq[TopicNodeView]

  StudentTopicNodeView* = object
    topic*: Topic
    progress*: StudentTopicProgress
    recentActivities*: seq[Activity]
    children*: seq[StudentTopicNodeView]

  StudentDashboardView* = object
    student*: Student
    overallMastery*: float
    totalActivities*: int
    studySeconds*: int
    rootSubjects*: seq[Subject]
    knowledgeMap*: seq[StudentTopicNodeView]

  TopicAdminView* = object
    subject*: Subject
    topic*: Topic
    document*: TopicDocumentRef
    relations*: seq[TopicRelation]
    thread*: Option[TopicChatThread]

  StudentTopicView* = object
    student*: Student
    subject*: Subject
    topic*: Topic
    progress*: StudentTopicProgress
    progressHistory*: seq[StudentTopicProgressSample]
    activities*: seq[Activity]

  ActivityMonitorView* = object
    student*: Student
    subject*: Subject
    topic*: Topic
    activity*: Activity
    questionnaire*: Option[Questionnaire]
    questions*: seq[Question]
    answers*: seq[Answer]
    events*: seq[ActivityEvent]
    presence*: seq[ClientPresence]


# ---------------------------------------------------------------------------
# Funções de domínio
# ---------------------------------------------------------------------------

proc masteryBand*(value: float): MasteryBand =
  if value < 40.0:
    mbLow
  elif value < 60.0:
    mbBasic
  elif value < 80.0:
    mbMedium
  else:
    mbHigh

proc answerAccuracy*(progress: StudentTopicProgress): float =
  if progress.questionCount <= 0:
    return 0.0
  (progress.correctAnswerCount.float / progress.questionCount.float) * 100.0

proc completionRate*(progress: StudentTopicProgress): float =
  if progress.activityCount <= 0:
    return 0.0
  (progress.completedActivityCount.float / progress.activityCount.float) * 100.0

proc isQuestionnaire*(activity: Activity): bool =
  activity.kind == akQuestionnaire

proc isLive*(activity: Activity): bool =
  activity.status == asInProgress

proc topicRoute*(topic: Topic): string =
  "/materias/" & topic.slug

proc studentRoute*(student: Student): string =
  "/alunos/" & student.uid

proc studentTopicRoute*(
  student: Student;
  subject: Subject;
  topic: Topic
): string =
  "/alunos/" & student.uid &
  "/materias/" & subject.key &
  "/assuntos/" & topic.slug

proc activityRoute*(
  student: Student;
  subject: Subject;
  topic: Topic;
  activity: Activity
): string =
  studentTopicRoute(student, subject, topic) &
  "/atividades/" & activity.uid
