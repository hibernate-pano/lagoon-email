-- V2 A3 follow-up: the durable body store must carry recipients.
--
-- `message_bodies` was created in 015 without the `To:`/`Cc:` addresses, so
-- every re-open of an already-fetched message (the store-hit path in
-- `MessageRoutes.fetchBody`) answered `to: [], cc: []`. The client then drops
-- the To:/Cc: rows and degrades reply-all to reply-to-sender. The 60s memory
-- cache this store replaced did preserve them, so this was a regression.
--
-- TEXT[] matches 016's `unsubscribe_links` idiom: order-preserving (the wire
-- contract keeps header order), NOT NULL so the read path never has to
-- distinguish "no recipients" from "unknown recipients", and idempotent for
-- databases where 015 is already applied.
--
-- Also corrects the FTS claim made in 015: the index there is on
-- `to_tsvector('simple', body_text)` and the search query now uses the same
-- expression, but the leading-wildcard `ILIKE` arm of the OR still forces a
-- sequential scan for the whole predicate, so the GIN index is not a usable
-- plan for the combined query — see the `# ponytail:` note in
-- `DraftRoutes.search`. 015 is left untouched (already applied everywhere);
-- this comment is the correction of record.
ALTER TABLE message_bodies
    ADD COLUMN IF NOT EXISTS to_addresses TEXT[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS cc_addresses TEXT[] NOT NULL DEFAULT '{}';
