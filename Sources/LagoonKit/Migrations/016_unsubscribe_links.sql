-- One-click unsubscribe (一键退订): candidate URLs harvested from the
-- List-Unsubscribe header at sync time and from the HTML body the first
-- time the body is fetched. TEXT[] keeps order (first = best candidate);
-- both writers merge with first-occurrence dedupe so repeated syncs cannot
-- grow the array. The unsubscribe endpoint reads this column before falling
-- back to a live body fetch.
ALTER TABLE message_headers
    ADD COLUMN IF NOT EXISTS unsubscribe_links TEXT[] NOT NULL DEFAULT '{}';
