#!/usr/bin/env bash
# Launch the phone-number uploader.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .streamlit/secrets.toml ]; then
  echo "Missing .streamlit/secrets.toml — copy .streamlit/secrets.toml.example and fill in the password." >&2
  exit 1
fi

exec python3 -m streamlit run streamlit_app.py --browser.gatherUsageStats false "$@"
