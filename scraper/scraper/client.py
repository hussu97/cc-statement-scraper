from __future__ import annotations

from pathlib import Path

import httpx


class ScraperClient:
    def __init__(self, base_url: str, api_token: str, profile_key: str) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_token = api_token
        self._profile_key = profile_key

    def upload_pdfs(self, files: list[Path]) -> dict:
        if not files:
            raise ValueError("No files to upload")
        if not self._api_token:
            raise RuntimeError("CCS_SCRAPER_API_TOKEN is not set")

        url = f"{self._base_url}/api/v1/jobs/upload"
        headers = {
            "Authorization": f"Bearer {self._api_token}",
            "X-Profile-Key": self._profile_key,
        }

        multipart: list[tuple] = []
        handles = []
        try:
            for path in files:
                fh = open(path, "rb")  # noqa: WPS515
                handles.append(fh)
                multipart.append(("files", (path.name, fh, "application/pdf")))

            with httpx.Client(timeout=120) as client:
                response = client.post(url, headers=headers, files=multipart)

            response.raise_for_status()
            return response.json()
        finally:
            for fh in handles:
                fh.close()
