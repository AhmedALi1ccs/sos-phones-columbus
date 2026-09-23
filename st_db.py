"""Connection sidebar shared by the uploader pages."""

import os

import streamlit as st


def secret(name, default=""):
    """.streamlit/secrets.toml first, then the environment, then the default."""
    try:
        if name in st.secrets:
            return str(st.secrets[name])
    except Exception:                                      # no secrets file at all
        pass
    return os.environ.get(name, default)


def sidebar_connection():
    """Draw the connection controls and return psycopg2 keyword arguments."""
    with st.sidebar:
        st.subheader("Database")
        params = {
            "host": st.text_input("Host", secret("PGHOST", "aws-1-us-east-2.pooler.supabase.com")),
            "port": int(st.text_input("Port", secret("PGPORT", "5432")) or 5432),
            "dbname": st.text_input("Database", secret("PGDATABASE", "postgres")),
            "user": st.text_input("User", secret("PGUSER", "postgres.hoahkpeblfxjbkhwbdxs")),
            "password": st.text_input("Password", secret("PGPASSWORD", ""), type="password"),
            "connect_timeout": 15,
        }
        st.caption("✅ Credentials loaded." if params["password"] else
                   "Set `PGPASSWORD` in `.streamlit/secrets.toml` (git-ignored) or type it above.")

        if st.button("Test connection", width="stretch"):
            try:
                import psycopg2
                with psycopg2.connect(**params) as c, c.cursor() as cur:
                    cur.execute('select count(*) from public."BuyBox"')
                    st.success(f"Connected — {cur.fetchone()[0]:,} BuyBox records")
            except Exception as exc:                       # noqa: BLE001
                st.error(f"{exc}")
    return params


def read_upload(upload):
    """Read a CSV/XLSX upload into an all-text dataframe, or stop with an error."""
    import pandas as pd
    try:
        if upload.name.lower().endswith(".csv"):
            df = pd.read_csv(upload, dtype=str, keep_default_na=False)
        else:
            df = pd.read_excel(upload, dtype=str).fillna("")
    except Exception as exc:                               # noqa: BLE001
        st.error(f"Could not read that file: {exc}")
        st.stop()
    df.columns = [str(c).strip() for c in df.columns]
    return df


def guess(cols, *wanted):
    """Find a column by any of several spellings, ignoring case and separators."""
    norm = {c.lower().replace(" ", "").replace("_", ""): c for c in cols}
    for w in wanted:
        hit = norm.get(w.lower().replace(" ", "").replace("_", ""))
        if hit:
            return hit
    return None
