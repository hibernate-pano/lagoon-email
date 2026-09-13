-- A client-generated request id makes a retried send observable. The API
-- checks this key before calling the provider, so a response lost after a
-- successful delivery does not send the same reply twice.
CREATE UNIQUE INDEX IF NOT EXISTS ai_actions_send_request_idx
    ON ai_actions (account_id, (payload->>'requestId'))
    WHERE kind = 'send' AND payload ? 'requestId';
