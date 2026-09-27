-- nice-dns: carry the operator's Pi-hole lists into a new image seed
-- (Sub-plan 4 Task 2.2; user decision 2026-09-27: lists survive, the
-- configuration and the image's own blocklists come from the image).
--
-- Run by nd-start.sh against a fresh copy of the image's seed gravity.db,
-- with the volume's previous gravity.db attached as "old". Rows are matched
-- by their natural keys, never by id: groups by name, domain rules by
-- (domain, type), clients by ip, blocklists by (address, type). The
-- operator's enabled state and comment win for rows both hold. Blocklists
-- only the operator added keep their downloaded domains, so they keep
-- blocking until the next gravity update. Any error stops here and leaves
-- the seed copy uncommitted; nd-start.sh then keeps the previous lists.
.bail on
ATTACH '@OLD@' AS old;
BEGIN;

INSERT OR IGNORE INTO "group" (enabled, name, date_added, date_modified, description)
  SELECT enabled, name, date_added, date_modified, description FROM old."group" WHERE id != 0;
UPDATE "group" SET enabled = (SELECT o.enabled FROM old."group" o WHERE o.name = "group".name),
                   description = (SELECT o.description FROM old."group" o WHERE o.name = "group".name)
  WHERE name IN (SELECT name FROM old."group");

INSERT OR IGNORE INTO domainlist (type, domain, enabled, date_added, date_modified, comment)
  SELECT type, domain, enabled, date_added, date_modified, comment FROM old.domainlist;
UPDATE domainlist SET
    enabled = (SELECT o.enabled FROM old.domainlist o WHERE o.domain = domainlist.domain AND o.type = domainlist.type),
    comment = (SELECT o.comment FROM old.domainlist o WHERE o.domain = domainlist.domain AND o.type = domainlist.type)
  WHERE EXISTS (SELECT 1 FROM old.domainlist o WHERE o.domain = domainlist.domain AND o.type = domainlist.type);
DELETE FROM domainlist_by_group WHERE domainlist_id IN
  (SELECT n.id FROM domainlist n JOIN old.domainlist o ON o.domain = n.domain AND o.type = n.type);
INSERT OR IGNORE INTO domainlist_by_group (domainlist_id, group_id)
  SELECT n.id, g.id FROM old.domainlist_by_group ob
    JOIN old.domainlist o ON o.id = ob.domainlist_id
    JOIN old."group" og ON og.id = ob.group_id
    JOIN domainlist n ON n.domain = o.domain AND n.type = o.type
    JOIN "group" g ON g.name = og.name;

INSERT OR IGNORE INTO client (ip, date_added, date_modified, comment)
  SELECT ip, date_added, date_modified, comment FROM old.client;
DELETE FROM client_by_group WHERE client_id IN (SELECT n.id FROM client n JOIN old.client o ON o.ip = n.ip);
INSERT OR IGNORE INTO client_by_group (client_id, group_id)
  SELECT n.id, g.id FROM old.client_by_group ob
    JOIN old.client o ON o.id = ob.client_id
    JOIN old."group" og ON og.id = ob.group_id
    JOIN client n ON n.ip = o.ip
    JOIN "group" g ON g.name = og.name;

CREATE TEMP TABLE nd_seed_lists AS SELECT address, type FROM main.adlist;
INSERT OR IGNORE INTO adlist (address, enabled, date_added, date_modified, comment, date_updated,
                              number, invalid_domains, status, abp_entries, type)
  SELECT address, enabled, date_added, date_modified, comment, date_updated,
         number, invalid_domains, status, abp_entries, type FROM old.adlist;
UPDATE adlist SET
    enabled = (SELECT o.enabled FROM old.adlist o WHERE o.address = adlist.address AND o.type = adlist.type),
    comment = (SELECT o.comment FROM old.adlist o WHERE o.address = adlist.address AND o.type = adlist.type)
  WHERE EXISTS (SELECT 1 FROM old.adlist o WHERE o.address = adlist.address AND o.type = adlist.type);
DELETE FROM adlist_by_group WHERE adlist_id IN
  (SELECT n.id FROM adlist n JOIN old.adlist o ON o.address = n.address AND o.type = n.type);
INSERT OR IGNORE INTO adlist_by_group (adlist_id, group_id)
  SELECT n.id, g.id FROM old.adlist_by_group ob
    JOIN old.adlist o ON o.id = ob.adlist_id
    JOIN old."group" og ON og.id = ob.group_id
    JOIN adlist n ON n.address = o.address AND n.type = o.type
    JOIN "group" g ON g.name = og.name;
INSERT INTO gravity (domain, adlist_id)
  SELECT og.domain, n.id FROM old.gravity og
    JOIN old.adlist o ON o.id = og.adlist_id
    JOIN adlist n ON n.address = o.address AND n.type = o.type
  WHERE NOT EXISTS (SELECT 1 FROM temp.nd_seed_lists s WHERE s.address = o.address AND s.type = o.type);
INSERT INTO antigravity (domain, adlist_id)
  SELECT og.domain, n.id FROM old.antigravity og
    JOIN old.adlist o ON o.id = og.adlist_id
    JOIN adlist n ON n.address = o.address AND n.type = o.type
  WHERE NOT EXISTS (SELECT 1 FROM temp.nd_seed_lists s WHERE s.address = o.address AND s.type = o.type);
UPDATE info SET value = (SELECT COUNT(DISTINCT domain) FROM gravity) WHERE property = 'gravity_count';
UPDATE info SET value = (SELECT COUNT(DISTINCT domain) FROM antigravity) WHERE property = 'antigravity_count';

COMMIT;
