DECLARE current_identifier STRING;
DECLARE dynamic_view_sql STRING;

-- Loop through every unique table_identifier in your staging table
FOR record IN (
  SELECT DISTINCT table_identifier 
  FROM `sjolbli-myi-nlpf.Twin_Projection.Master_stage`
  WHERE table_identifier IS NOT NULL
) 
DO
  SET current_identifier = record.table_identifier;

  -- 1. Construct the complete 'CREATE VIEW' SQL statement directly
  SET dynamic_view_sql = FORMAT("""
    CREATE OR REPLACE VIEW `sjolbli-myi-nlpf.Twin_Projection.view_%s` AS
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
      -- Leaves attributes unflattened but ready for on-demand JSON queries
      attributes
    FROM `sjolbli-myi-nlpf.Twin_Projection.Master_stage`
    WHERE table_identifier = '%s'
    -- Keeps only the latest state of each unique record ID on-the-fly
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY id 
      ORDER BY updatedAt DESC, published_at DESC
    ) = 1;
  """, current_identifier, current_identifier);

  -- 2. Physically execute the query to build/update the view
  EXECUTE IMMEDIATE dynamic_view_sql;

END FOR;
