from __future__ import annotations

import time
from pathlib import Path

import httpx

_RETRY_DELAYS = (5, 15, 45)  # seconds between attempts 1→2, 2→3, 3→fail


def _bank_code_from_filename(name: str) -> str | None:
    """Last-resort fallback: infer bank code from the scraper filename prefix.

    Only used when no authoritative bank_map entry exists (e.g. the standalone
    ``upload`` CLI command pointing at arbitrary files).
    """
    candidate = name.split("_")[0].upper()
    if 2 <= len(candidate) <= 16 and candidate.isalpha():
        return candidate
    return None


class ScraperClient:
    def __init__(self, base_url: str, api_token: str, profile_key: str) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_token = api_token
        self._profile_key = profile_key

    def upload_pdfs(self, files: list[Path], bank_code: str | None = None) -> dict:
        """Upload *files* to the backend.

        Parameters
        ----------
        files:
            PDF files to upload.
        bank_code:
            Authoritative bank code known at download time (from BankMap).
            When provided all files in the batch are tagged with it and the
            backend skips PDF content detection entirely.  When *None* the
            backend falls back to content detection (used by the standalone
            ``upload`` command where the bank is unknown).
        """
        if not files:
            raise ValueError("No files to upload")
        if not self._api_token:
            raise RuntimeError("CCS_SCRAPER_API_TOKEN is not set")

        url = f"{self._base_url}/api/v1/jobs/upload"
        headers = {
            "Authorization": f"Bearer {self._api_token}",
            "X-Profile-Key": self._profile_key,
        }

        # Use caller-supplied code; fall back to filename prefix as last resort.
        hint = bank_code or _bank_code_from_filename(files[0].name) if files else None
        data = {"bank_code_hint": hint} if hint else {}

        last_exc: Exception = RuntimeError("Upload failed")
        for attempt, delay in enumerate((*_RETRY_DELAYS, None), start=1):
            multipart: list[tuple] = []
            handles = []
            try:
                for path in files:
                    fh = open(path, "rb")  # noqa: WPS515
                    handles.append(fh)
                    multipart.append(("files", (path.name, fh, "application/pdf")))

                with httpx.Client(timeout=120) as client:
                    response = client.post(url, headers=headers, files=multipart, data=data)

                if response.is_success:
                    return response.json()

                try:
                    body = response.json()
                except Exception:
                    body = response.text

                # 4xx errors are not transient — don't retry
                if 400 <= response.status_code < 500:
                    raise RuntimeError(f"Upload failed {response.status_code}: {body}")

                last_exc = RuntimeError(f"Upload failed {response.status_code}: {body}")
            except RuntimeError:
                raise
            except Exception as exc:
                last_exc = exc
            finally:
                for fh in handles:
                    fh.close()

            if delay is not None:
                print(f"Upload attempt {attempt} failed, retrying in {delay}s …")
                time.sleep(delay)

        raise last_exc
