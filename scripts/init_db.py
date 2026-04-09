"""One-shot DB initializer. Runs schema.sql against the configured database."""
import pathlib
import psycopg2
from dotenv import load_dotenv
import os

load_dotenv()

SCHEMA = pathlib.Path(__file__).parent.parent / "schema.sql"


def main() -> None:
    conn = psycopg2.connect(
        host=os.environ["POSTGRES_HOST"],
        port=os.environ["POSTGRES_PORT"],
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    )
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(SCHEMA.read_text())
    conn.close()
    print("Schema applied.")


if __name__ == "__main__":
    main()
