DECLARE current_identifier STRING;
DECLARE json_paths ARRAY<STRING>;
DECLARE dynamic_view_sql STRING;

-- Loop through every unique table_identifier in your staging table
FOR record IN (
  SELECT DISTINCT table_identifier 
  FROM `sjolbli-myi-nlpf.Twin_Projection.Master_stage`
  WHERE table_identifier IS NOT NULL
) 
DO
  SET current_identifier = record.table_identifier;

  EXECUTE IMMEDIATE FORMAT("""
    WITH raw_paths AS (
      SELECT DISTINCT path
      FROM `sjolbli-myi-nlpf.Twin_Projection.Master_stage`,
      UNNEST(JSON_KEYS(attributes, mode => 'lax recursive')) AS path
      WHERE table_identifier = '%s'
        AND attributes IS NOT NULL
      LIMIT 500
    )
    SELECT ARRAY_AGG(p.path)
    FROM raw_paths p
    -- A clean, flat LEFT JOIN instead of a correlated subquery
    LEFT JOIN raw_paths sub
      ON sub.path != p.path 
      -- Safe cross-field pattern matching that works perfectly on standard JOIN blocks
      AND STARTS_WITH(sub.path, CONCAT(p.path, '.'))
    -- Keeps only rows where NO deeper/longer sub-path was found
    WHERE sub.path IS NULL
  """, current_identifier) INTO json_paths;

  -- 2. Construct the base 'CREATE VIEW' statement
  SET dynamic_view_sql = FORMAT("""
    CREATE OR REPLACE VIEW `sjolbli-myi-nlpf.Twin_Projection.view_flat_%s` AS
    SELECT 
      table_identifier,
      operation,
      shortCode,
      id,
      twinType,
      twinInstanceVersion,
      createdAt,
      createdBy,
      updatedAt,
      updatedBy,
      twinClassVersion,
      published_at,
  """, current_identifier);

  -- 3. Dynamically map individual leaf paths to safe flat columns using JSON subscript syntax
  IF json_paths IS NOT NULL THEN
    FOR path_record IN (SELECT * FROM UNNEST(json_paths) AS path_name)
    DO
      SET dynamic_view_sql = dynamic_view_sql || FORMAT(
        "  LAX_STRING(attributes.%s) AS `%s`,\n", 
        path_record.path_name, REGEXP_REPLACE(path_record.path_name, r'[^a-zA-Z0-9_]', '_')
      );
    END FOR;
  END IF;

  -- 4. Strip trailing commas and close out query with deduplication rules
  SET dynamic_view_sql = REGEXP_REPLACE(dynamic_view_sql, ',\n$', '\n');
  SET dynamic_view_sql = dynamic_view_sql || FORMAT("""
    FROM `sjolbli-myi-nlpf.Twin_Projection.Master_stage`
    WHERE table_identifier = '%s'
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY id 
      ORDER BY updatedAt DESC, published_at DESC
    ) = 1;
  """, current_identifier);

  -- 5. Physically execute the query to build/update the view
  EXECUTE IMMEDIATE dynamic_view_sql;

END FOR;
