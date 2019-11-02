DROP TABLE IF EXISTS short_trans;
DROP TABLE IF EXISTS short_best_trans;
DROP TABLE IF EXISTS country_trans;
DROP TABLE IF EXISTS admin1codes_trans;
DROP TABLE IF EXISTS geoname_trans;
COMMIT;
CREATE EXTENSION pg_trgm;


CREATE TABLE short_trans AS
SELECT p.alternate_name_id, p.alternate_name, p.name_id, p.iso_language_code
FROM (
         SELECT DISTINCT ON (a.name_id, a.iso_language_code) a.name_id, a.iso_language_code, a.alternate_name_id AS aid
         FROM alternate_names a
         WHERE a.is_historic IS NULL
           AND a.iso_language_code IN
               ('en', 'ru', 'kk', 'ar', 'uz', 'ky', 'tr', 'id', 'ur', 'ms', 'th', 'nl', 'fr', 'de', 'it', 'jp', 'pt',
                'zh', 'es')
         ORDER BY a.name_id, a.iso_language_code, length(a.alternate_name)
     ) a
         JOIN alternate_names p ON p.alternate_name_id = a.aid AND p.name_id = a.name_id;
CREATE INDEX idx_short_trans_geonameid ON short_trans (name_id);

CREATE TABLE short_best_trans AS
SELECT p.alternate_name_id, p.alternate_name, p.name_id, p.iso_language_code
FROM (
         SELECT DISTINCT ON (a.name_id, a.iso_language_code) a.name_id, a.iso_language_code, a.alternate_name_id AS aid
         FROM alternate_names a
         WHERE a.is_historic IS NULL
           AND a.iso_language_code IN
               ('en', 'ru', 'kk', 'ar', 'uz', 'ky', 'tr', 'id', 'ur', 'ms', 'th', 'nl', 'fr', 'de', 'it', 'jp', 'pt',
                'zh', 'es')
         ORDER BY a.name_id, a.iso_language_code, round(length(a.alternate_name) / 3) ASC, a.alternate_name_id DESC
     ) a
         JOIN alternate_names p ON p.alternate_name_id = a.aid AND p.name_id = a.name_id;
CREATE INDEX idx_short_best_trans_geonameid ON short_best_trans (name_id);

-- Almaty
select *
from short_best_trans
where name_id = 1526384;
select *
from short_trans
where name_id = 1526384;
------------------------------------------------

---------------------------/* Create country_trans */-------------------------------
DROP TABLE IF EXISTS country_trans;

CREATE TABLE country_trans AS
SELECT c.iso_alpha2, c.name, json_object_agg(a.iso_language_code, a.alternate_name) AS trans
FROM country_info c
         JOIN short_trans a ON a.name_id = c.name_id
GROUP BY c.iso_alpha2, c.name;

ALTER TABLE country_trans
    ADD CONSTRAINT pk_country_trans
        PRIMARY KEY (iso_alpha2);

select *
from country_trans
where iso_alpha2 = 'KZ';

-------------------------------------------------------------------------------------

------------------------------/* Create admin1codes_trans */-------------------------------------

CREATE TABLE admin1codes_trans AS
SELECT c.code, c.ascii_name, c.name_id, json_object_agg(a.iso_language_code, a.alternate_name) AS trans
FROM admin1_ascii_codes c
         JOIN short_best_trans a ON a.name_id = c.name_id
GROUP BY c.code, c.ascii_name, c.name_id;

ALTER TABLE admin1codes_trans
    ADD CONSTRAINT pk_admin1codes_trans
        PRIMARY KEY (code);

------------------------------------------------------------------------------------------------------

-- Add the_geom field
CREATE EXTENSION postgis;
CREATE EXTENSION fuzzystrmatch;

SELECT AddGeometryColumn('names', 'the_geom', 4326, 'POINT', 2);

-- Fill the_geom field
UPDATE names
SET the_geom = ST_SetSRID(ST_Point(longitude, latitude), 4326)
WHERE name_id IN (
    SELECT name_id
    FROM names
    WHERE the_geom IS NULL
    LIMIT 1000000);

-- should be 0
SELECT count(name_id)
FROM names
WHERE the_geom IS NULL;

select *
from names
where name_id = 1526384;
select count(*)
from names;

------------------------------------------------------------------------------------------------------

------------------------------------------/* Create geoname_trans */----------------------------------
DROP TABLE IF EXISTS geoname_trans;

CREATE TABLE geoname_trans AS
WITH gtrans AS (
    SELECT a.name_id,
           json_object_agg(a.iso_language_code, a.alternate_name) AS trans,
           string_agg(a.alternate_name, ' ')                      as trans_str
    FROM short_best_trans a
    GROUP BY a.name_id
)
SELECT g.name_id                                                                                as geonameid,
       g.ascii_name                                                                             as asciiname,
       g.latitude,
       g.longitude,
       g.timezone,
       g.modified_at,
       g.the_geom,
       g.country_code                                                                           as country,
       concat_ws(' ', g.country_code, g.ascii_name::text, t.trans_str::text, g.alternate_names) as alternatenames,
       c.name_id                                                                                as admin1_geonameid,
       c.ascii_name                                                                             as admin1_asciiname,
       c.trans                                                                                  as admin1_trans,
       t.trans,
       ct.name                                                                                  as country_name,
       ct.trans                                                                                 as country_trans
FROM names g
         LEFT JOIN admin1codes_trans c ON c.code = concat_ws('.', g.country_code::text, g.admin1_code::text)
         LEFT JOIN gtrans t ON t.name_id = g.name_id
         JOIN country_trans ct ON ct.iso_alpha2 = g.country_code
WHERE g.feature_class = 'P'
  AND g.country_code NOT IN ('CS', 'AN');

ALTER TABLE geoname_trans ADD CONSTRAINT geoname_trans_pkey PRIMARY KEY (geonameid);
CREATE INDEX geoname_trans_alternatenames_idx ON geoname_trans USING GIN (alternatenames gin_trgm_ops);
CREATE INDEX idx_geoname_trans_geom ON geoname_trans USING gist (the_geom);

------------------------------------------------------------------------------------------------------------------------
select count(geonameid)
from geoname_trans; -- 4_730_747

select count(name_id)
from names
WHERE feature_class = 'P'; -- 4_730_747

select count(name_id)
from short_best_trans;
-- 3_426_999

-- pg_dump --format custom --host localhost --port 5432 --username sajda -t geoname_trans geonames -f geoname_trans.dump -v
-- pg_restore --host localhost --port 5432 --username sajda -t geoname_trans -d sajda geoname_trans.dump