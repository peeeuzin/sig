CREATE TABLE workflows (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  context JSONB NOT NULL DEFAULT '{}',
  definition JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE workflow_executions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id UUID NOT NULL REFERENCES workflows(id),
  status TEXT NOT NULL CHECK (status IN
    ('pending','running','suspended','completed','failed','cancelled')),
  current_step TEXT,
  context JSONB NOT NULL DEFAULT '{}',
  outputs JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_executions_status ON workflow_executions(status);
CREATE INDEX idx_executions_workflow ON workflow_executions(workflow_id);

CREATE TABLE execution_events (
  id BIGSERIAL PRIMARY KEY,
  execution_id UUID NOT NULL REFERENCES workflow_executions(id),
  seq INT NOT NULL,
  type TEXT NOT NULL,
  payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (execution_id, seq)
);

CREATE INDEX idx_events_execution ON execution_events(execution_id, seq);

CREATE TABLE step_executions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  execution_id UUID NOT NULL REFERENCES workflow_executions(id),
  step_id TEXT NOT NULL,
  attempt INT NOT NULL DEFAULT 1,
  status TEXT NOT NULL CHECK (status IN ('running','completed','failed')),
  idempotency_key TEXT NOT NULL,
  output JSONB,
  error TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ,
  UNIQUE (idempotency_key)
);

CREATE INDEX idx_steps_execution ON step_executions(execution_id, step_id);

CREATE TABLE outbox (
  id BIGSERIAL PRIMARY KEY,
  execution_id UUID NOT NULL REFERENCES workflow_executions(id),
  event_type TEXT NOT NULL,
  payload JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','failed')),
  attempts INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at TIMESTAMPTZ
);

CREATE INDEX idx_outbox_pending ON outbox(status) WHERE status = 'pending';