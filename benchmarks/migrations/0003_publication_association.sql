ALTER TABLE publications ADD COLUMN local_id TEXT;
UPDATE publications SET local_id=(SELECT local_id FROM sessions WHERE id=publications.session) WHERE session IS NOT NULL;
CREATE INDEX publications_comparison ON publications(owner,local_id);
CREATE TRIGGER publication_association_guard BEFORE INSERT ON publications BEGIN
 SELECT CASE WHEN (NEW.session IS NOT NULL AND NOT EXISTS(SELECT 1 FROM sessions WHERE id=NEW.session AND owner=NEW.owner AND local_id=NEW.local_id AND deleted_at IS NULL)) OR EXISTS(SELECT 1 FROM sessions WHERE owner=NEW.owner AND local_id=NEW.local_id AND deleted_at IS NOT NULL) THEN RAISE(ABORT,'publication_association_conflict') END;
END;
ALTER TABLE object_intents ADD COLUMN local_id TEXT;
CREATE INDEX object_intents_comparison ON object_intents(owner,local_id);
CREATE TRIGGER object_intent_association_guard BEFORE INSERT ON object_intents BEGIN
 SELECT CASE WHEN NEW.state='uploading' AND EXISTS(SELECT 1 FROM sessions WHERE owner=NEW.owner AND local_id=NEW.local_id AND deleted_at IS NOT NULL) THEN RAISE(ABORT,'object_association_deleted') END;
END;
