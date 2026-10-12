CREATE TABLE accounts (id TEXT PRIMARY KEY, issuer TEXT NOT NULL, subject TEXT NOT NULL, deleted_at TEXT, UNIQUE(issuer,subject));
CREATE TABLE sessions (id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES accounts(id), local_id TEXT NOT NULL, purpose TEXT NOT NULL CHECK(purpose IN ('sync','contribution')), fixture INTEGER NOT NULL, context TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open', next_sequence INTEGER NOT NULL DEFAULT 0, last_hash TEXT NOT NULL DEFAULT '', bytes INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, deleted_at TEXT, UNIQUE(owner,local_id));
CREATE TABLE chunks (session TEXT NOT NULL REFERENCES sessions(id), id TEXT NOT NULL, start_sequence INTEGER NOT NULL, end_sequence INTEGER NOT NULL, hash TEXT NOT NULL, previous_hash TEXT NOT NULL, object_key TEXT NOT NULL, bytes INTEGER NOT NULL, received_at TEXT NOT NULL, PRIMARY KEY(session,id), UNIQUE(session,start_sequence));
CREATE TABLE publications (id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES accounts(id), token_hash TEXT NOT NULL UNIQUE, object_key TEXT NOT NULL UNIQUE, projection_hash TEXT NOT NULL, bytes INTEGER NOT NULL, session TEXT REFERENCES sessions(id), created_at TEXT NOT NULL, revoked_at TEXT);
CREATE TABLE contribution_revisions (id TEXT PRIMARY KEY, session TEXT NOT NULL REFERENCES sessions(id), revision INTEGER NOT NULL, requested_at TEXT NOT NULL, withdrawn_at TEXT, UNIQUE(session,revision));
CREATE TABLE validations (session TEXT PRIMARY KEY REFERENCES sessions(id), completeness TEXT NOT NULL, eligible INTEGER NOT NULL, reasons TEXT NOT NULL, metrics TEXT NOT NULL, validated_at TEXT NOT NULL);
CREATE TABLE outbox (id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('validate','deleteSession','deletePublication','deleteAccount')), target TEXT NOT NULL, created_at TEXT NOT NULL, completed_at TEXT, generation INTEGER NOT NULL DEFAULT 1, content_cleaned_at TEXT, blocked_reason TEXT, UNIQUE(kind,target));
CREATE TABLE object_intents (object_key TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES accounts(id), session TEXT REFERENCES sessions(id), bytes INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN('uploading','deleting')), updated_at TEXT NOT NULL);
CREATE TABLE feedback_revisions (session TEXT NOT NULL REFERENCES sessions(id), segment_id TEXT NOT NULL, agent_id TEXT NOT NULL, message_id TEXT NOT NULL, revision INTEGER NOT NULL, selection TEXT NOT NULL CHECK(selection IN('favorite','negative','unmarked')), created_at TEXT NOT NULL, PRIMARY KEY(session,segment_id,agent_id,message_id,revision));
CREATE INDEX sessions_owner ON sessions(owner);
CREATE INDEX publications_owner ON publications(owner);
CREATE INDEX pending_jobs ON outbox(completed_at,created_at);
CREATE INDEX object_intents_owner ON object_intents(owner);
CREATE TRIGGER intent_guard BEFORE INSERT ON object_intents WHEN NOT EXISTS(SELECT 1 FROM object_intents WHERE object_key=NEW.object_key) BEGIN
 SELECT CASE WHEN (NEW.state='uploading' AND NOT EXISTS(SELECT 1 FROM accounts WHERE id=NEW.owner AND deleted_at IS NULL)) OR NEW.bytes>1048576 OR NEW.bytes<0 OR (SELECT count(*) FROM object_intents WHERE owner=NEW.owner)>=128 OR COALESCE((SELECT sum(bytes) FROM sessions WHERE owner=NEW.owner),0)+COALESCE((SELECT sum(bytes) FROM publications WHERE owner=NEW.owner),0)+COALESCE((SELECT sum(bytes) FROM object_intents WHERE owner=NEW.owner),0)+NEW.bytes>67108864 THEN RAISE(ABORT,'pending_object_quota') END;
END;
CREATE TRIGGER chunk_guard BEFORE INSERT ON chunks BEGIN
 SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM sessions JOIN accounts ON accounts.id=sessions.owner WHERE sessions.id=NEW.session AND sessions.status='open' AND sessions.deleted_at IS NULL AND accounts.deleted_at IS NULL AND sessions.next_sequence=NEW.start_sequence-1 AND sessions.last_hash=NEW.previous_hash AND sessions.bytes+NEW.bytes<=16777216 AND COALESCE((SELECT sum(bytes) FROM sessions s WHERE s.owner=sessions.owner),0)+COALESCE((SELECT sum(bytes) FROM publications WHERE owner=sessions.owner),0)+COALESCE((SELECT sum(bytes) FROM object_intents WHERE owner=sessions.owner AND object_key!=NEW.object_key),0)+NEW.bytes<=67108864) THEN RAISE(ABORT,'chunk_conflict_or_quota') END;
END;
CREATE TRIGGER chunk_advance AFTER INSERT ON chunks BEGIN
 UPDATE sessions SET next_sequence=NEW.end_sequence,last_hash=NEW.hash,bytes=bytes+NEW.bytes WHERE id=NEW.session;
 DELETE FROM object_intents WHERE object_key=NEW.object_key;
END;
CREATE TRIGGER publication_guard BEFORE INSERT ON publications BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM accounts WHERE id=NEW.owner AND deleted_at IS NULL) OR (NEW.session IS NOT NULL AND NOT EXISTS(SELECT 1 FROM sessions WHERE id=NEW.session AND owner=NEW.owner AND deleted_at IS NULL)) OR (SELECT count(*) FROM publications WHERE owner=NEW.owner)>=100 THEN RAISE(ABORT,'publication_conflict_or_quota') END;
END;
CREATE TRIGGER publication_commit AFTER INSERT ON publications BEGIN
 DELETE FROM object_intents WHERE object_key=NEW.object_key;
END;
CREATE TRIGGER session_guard BEFORE INSERT ON sessions BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM accounts WHERE id=NEW.owner AND deleted_at IS NULL) OR (SELECT count(*) FROM sessions WHERE owner=NEW.owner AND deleted_at IS NULL)>=200 THEN RAISE(ABORT,'session_conflict_or_quota') END;
END;
