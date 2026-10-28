-- Links Harlyy locations (and later Chowdeck listings) to the company store master,
-- public.pulse_store_master_map, so every piece of feedback has a store_number, area and
-- business unit. Run after 01_tables.sql and before 05_alert_feed.sql.
--
-- How a Harlyy location gets its store:
--   1. A row in store_map_overrides (manual), if there is one; store_number NULL there
--      means "not a physical store" (online channels).
--   2. Otherwise by name: Harlyy "CSC IKOTA" = master brand "CSC" + store_name "IKOTA",
--      same country, ignoring case and extra spaces.
--   3. Otherwise unmatched: add an override below and re-run this file.
--
-- Master brand codes: DP Domino's Pizza, CSC Cold Stone Creamery, PB Pinkberry,
-- PP Pastry Planet (newer; its stores were not in Harlyy on 2026-10-23).
--
-- On 2026-10-23 every Nigerian store matched by name (three only once double spaces
-- are ignored); the Kenyan locations and the online channels are listed below by hand.
-- New Nigerian stores named "<BRAND> <STORE NAME>" in Harlyy match on their own.


CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.store_map_overrides (
    id_type      VARCHAR(32)  NOT NULL,    -- 'location' or 'listing'
    harlyy_id    VARCHAR(128) NOT NULL,    -- Harlyy location_id, or review listing_id (Chowdeck / Google)
    store_number INTEGER,                  -- public.pulse_store_master_map.store_number; NULL = online / no store
    note         VARCHAR(256),
    updated_at   TIMESTAMP DEFAULT GETDATE()
);

-- This file is the source of truth for the manual links: edit the list and re-run.
BEGIN;
DELETE FROM harlyy_feedback_analytics.store_map_overrides WHERE id_type = 'location';
INSERT INTO harlyy_feedback_analytics.store_map_overrides (id_type, harlyy_id, store_number, note) VALUES
    -- Kenya, Cold Stone
    ('location', 'loc_69e8faa61fd2c36626aec64e', 23219, 'Cold Stone - UN Corner'),
    ('location', 'loc_69e8fdf4fbfcfd569919c5d7', 23887, 'Cold Stone Creamery - City Mall, Nyali'),
    ('location', 'loc_69e8fb98fbfcfd5699190f68', 23578, 'Cold Stone Creamery - Galleria Mall'),
    ('location', 'loc_69e8fcf3fbfcfd56991979b1', 23647, 'Cold Stone Creamery - Mega Mall'),
    ('location', 'loc_69e8fc761fd2c36626af45d5', 23653, 'Cold Stone Creamery - Sarit Centre phase 3'),
    ('location', 'loc_69e8fa5efbfcfd569918be77', 23221, 'Cold Stone Creamery - The Hub'),
    ('location', 'loc_69e8fbd5fbfcfd569919230e', 23507, 'Cold Stone Creamery - The Junction Mall'),
    ('location', 'loc_69e8fc2d1fd2c36626af3025', 23296, 'Cold Stone Creamery - The Village Market'),
    ('location', 'loc_69e8fc501fd2c36626af3a14', 23343, 'Cold Stone Creamery - Thika Road Mall'),
    ('location', 'loc_69e8f9e1fbfcfd5699189949', 23220, 'Cold Stone Creamery - Westlands (master: WESTLANDS SQUARE)'),
    ('location', 'loc_69e8fcc0fbfcfd569919696b', 23495, 'Cold Stone Creamery - Yaya Center'),
    ('location', 'loc_69e8fb6d1fd2c36626aef6f9', 24461, 'Cold Stone Creamery Kenya - Kimathi Street'),
    ('location', 'loc_69e8fc02fbfcfd5699193224', 23508, 'Cold Stone Creamery Kenya - Valley Arcade'),
    ('location', 'loc_69e8fa2b81361621778d7606', 24039, 'Cold Stone Creamery Kenya, Embakasi Branch'),
    ('location', 'loc_69e8fc9881361621778e328f', 24382, 'Cold Stone Creamery Mwanzi Market'),
    ('location', 'loc_69e8fb3f1fd2c36626aeec00', 24119, 'Cold Stone Kahawa (master: KAHAWA SUKARI)'),
    ('location', 'loc_6a4502f3aae99504495110c7', NULL,  'Cold Stone KE Website - online, no store'),
    -- Kenya, Domino's
    ('location', 'loc_69e8e2401fd2c36626a81f8d', 57336, 'Domino''s Nextgen Mall'),
    ('location', 'loc_69e8e30b1fd2c36626a85a4f', 57334, 'Domino''s Pizza - Hurlingham'),
    ('location', 'loc_69e8e38d1fd2c36626a88212', 57338, 'Domino''s Pizza - Kahawa Sukari'),
    ('location', 'loc_69e8e490fbfcfd56991279df', 57335, 'Domino''s Pizza - Ngong Road'),
    ('location', 'loc_69e8e2ccfbfcfd569911f2c7', 57333, 'Domino''s Pizza - The hub'),
    ('location', 'loc_69e8e40ffbfcfd569912568e', 57332, 'Domino''s Pizza City Mall'),
    ('location', 'loc_69e8e0aa1fd2c36626a7bce4', 57337, 'Domino''s Pizza Embakasi'),
    ('location', 'loc_69e8e45afbfcfd5699126d1e', 57339, 'Domino''s Pizza Kenya - Kimathi Street'),
    ('location', 'loc_69e8e35a8136162177869e03', 57331, 'Dominos Pizza - Un Corner Gigiri Shopping Centre'),
    ('location', 'loc_69e8e05a813616217785c9bb', 57330, 'Domino''s Pizza Westlands (master: WESTLANDS SQUARE)'),
    -- Nigeria, online channels
    ('location', 'loc_69cd2d4eb2148b2514850fcf', NULL,  'Online - Cold Stone, no store'),
    ('location', 'loc_69cd2c5fee8f5a5eb27f71e4', NULL,  'Online - Dominos, no store'),
    ('location', 'loc_69cd2d7ab2148b25148517a2', NULL,  'Online - Pinkberry, no store');
COMMIT;

-- Review listings with no Harlyy location: every Chowdeck listing, and the few Google
-- listings not linked in Harlyy. Matched by name and the area in the Chowdeck URL;
-- the ambiguous ones were confirmed by operations on 2026-10-23.
BEGIN;
DELETE FROM harlyy_feedback_analytics.store_map_overrides WHERE id_type = 'listing';
INSERT INTO harlyy_feedback_analytics.store_map_overrides (id_type, harlyy_id, store_number, note) VALUES
    -- Chowdeck, Cold Stone
    ('listing', 'lst_6a70af4ac5350600171d5b26', 23408, 'Cold Stone Creamery - AGIDINGBI'),
    ('listing', 'lst_6a6c5866f8eefd7e38e26b65', 23560, 'Cold Stone Creamery - Abeokuta 1 (URL: Ibara)'),
    ('listing', 'lst_6a6c5866f8eefd7e38e26b5d', 23901, 'Cold Stone Creamery - Abeokuta 2 (Abiola Way)'),
    ('listing', 'lst_6a70b527c5350600171d9068', 23040, 'Cold Stone Creamery - Admiralty 1'),
    ('listing', 'lst_6a70b527c5350600171d9065', 23838, 'Cold Stone Creamery - Admiralty 2'),
    ('listing', 'lst_6a70af4ac5350600171d5b20', 23218, 'Cold Stone Creamery - Agungi'),
    ('listing', 'lst_6a719498d18bae7dc4d70474', 23649, 'Cold Stone Creamery - Ajao'),
    ('listing', 'lst_6a67370416310d1825502fe0', 23914, 'Cold Stone Creamery - Ajose'),
    ('listing', 'lst_6a6c582df8eefd7e38e261d8', 23900, 'Cold Stone Creamery - Akobo'),
    ('listing', 'lst_6a70af4ac5350600171d5b24', 23828, 'Cold Stone Creamery - Ali Akilu'),
    ('listing', 'lst_6a70af4ac5350600171d5b19', 23163, 'Cold Stone Creamery - Apapa'),
    ('listing', 'lst_6a6737a116310d1825503231', 23624, 'Cold Stone Creamery - Apo'),
    ('listing', 'lst_6a70af4ac5350600171d5b1d', 23836, 'Cold Stone Creamery - Aromire'),
    ('listing', 'lst_6a6c58c7f8eefd7e38e279f0', 23753, 'Cold Stone Creamery - BENIN SAPELE'),
    ('listing', 'lst_6a6c58c7f8eefd7e38e279eb', 23755, 'Cold Stone Creamery - BENIN UGBOWO'),
    ('listing', 'lst_6a70af4ac5350600171d5b15', 23716, 'Cold Stone Creamery - Badore'),
    ('listing', 'lst_6a70af4ac5350600171d5b18', 23827, 'Cold Stone Creamery - Barnawa'),
    ('listing', 'lst_6a74a89de5ce5b6c7bf83ae2', 23898, 'Cold Stone Creamery - Bodethomas'),
    ('listing', 'lst_6a6c582cf8eefd7e38e261ca', 23623, 'Cold Stone Creamery - Bodija'),
    ('listing', 'lst_6a6c582df8eefd7e38e261ce', 23824, 'Cold Stone Creamery - Challenge'),
    ('listing', 'lst_6a79eb50d10ed5135545ae41', 23826, 'Cold Stone Creamery - Choba'),
    ('listing', 'lst_6a70af4ac5350600171d5b0e', 23643, 'Cold Stone Creamery - Egbeda'),
    ('listing', 'lst_6a70af4ac5350600171d5b14', 23207, 'Cold Stone Creamery - Festac'),
    ('listing', 'lst_6a6c58c7f8eefd7e38e279f6', 24008, 'Cold Stone Creamery - Freedom Way'),
    ('listing', 'lst_6a79eac4d10ed5135545abc0', 23594, 'Cold Stone Creamery - GRA PH (PH-Olusegun Obasanjo)'),
    ('listing', 'lst_6a70af4ac5350600171d5b0f', 23614, 'Cold Stone Creamery - Gateway Mall Lugbe'),
    ('listing', 'lst_6a70af5fd18bae7dc4d1b78b', 23717, 'Cold Stone Creamery - Gbagada'),
    ('listing', 'lst_6a70af5fd18bae7dc4d1b78d', 23361, 'Cold Stone Creamery - Gwarinpa'),
    ('listing', 'lst_6a6c5866f8eefd7e38e26b4f', 23271, 'Cold Stone Creamery - ICM (Ikeja City Mall)'),
    ('listing', 'lst_6a6c582cf8eefd7e38e261cd', 23186, 'Cold Stone Creamery - Ibadan Mall (Palms Mall)'),
    ('listing', 'lst_6a70af5fd18bae7dc4d1b791', 23510, 'Cold Stone Creamery - Idimu'),
    ('listing', 'lst_6a6c5897f8eefd7e38e273ce', 23502, 'Cold Stone Creamery - Ikorodu (TOS Benson; Sawmill has its own listing)'),
    ('listing', 'lst_6a70af5fd18bae7dc4d1b782', 24010, 'Cold Stone Creamery - Ikota'),
    ('listing', 'lst_6a70af5fd18bae7dc4d1b786', 23490, 'Cold Stone Creamery - Ikotun'),
    ('listing', 'lst_6a6c5897f8eefd7e38e273c0', 23591, 'Cold Stone Creamery - Ikoyi'),
    ('listing', 'lst_6a719498d18bae7dc4d7046e', 23509, 'Cold Stone Creamery - Ilupeju'),
    ('listing', 'lst_6a70af5fd18bae7dc4d1b788', 23619, 'Cold Stone Creamery - Itire'),
    ('listing', 'lst_6a6737a116310d1825503232', 23605, 'Cold Stone Creamery - Jabi Mall'),
    ('listing', 'lst_6a70af5fd18bae7dc4d1b780', 23626, 'Cold Stone Creamery - Kubwa'),
    ('listing', 'lst_6a6c5866f8eefd7e38e26b5e', 23648, 'Cold Stone Creamery - Kwara Mall'),
    ('listing', 'lst_6a70b527c5350600171d9059', 23964, 'Cold Stone Creamery - Lasu'),
    ('listing', 'lst_6a6c5897f8eefd7e38e273d6', 23618, 'Cold Stone Creamery - Magodo'),
    ('listing', 'lst_6a70af5ed18bae7dc4d1b77a', 23611, 'Cold Stone Creamery - Maryland'),
    ('listing', 'lst_6a70af5fd18bae7dc4d1b77c', 23147, 'Cold Stone Creamery - OGUNNAIKE'),
    ('listing', 'lst_6a6c5897f8eefd7e38e273d3', 23423, 'Cold Stone Creamery - Ogudu'),
    ('listing', 'lst_6a70af5ed18bae7dc4d1b778', 23512, 'Cold Stone Creamery - Oko Oba'),
    ('listing', 'lst_6a70af79c5350600171d61cb', 23491, 'Cold Stone Creamery - Okota'),
    ('listing', 'lst_6a70af79c5350600171d61cc', 23612, 'Cold Stone Creamery - Ota'),
    ('listing', 'lst_6a6c5897f8eefd7e38e273c6', 23652, 'Cold Stone Creamery - PETER ODILI'),
    ('listing', 'lst_6a6c5897f8eefd7e38e273ca', 23112, 'Cold Stone Creamery - Polo Park Mall'),
    ('listing', 'lst_6a6737a116310d182550322c', 23185, 'Cold Stone Creamery - Ringroad'),
    ('listing', 'lst_6a6c58c7f8eefd7e38e27a03', 23033, 'Cold Stone Creamery - Saka Tinubu'),
    ('listing', 'lst_6a70af79c5350600171d61c6', 23613, 'Cold Stone Creamery - Sangotedo'),
    ('listing', 'lst_6a70af79c5350600171d61c8', 23593, 'Cold Stone Creamery - Satellite'),
    ('listing', 'lst_6a6c5897f8eefd7e38e273d0', 23981, 'Cold Stone Creamery - Sawmill'),
    ('listing', 'lst_6a6c5897f8eefd7e38e273c5', 23650, 'Cold Stone Creamery - Shell'),
    ('listing', 'lst_6a70b526c5350600171d904f', 23146, 'Cold Stone Creamery - Surulere (AOS Mall)'),
    ('listing', 'lst_6a70af79c5350600171d61c0', 23145, 'Cold Stone Creamery - Toyin Street'),
    ('listing', 'lst_6a6c58ecf8eefd7e38e281e9', 23754, 'Cold Stone Creamery - Warri'),
    ('listing', 'lst_6a74a89ee5ce5b6c7bf83af3', 23313, 'Cold Stone Creamery - Wuse'),
    ('listing', 'lst_6a70af79c5350600171d61c2', 23407, 'Cold Stone Creamery - Yaba'),
    ('listing', 'lst_6a6c58c7f8eefd7e38e279fd', 23837, 'Cold Stone Creamery - jakande'),
    ('listing', 'lst_6a6c5897f8eefd7e38e273c9', 23915, 'Cold Stone Creamery - Achike Owerri'),
    -- Chowdeck, Domino's
    ('listing', 'lst_6a6c582cf8eefd7e38e261c4', 51823, 'Domino''s Pizza - Abeokuta (URL: Ibara)'),
    ('listing', 'lst_6a6c582cf8eefd7e38e261c3', 51862, 'Domino''s Pizza - Abiola Way'),
    ('listing', 'lst_6a70b527c5350600171d9060', 51791, 'Domino''s Pizza - Admiralty 1'),
    ('listing', 'lst_6a70b527c5350600171d905e', 51812, 'Domino''s Pizza - Admiralty 2'),
    ('listing', 'lst_6a6c5866f8eefd7e38e26b5a', 51808, 'Domino''s Pizza - Agidingbi'),
    ('listing', 'lst_6a70af79c5350600171d61bc', 51796, 'Domino''s Pizza - Agungi'),
    ('listing', 'lst_6a719498d18bae7dc4d7046f', 51800, 'Domino''s Pizza - Ajao'),
    ('listing', 'lst_6a6c58c7f8eefd7e38e279fa', 51801, 'Domino''s Pizza - Ajose'),
    ('listing', 'lst_6a6c582df8eefd7e38e261da', 51863, 'Domino''s Pizza - Akobo'),
    ('listing', 'lst_6a70af78c5350600171d61ba', 51794, 'Domino''s Pizza - Apapa'),
    ('listing', 'lst_6a70af78c5350600171d61b6', 51832, 'Domino''s Pizza - Apo Mall'),
    ('listing', 'lst_6a6737a116310d182550322b', 51811, 'Domino''s Pizza - Aromire'),
    ('listing', 'lst_6a6c58c7f8eefd7e38e279f1', 51844, 'Domino''s Pizza - Benin Sapele'),
    ('listing', 'lst_6a6c58c7f8eefd7e38e279ea', 51845, 'Domino''s Pizza - Benin Ugbowo'),
    ('listing', 'lst_6a6c59aff8eefd7e38e2825e', 51799, 'Domino''s Pizza - Bode Thomas'),
    ('listing', 'lst_6a6c582cf8eefd7e38e261c9', 51798, 'Domino''s Pizza - Bodija'),
    ('listing', 'lst_6a6c582df8eefd7e38e261d1', 51851, 'Domino''s Pizza - Challenge'),
    ('listing', 'lst_6a70b527c5350600171d905a', 51853, 'Domino''s Pizza - Choba'),
    ('listing', 'lst_6a70af98d18bae7dc4d1c416', 51814, 'Domino''s Pizza - Egbeda'),
    ('listing', 'lst_6a70af78c5350600171d61b4', 51797, 'Domino''s Pizza - Festac'),
    ('listing', 'lst_6a6c58c7f8eefd7e38e279f4', 51870, 'Domino''s Pizza - Freedom Way'),
    ('listing', 'lst_6a74a89ee5ce5b6c7bf83aec', 51827, 'Domino''s Pizza - GRA (PH-Olusegun Obasanjo)'),
    ('listing', 'lst_6a70af97d18bae7dc4d1c405', 51830, 'Domino''s Pizza - Gateway Mall'),
    ('listing', 'lst_6a70af97d18bae7dc4d1c402', 51802, 'Domino''s Pizza - Gbagada'),
    ('listing', 'lst_6a70af97d18bae7dc4d1c40a', 51806, 'Domino''s Pizza - Gwarinpa'),
    ('listing', 'lst_6a70af98d18bae7dc4d1c410', 51818, 'Domino''s Pizza - Idimu'),
    ('listing', 'lst_6a6c5866f8eefd7e38e26b59', 51820, 'Domino''s Pizza - Iju'),
    ('listing', 'lst_6a6c5866f8eefd7e38e26b50', 51817, 'Domino''s Pizza - Ikorodu (URL: Ebute, TOS Benson)'),
    ('listing', 'lst_6a70af97d18bae7dc4d1c3fe', 51810, 'Domino''s Pizza - Ikotun'),
    ('listing', 'lst_6a6737a116310d182550322a', 51826, 'Domino''s Pizza - Ikoyi'),
    ('listing', 'lst_6a719498d18bae7dc4d7046d', 51816, 'Domino''s Pizza - Ilupeju'),
    ('listing', 'lst_6a70af97d18bae7dc4d1c3f9', 51831, 'Domino''s Pizza - Itire'),
    ('listing', 'lst_6a70b526c5350600171d9050', 51829, 'Domino''s Pizza - Jabi'),
    ('listing', 'lst_6a6c58c7f8eefd7e38e27a01', 51824, 'Domino''s Pizza - Jakande'),
    ('listing', 'lst_6a70af97d18bae7dc4d1c3f4', 51834, 'Domino''s Pizza - Kubwa'),
    ('listing', 'lst_6a6c5866f8eefd7e38e26b62', 51836, 'Domino''s Pizza - Kwara Mall'),
    ('listing', 'lst_6a70b527c5350600171d9056', 51864, 'Domino''s Pizza - Lasu'),
    ('listing', 'lst_6a6c5866f8eefd7e38e26b55', 51804, 'Domino''s Pizza - Magodo'),
    ('listing', 'lst_6a719498d18bae7dc4d70475', 51822, 'Domino''s Pizza - Maryland'),
    ('listing', 'lst_6a70af97d18bae7dc4d1c3ed', 51809, 'Domino''s Pizza - Ogudu'),
    ('listing', 'lst_6a70afa7d18bae7dc4d1c8b0', 51793, 'Domino''s Pizza - Ogunnaike'),
    ('listing', 'lst_6a70af97d18bae7dc4d1c3f1', 51819, 'Domino''s Pizza - Oko Oba'),
    ('listing', 'lst_6a70afa7d18bae7dc4d1c8a8', 51813, 'Domino''s Pizza - Okota'),
    ('listing', 'lst_6a70afa7d18bae7dc4d1c8ab', 51825, 'Domino''s Pizza - Ota'),
    ('listing', 'lst_6a6c582df8eefd7e38e261d3', 51795, 'Domino''s Pizza - Ring Road'),
    ('listing', 'lst_6a6c5897f8eefd7e38e273bf', 51790, 'Domino''s Pizza - Saka Tinubu'),
    ('listing', 'lst_6a70afa7d18bae7dc4d1c89f', 51815, 'Domino''s Pizza - Sangotedo'),
    ('listing', 'lst_6a70afa7d18bae7dc4d1c8a2', 51828, 'Domino''s Pizza - Satellite'),
    ('listing', 'lst_6a74a89ee5ce5b6c7bf83aea', 51838, 'Domino''s Pizza - Shell'),
    ('listing', 'lst_6a6c58ecf8eefd7e38e281e8', 51849, 'Domino''s Pizza - Warri'),
    ('listing', 'lst_6a74a89ee5ce5b6c7bf83b17', 51803, 'Domino''s Pizza - Wuse'),
    ('listing', 'lst_6a70afa7d18bae7dc4d1c899', 51807, 'Domino''s Pizza - Yaba'),
    ('listing', 'lst_6a74a89ee5ce5b6c7bf83af0', 51858, 'Domino''s Pizza - New Owerri'),
    ('listing', 'lst_6a79e634d10ed513554593de', 51833, 'Domino''s Pizza - Polo park'),
    -- Chowdeck, Pinkberry
    ('listing', 'lst_6a74a89ee5ce5b6c7bf83ae6', 9001,  'Pinkberry - Admiralty 2'),
    ('listing', 'lst_6a74a8bce5ce5b6c7bf83f1c', 269,   'Pinkberry - Agidingbi'),
    ('listing', 'lst_6a70afa7d18bae7dc4d1c890', 6232,  'Pinkberry - Ajose'),
    ('listing', 'lst_6a70afa7d18bae7dc4d1c896', 9002,  'Pinkberry - Aromire'),
    ('listing', 'lst_6a70afa7d18bae7dc4d1c88c', 270,   'Pinkberry - Bode Thomas'),
    ('listing', 'lst_6a79ea4cd10ed5135545aa9c', 6239,  'Pinkberry - GRA (check: assumed PH-Olusegun Obasanjo)'),
    ('listing', 'lst_6a70afb6d18bae7dc4d1ccd5', 6242,  'Pinkberry - Gateway mall'),
    ('listing', 'lst_6a70afb6d18bae7dc4d1cccf', 6233,  'Pinkberry - Ikoyi'),
    ('listing', 'lst_6a74a89ee5ce5b6c7bf83ae9', 271,   'Pinkberry - Ilupeju'),
    ('listing', 'lst_6a70afb6d18bae7dc4d1cccd', 6243,  'Pinkberry - Jabi Lake mall'),
    ('listing', 'lst_6a74a89de5ce5b6c7bf83ae3', 6231,  'Pinkberry - Jakande'),
    ('listing', 'lst_6a79e545d10ed5135545934e', 93,    'Pinkberry - Peter Odili'),
    ('listing', 'lst_6a79e9c9d10ed5135545a8bf', 6245,  'Pinkberry - Polo Park Mall'),
    ('listing', 'lst_6a70afb6d18bae7dc4d1cccb', 266,   'Pinkberry - Yaba'),
    -- Chowdeck, other names
    ('listing', 'lst_6a6c5866f8eefd7e38e26b56', 51839, 'Pizza Jungle - Simbiat Mall (= DP Jara Mall)'),
    -- Google listings with no Harlyy location
    ('listing', 'lst_6a7a67e4d10ed51355467dc2', 24007, 'Google: Cold Stone Creamery - Lagos - Awoyaya'),
    ('listing', 'lst_69b0270e8ee5963122c0ad40', 23362, 'Google: Cold Stone Creamery - Lagos - Chevron'),
    ('listing', 'lst_6a7521f9e5ce5b6c7bfa9480', 23900, 'Google: Cold Stone Creamery - Ibadan - Akobo.'),
    ('listing', 'lst_69e3621c4350e23f615e953c', 23647, 'Google: Cold Stone Creamery - Mega Mall (KE)'),
    ('listing', 'lst_69b0271f8ee5963122c0b67d', 51836, 'Google: Domino''s Pizza - Ilorin - Kwara Mall'),
    ('listing', 'lst_69b0271d8ee5963122c0b5ab', 51827, 'Google: Domino''s Pizza - Port Harcourt - PH-Olusegun Obasanjo'),
    ('listing', 'lst_6a727ede7df4a367e01dbee1', 57341, 'Google: Domino''s Pizza - Trafford Park (KE)'),
    ('listing', 'lst_69b0271b8ee5963122c0b4c3', 51848, 'Google: Domino''s Pizza - Kano - Zoo Road (= Bompai Road, confirmed by operations)'),
    ('listing', 'lst_6a6d38d93f335d55604c4bec', 24583, 'Google: Cold Stone Creamery - Rubis Waiyaki Way (KE, = Rubis Kianda, confirmed by operations)'),
    ('listing', 'lst_69b027368ee5963122c0c057', NULL,  'Google: Cold Stone / Dominos Pizza (check: which store?)');
COMMIT;


-- Other names customers use for a store, for reading the store out of online/delivery
-- survey comments (05_alert_feed.sql). Master store names and 5-digit store numbers are
-- matched as they are; list only extra names here. A comment is used only if it names
-- exactly one store.
CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.store_aliases (
    brand        VARCHAR(16)  NOT NULL,    -- master brand code: DP, CSC, PB, PP
    alias        VARCHAR(128) NOT NULL,    -- words as a customer would write them
    store_number INTEGER      NOT NULL
);

BEGIN;
DELETE FROM harlyy_feedback_analytics.store_aliases;
INSERT INTO harlyy_feedback_analytics.store_aliases (brand, alias, store_number) VALUES
    ('DP',  'Abule Egba',     51819),   -- Oko Oba
    ('CSC', 'Abule Egba',     23512),
    ('DP',  'Lekki Phase 1',  51870),   -- Freedom Way
    ('CSC', 'Lekki Phase 1',  24008),
    ('DP',  'Ilasamaja',      51813),   -- Okota
    ('CSC', 'Ilasamaja',      23491),
    ('DP',  'Simbiat Mall',   51839),   -- Jara Mall
    ('CSC', 'ICM',            23271),   -- Ikeja City Mall
    ('DP',  'Sawmill',        51865),
    ('CSC', 'Sawmill',        23981),
    ('DP',  'Saka Tinubu',    51790),
    ('CSC', 'Saka Tinubu',    23033),
    ('DP',  'Bodethomas',     51799),
    ('CSC', 'Bodethomas',     23898),
    ('DP',  'Sangotoedo',     51815),   -- common misspelling of Sangotedo
    ('CSC', 'Sangotoedo',     23613),
    ('DP',  'Ologolo',        51824),   -- Jakande (confirmed by operations)
    ('CSC', 'Ologolo',        23837),
    ('PB',  'Ologolo',        6231),
    ('PB',  'Wuse',           264),     -- Wuse II
    ('PB',  'Ikorodu',        273);     -- PB's only Ikorodu store (TOS Benson)
COMMIT;


-- Region for review listings whose store is not in the store master (closed, new, or
-- not ours to number), so vw_review_actions can still group them. Use the same region
-- names as Harlyy / regional_bu. A listing that gets a store later no longer needs a row.
CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.listing_regions (
    listing_id VARCHAR(128) NOT NULL,
    region     VARCHAR(512) NOT NULL,
    note       VARCHAR(256)
);

BEGIN;
DELETE FROM harlyy_feedback_analytics.listing_regions;
INSERT INTO harlyy_feedback_analytics.listing_regions (listing_id, region, note) VALUES
    ('lst_69b0270d8ee5963122c0acaf', 'Island',  'Google: Cold Stone Creamery The Palms Lekki (Lekki, Lagos; confirmed by operations)'),
    ('lst_69b027178ee5963122c0b2ef', 'Mainland', 'Google: Domino''s Pizza Aggrey Road (near Yaba, Lagos; confirmed by operations)'),
    ('lst_6aac8089a1c2cf26a9718cc0', 'Nairobi', 'Google: Cold Stone Creamery- Shell Umoja (KE; check: which store?)');
COMMIT;


-- vw_store_map: one row per Harlyy location and per mapped review listing (manual link
-- in store_map_overrides, else matched by name).
-- Join on map_key: 'location:<location_id>' or 'listing:<listing_id>'.
CREATE OR REPLACE VIEW harlyy_feedback_analytics.vw_store_map AS
WITH master AS (
    SELECT store_number,
           UPPER(TRIM(brand)) || ' ' || UPPER(TRIM(REGEXP_REPLACE(store_name, '[[:space:]]+', ' '))) AS match_key,
           country
    FROM public.pulse_store_master_map
),
-- Review listings with no manual link are matched by name: the master store name (or a
-- store_aliases name) found inside the listing name, same brand and country, letters
-- and digits only ("…Kano - Awka - Awka" -> DP AWKA). The longest name wins, so
-- "Ikota" is not read as "Ota". Listings naming no master store stay unlinked.
name_candidates AS (
    SELECT UPPER(TRIM(brand)) AS brand, country, store_number,
           REGEXP_REPLACE(UPPER(store_name), '[^A-Z0-9]', '') AS name_key
    FROM public.pulse_store_master_map
    UNION ALL
    SELECT UPPER(TRIM(a.brand)), p.country, a.store_number,
           REGEXP_REPLACE(UPPER(a.alias), '[^A-Z0-9]', '')
    FROM harlyy_feedback_analytics.store_aliases a
    JOIN public.pulse_store_master_map p ON p.store_number = a.store_number
),
listing_names AS (
    SELECT r.listing_id,
           MAX(r.listing_name)                                          AS listing_name,
           MAX(r.country_code)                                          AS country_code,
           REGEXP_REPLACE(UPPER(MAX(r.listing_name)), '[^A-Z0-9]', '')  AS name_key,
           CASE WHEN UPPER(MAX(r.listing_name)) LIKE 'DOMINO%'       THEN 'DP'
                WHEN UPPER(MAX(r.listing_name)) LIKE 'COLD%STONE%'   THEN 'CSC'
                WHEN UPPER(MAX(r.listing_name)) LIKE 'PINKBERRY%'    THEN 'PB'
                WHEN UPPER(MAX(r.listing_name)) LIKE 'PASTRY PLANET%' THEN 'PP' END AS brand
    FROM harlyy_feedback_analytics.reviews r
    WHERE r.listing_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM harlyy_feedback_analytics.store_map_overrides o
                      WHERE o.id_type = 'listing' AND o.harlyy_id = r.listing_id)
    GROUP BY r.listing_id
),
mapped AS (
    SELECT 'location'                                                   AS id_type,
           l.location_id                                                AS harlyy_id,
           CAST(l.location_name AS VARCHAR(512))                        AS harlyy_name,
           CASE WHEN o.harlyy_id IS NOT NULL THEN o.store_number ELSE m.store_number END AS store_number,
           CASE WHEN o.harlyy_id IS NOT NULL THEN 'manual'
                WHEN m.store_number IS NOT NULL THEN 'name match'
                ELSE 'unmatched' END                                    AS match_method,
           o.note
    FROM harlyy_feedback_analytics.locations l
    LEFT JOIN harlyy_feedback_analytics.store_map_overrides o
           ON o.id_type = 'location' AND o.harlyy_id = l.location_id
    LEFT JOIN master m      -- "Pastry Planet Ikoyi" in Harlyy also matches master "PP IKOYI"
           ON m.match_key = REGEXP_REPLACE(UPPER(TRIM(REGEXP_REPLACE(l.location_name, '[[:space:]]+', ' '))),
                                           '^PASTRY PLANET[ -]+', 'PP ')
          AND m.country = l.country_code
    UNION ALL
    SELECT 'listing', o.harlyy_id, CAST(o.note AS VARCHAR(512)), o.store_number, 'manual', o.note
    FROM harlyy_feedback_analytics.store_map_overrides o
    WHERE o.id_type = 'listing'
    UNION ALL
    SELECT 'listing', x.listing_id, CAST(x.listing_name AS VARCHAR(512)), x.store_number,
           'name match', CAST(NULL AS VARCHAR(256))
    FROM (
        SELECT l.listing_id, l.listing_name, c.store_number,
               ROW_NUMBER() OVER (PARTITION BY l.listing_id
                                  ORDER BY LEN(c.name_key) DESC, c.store_number) AS rn
        FROM listing_names l
        JOIN name_candidates c
          ON c.brand = l.brand
         AND (l.country_code IS NULL OR c.country = l.country_code)
         AND POSITION(c.name_key IN l.name_key) > 0
    ) x
    WHERE x.rn = 1
)
SELECT x.id_type || ':' || x.harlyy_id AS map_key,
       x.id_type,
       x.harlyy_id,
       x.harlyy_name,
       x.match_method,
       x.store_number,
       p.brand                          AS store_brand,
       p.store_name                     AS master_store_name,
       p.country                        AS store_country,
       p.area,
       p.regional_bu,
       x.note
FROM mapped x
LEFT JOIN public.pulse_store_master_map p ON p.store_number = x.store_number
WITH NO SCHEMA BINDING;


-- ---------------------------------------------------------------------------------
-- Checks (run any time; all should return nothing unless stated)
-- ---------------------------------------------------------------------------------

-- 1. Harlyy locations with no store yet.
-- SELECT harlyy_id, harlyy_name FROM harlyy_feedback_analytics.vw_store_map
-- WHERE match_method = 'unmatched' ORDER BY harlyy_name;

-- 2. A location linked to two stores (master has duplicate names or store numbers).
-- SELECT map_key, COUNT(*) FROM harlyy_feedback_analytics.vw_store_map
-- GROUP BY map_key HAVING COUNT(*) > 1;

-- 3. Harlyy's regional manager differs from the one most stores in the same master
--    area have: usually a label to fix in Harlyy.
-- WITH x AS (
--     SELECT sm.area, l.region, l.regional_manager, l.location_name
--     FROM harlyy_feedback_analytics.vw_store_map sm
--     JOIN harlyy_feedback_analytics.locations l ON sm.map_key = 'location:' || l.location_id
--     WHERE sm.area IS NOT NULL AND l.regional_manager IS NOT NULL
-- ),
-- usual AS (
--     SELECT area, regional_manager,
--            ROW_NUMBER() OVER (PARTITION BY area ORDER BY COUNT(*) DESC) AS rn
--     FROM x GROUP BY area, regional_manager
-- )
-- SELECT x.location_name, x.area, x.region, x.regional_manager, u.regional_manager AS usual_for_area
-- FROM x JOIN usual u ON u.area = x.area AND u.rn = 1
-- WHERE x.regional_manager <> u.regional_manager
-- ORDER BY x.area, x.location_name;

-- 4. Review listings (any platform) with no location and no link yet: add each as
--    ('listing', '<listing_id>', <store_number>, '<listing_name>') above and re-run.
-- SELECT r.source, r.listing_id, r.listing_name, r.brand, r.country_code,
--        COUNT(*) AS reviews, MAX(r.review_created_at) AS last_review
-- FROM harlyy_feedback_analytics.reviews r
-- LEFT JOIN harlyy_feedback_analytics.vw_store_map sm ON sm.map_key = 'listing:' || r.listing_id
-- WHERE r.location_id IS NULL AND sm.map_key IS NULL
-- GROUP BY 1, 2, 3, 4, 5
-- ORDER BY r.source, r.brand, r.listing_name;
