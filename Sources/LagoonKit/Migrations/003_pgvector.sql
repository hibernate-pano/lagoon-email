CREATE EXTENSION IF NOT EXISTS vector;
-- Per spec section 6.6 rule 3, vector columns must always be bound as $1::vector in queries.
-- Actual message_embeddings table lands in M1 alongside the AI Gateway.