DROP TABLE IF EXISTS test_items;
DROP TABLE IF EXISTS authors;
DROP TABLE IF EXISTS companies;

CREATE TABLE companies (
  id SERIAL PRIMARY KEY,
  company_name VARCHAR(255)
);

CREATE TABLE authors (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255),
  email VARCHAR(255),
  company_id INTEGER REFERENCES companies(id)
);

CREATE TABLE test_items (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255),
  age INTEGER,
  score DOUBLE PRECISION,
  active BOOLEAN,
  tags TEXT[],
  body TEXT,
  role VARCHAR(255),
  status VARCHAR(255),
  metadata JSONB,
  created_at TIMESTAMP WITH TIME ZONE,
  author_id INTEGER REFERENCES authors(id)
);
