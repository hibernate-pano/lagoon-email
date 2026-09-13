-- M1.6: IMAP UID is mailbox-local and changes after MOVE. Use the RFC 5322
-- Message-ID as the stable remote identity for rows that have one.
CREATE TEMP TABLE lagoon_remote_id_map AS
WITH ranked AS (
    SELECT
        account_id,
        remote_id AS old_remote_id,
        message_id_header AS new_remote_id,
        row_number() OVER (
            PARTITION BY account_id, message_id_header
            ORDER BY fetched_at, remote_id
        ) AS rn
    FROM message_headers
    WHERE message_id_header IS NOT NULL
      AND message_id_header <> ''
      AND remote_id <> message_id_header
)
SELECT account_id, old_remote_id, new_remote_id
FROM ranked
WHERE rn = 1
  AND NOT EXISTS (
      SELECT 1
      FROM message_headers existing
      WHERE existing.account_id = ranked.account_id
        AND existing.remote_id = ranked.new_remote_id
  );

UPDATE message_pins pins
SET remote_id = map.new_remote_id
FROM lagoon_remote_id_map map
WHERE pins.account_id = map.account_id
  AND pins.remote_id = map.old_remote_id;

UPDATE draft_replies drafts
SET remote_id = map.new_remote_id
FROM lagoon_remote_id_map map
WHERE drafts.account_id = map.account_id
  AND drafts.remote_id = map.old_remote_id;

UPDATE ai_overrides overrides
SET remote_id = map.new_remote_id
FROM lagoon_remote_id_map map
WHERE overrides.account_id = map.account_id
  AND overrides.remote_id = map.old_remote_id;

UPDATE ai_actions actions
SET payload = jsonb_set(payload, '{remoteId}', to_jsonb(map.new_remote_id::text), true)
FROM lagoon_remote_id_map map
WHERE actions.account_id = map.account_id
  AND actions.payload->>'remoteId' = map.old_remote_id;

UPDATE message_headers messages
SET remote_id = map.new_remote_id
FROM lagoon_remote_id_map map
WHERE messages.account_id = map.account_id
  AND messages.remote_id = map.old_remote_id;

DROP TABLE lagoon_remote_id_map;
