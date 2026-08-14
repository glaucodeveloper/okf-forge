## Study Station — fragmento ORM GlaucoPlastic
##
## Este bloco deve ficar dentro de:
##
##   glaucoplastic StudyStationApplication, application:
##
## Os enums dos tipos fortes são persistidos como string. Estruturas variáveis
## (options, expected, payload, dimensions, metrics, filters, snapshots) são JSON.

orm:
  Account:
    uid string
    role string
    displayName string
    email string
    status string
    createdAt string
    updatedAt string

  Subject:
    uid string
    key string
    title string
    description string
    status string
    order int
    createdAt string
    updatedAt string

  Topic:
    uid string
    subjectUid string
    parentTopicUid string
    key string
    slug string
    title string
    summary string
    level int
    order int
    status string
    createdAt string
    updatedAt string

  TopicRelation:
    uid string
    fromTopicUid string
    toTopicUid string
    kind string
    weight float
    description string
    createdAt string

  TopicDocumentRef:
    uid string
    topicUid string
    okfSpace string
    okfId string
    status string
    currentVersion int
    checksum string
    updatedByAccountUid string
    updatedAt string

  TopicDocumentVersion:
    uid string
    topicDocumentUid string
    topicUid string
    version int
    okfSnapshotId string
    checksum string
    changeSummary string
    createdByAccountUid string
    createdAt string

  TopicChatThread:
    uid string
    topicUid string
    topicDocumentUid string
    createdByAccountUid string
    metisSession string
    createdAt string
    updatedAt string

  TopicChatMessage:
    uid string
    threadUid string
    role string
    content string
    documentVersion int
    createdAt string

  TopicDocumentSuggestion:
    uid string
    threadUid string
    topicUid string
    topicDocumentUid string
    baseVersion int
    title string
    explanation string
    patch json
    status string
    createdAt string
    resolvedAt string

  Student:
    uid string
    code string
    name string
    className string
    status string
    createdAt string
    updatedAt string

  Enrollment:
    uid string
    studentUid string
    subjectUid string
    enrolledAt string
    completedAt string
    active bool

  StudentMemoryProfile:
    uid string
    studentUid string
    profileKey string
    metisSession string
    memoryStateRef string
    lastRecordedAt string
    updatedAt string

  StudentTopicProgress:
    uid string
    studentUid string
    subjectUid string
    topicUid string

    mastery float
    confidence float
    band string

    activityCount int
    completedActivityCount int
    questionCount int
    correctAnswerCount int
    answerRevisionCount int
    studySeconds int

    lastActivityUid string
    lastActivityAt string

    learningSummary string
    difficultySummary string
    updatedAt string

  StudentTopicProgressSample:
    uid string
    studentTopicProgressUid string
    studentUid string
    topicUid string
    activityUid string
    mastery float
    confidence float
    correctRate float
    studySeconds int
    measuredAt string

  Activity:
    uid string
    studentUid string
    subjectUid string
    topicUid string

    kind string
    status string
    difficulty string

    title string
    description string

    generatedBy string
    sourceTopicDocumentVersion int

    startedAt string
    completedAt string
    durationSeconds int

    questionCount int
    answerCount int
    correctAnswerCount int
    answerRevisionCount int

    score float
    masteryBefore float
    masteryAfter float
    masteryGain float

    createdAt string
    updatedAt string

  Questionnaire:
    uid string
    activityUid string
    studentUid string
    subjectUid string
    topicUid string

    title string
    instructions string
    generatedByAgent string

    requestedQuestionCount int
    actualQuestionCount int
    passingScore float
    createdAt string

  Question:
    uid string
    questionnaireUid string
    activityUid string
    topicUid string

    position int
    kind string
    difficulty string

    prompt string
    options json
    expected json
    explanation string

    generatedByAgent string
    sourceEvidence json
    createdAt string

  Answer:
    uid string
    activityUid string
    questionnaireUid string
    questionUid string
    studentUid string
    topicUid string

    state string
    value json

    revision int
    correct bool
    score float
    confidence float

    firstChangedAt string
    confirmedAt string
    evaluatedAt string

  ActivityEvent:
    uid string
    activityUid string
    studentUid string
    topicUid string
    kind string
    sequence int
    payload json
    at string

  StudyAccessToken:
    uid string
    activityUid string
    studentUid string
    tokenHash string
    expiresAt string
    revokedAt string
    createdAt string

  ClientPresence:
    uid string
    clientId string
    role string
    studentUid string
    activityUid string
    state string
    connectedAt string
    lastSeenAt string

  ReportDefinition:
    uid string
    title string
    description string
    dimensions json
    metrics json
    filters json
    groupBy string
    visualization string
    createdByAccountUid string
    createdAt string
    updatedAt string

  ReportRun:
    uid string
    reportUid string
    periodStart string
    periodEnd string
    resultSnapshot json
    generatedAt string

  ReportInsight:
    uid string
    reportRunUid string
    kind string
    title string
    description string
    evidence json
    confidence float
    generatedBy string
    createdAt string
