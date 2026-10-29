"""Synthetic saved ChatGPT logins. Never reads an installed login."""
import base64
from datetime import datetime, timezone
import json
import time


CLOCK = int(time.time())
CLAIM = "https://api.openai.com/auth"


def encoded(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")


def bundle(generation=0, *, user_id="fixture-user", workspace_id="fixture-workspace"):
    claims = {"exp": CLOCK + 86400, "iat": CLOCK + generation,
              CLAIM: {"chatgpt_user_id": user_id}}
    return {"auth_mode": "chatgpt", "OPENAI_API_KEY": None,
            "tokens": {"id_token": encoded({"alg": "none"}) + "." + encoded(claims) + ".synthetic",
                       "access_token": "synthetic-access-" + str(generation),
                       "refresh_token": "synthetic-refresh-" + str(generation),
                       "account_id": workspace_id},
            "last_refresh": datetime.fromtimestamp(CLOCK + generation, timezone.utc)
                .isoformat().replace("+00:00", "Z")}
