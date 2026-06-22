DECLARE current_identifier STRING;
DECLARE json_paths ARRAY<STRING>;
DECLARE dynamic_view_sql STRING;
DECLARE safe_json_path STRING;

-- Loop through every unique table_identifier currently found in your master table
FOR record IN (
  SELECT DISTINCT table_identifier 
  FROM `sjolbli-myi-nlpf.Twin_Projection.Master_stg`
  WHERE table_identifier IS NOT NULL
) 
DO
  SET current_identifier = record.table_identifier;

  -- 1. Scan distinct keys and cleanly drop parent containers via strict hash matching
  EXECUTE IMMEDIATE FORMAT("""
    WITH raw_sample AS (
      SELECT DISTINCT key_path
      FROM `sjolbli-myi-nlpf.Twin_Projection.Master_stg`,
      UNNEST(JSON_KEYS(payload, 99, mode => 'lax recursive')) AS key_path
      WHERE table_identifier = '%s'
        AND payload IS NOT NULL
      LIMIT 10
    ),
    parent_paths AS (
      -- Extract parent namespaces by stripping the last nested node component
      -- e.g., 'metadata.createdAt' creates a parent signature entry for 'metadata'
      SELECT DISTINCT 
        REGEXP_REPLACE(key_path, r'\\.[^.]+$', '') AS parent_name
      FROM raw_sample
      WHERE CONTAINS_SUBSTR(key_path, '.')
    )
    SELECT ARRAY_AGG(key_path)
    FROM raw_sample
    -- Drops structural headers (like 'metadata' or 'identifiers') if they appear in the parent map.
    WHERE key_path NOT IN (SELECT parent_name FROM parent_paths)
    """, current_identifier) INTO json_paths;

  -- Guard rail: If no records or keys exist for this identifier, skip to avoid breaking the script
  IF ARRAY_LENGTH(json_paths) IS NULL OR ARRAY_LENGTH(json_paths) = 0 THEN
    CONTINUE;
  END IF;

  -- 2. Initialize the dynamic 'CREATE VIEW' SQL statement string
  SET dynamic_view_sql = FORMAT("""
    CREATE OR REPLACE VIEW `sjolbli-myi-nlpf.Twin_Projection.view_%s` AS
    SELECT 
      created_at AS record_ingested_at,\n""", current_identifier);

  -- 3. Loop through all paths and build a safe flattened view selection block
  FOR path_record IN (SELECT * FROM UNNEST(json_paths) AS path_name)
  DO
    -- Prepend '$.' directly onto the raw key name (e.g. 'metadata.createdAt' becomes '$.metadata.createdAt')
    SET safe_json_path = CONCAT('$.', path_record.path_name);

    -- Wrap the path query block safely using escaped single quotes inside the template string.
    SET dynamic_view_sql = dynamic_view_sql 
      || '  JSON_VALUE(payload, \'' || safe_json_path || '\') AS `' 
      || REGEXP_REPLACE(path_record.path_name, r'[^a-zA-Z0-9_]', '_') 
      || '`,\n';
  END FOR;

  -- 4. Clean up trailing commas and close out the query text
  SET dynamic_view_sql = REGEXP_REPLACE(dynamic_view_sql, ',\n$', '\n');
  SET dynamic_view_sql = dynamic_view_sql || FORMAT("""
    FROM `sjolbli-myi-nlpf.Twin_Projection.Master_stg`
    WHERE table_identifier = '%s';\n""", current_identifier);

  -- 5. Physically execute the query to build/update the view
  EXECUTE IMMEDIATE dynamic_view_sql;

END FOR;
