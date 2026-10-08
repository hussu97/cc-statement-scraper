from __future__ import annotations

import logging
import time
from collections import Counter
from pathlib import Path
from typing import Any, Callable

import httpx

from scraper.config import DEFAULT_UPLOAD_PATH

logger = logging.getLogger("ccs_scraper.client")

_RETRY_DELAYS = (5, 15, 45)  # seconds between attempts 1→2, 2→3, 3→fail


def build_upload_url(base_url: str, upload_path: str = DEFAULT_UPLOAD_PATH) -> str:
    """Join the target base URL and the upload path with exactly one slash."""
    path = (upload_path or DEFAULT_UPLOAD_PATH).strip()
    return f"{base_url.rstrip('/')}/{path.lstrip('/')}"


def parse_upload_response(body: Any) -> list[dict]:
    """Return the per-file ``uploads`` entries from an upload response body.

    The Ledger v2 Edge Function returns
    ``{"uploads": [{"filename", "doc_code", "status"}]}``.  The legacy backend
    returns a job payload without ``uploads``; in that case an empty list is
    returned.
    """
    if not isinstance(body, dict):
        return []
    uploads = body.get("uploads")
    if not isinstance(uploads, list):
        return []
    return [u for u in uploads if isinstance(u, dict)]


def summarize_uploads(uploads: list[dict]) -> dict[str, int]:
    """Count uploads by status (e.g. ``{"queued": 2, "duplicate": 1}``)."""
    return dict(Counter(str(u.get("status") or "unknown") for u in uploads))


class ScraperClient:
    def __init__(
        self,
        base_url: str,
        api_token: str,
        profile_key: str,
        upload_path: str = DEFAULT_UPLOAD_PATH,
        anon_key: str | None = None,
        *,
        transport: httpx.BaseTransport | None = None,
        retry_delays: tuple[float, ...] = _RETRY_DELAYS,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_token = api_token
        self._profile_key = profile_key
        self._upload_path = upload_path
        self._anon_key = anon_key or None
        self._transport = transport
        self._retry_delays = retry_delays
        self._sleep = sleep

    @property
    def upload_url(self) -> str:
        return build_upload_url(self._base_url, self._upload_path)

    def _headers(self) -> dict[str, str]:
        headers = {
            "Authorization": f"Bearer {self._api_token}",
            "X-Profile-Key": self._profile_key,
        }
        if self._anon_key:
            headers["apikey"] = self._anon_key
        return headers

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

        Returns the parsed JSON response body (``{"raw": text}`` if the body is
        not a JSON object).  4xx responses raise immediately; 5xx responses and
        network errors are retried with backoff before raising.
        """
        if not files:
            raise ValueError("No files to upload")
        if not self._api_token:
            raise RuntimeError("CCS_SCRAPER_API_TOKEN is not set")

        url = self.upload_url
        headers = self._headers()
        hint = bank_code or None
        data = {"bank_code_hint": hint} if hint else {}
        # Read once so every retry sends identical bytes without reopening files.
        payload = [(path.name, path.read_bytes()) for path in files]

        last_exc: Exception = RuntimeError("Upload failed")
        with httpx.Client(timeout=120, transport=self._transport) as client:
            for attempt, delay in enumerate((*self._retry_delays, None), start=1):
                multipart = [("files", (name, content, "application/pdf")) for name, content in payload]
                try:
                    response = client.post(url, headers=headers, files=multipart, data=data)
                except httpx.HTTPError as exc:
                    last_exc = exc
                else:
                    if response.is_success:
                        body = self._json_or_text(response)
                        result = body if isinstance(body, dict) else {"raw": body}
                        self._log_result(result, bank_code)
                        return result

                    body = self._json_or_text(response)
                    # 4xx errors are not transient — don't retry
                    if 400 <= response.status_code < 500:
                        raise RuntimeError(f"Upload failed {response.status_code}: {body}")
                    last_exc = RuntimeError(f"Upload failed {response.status_code}: {body}")

                if delay is not None:
                    logger.warning("Upload attempt %d failed (%s), retrying in %ss …", attempt, last_exc, delay)
                    self._sleep(delay)

        raise last_exc

    @staticmethod
    def _json_or_text(response: httpx.Response) -> Any:
        try:
            return response.json()
        except Exception:  # noqa: BLE001 — non-JSON body
            return response.text

    @staticmethod
    def _log_result(result: dict, bank_code: str | None) -> None:
        uploads = parse_upload_response(result)
        label = bank_code or "(unknown)"
        if not uploads:
            logger.info("Upload accepted for bank %s: %s", label, result)
            return
        for item in uploads:
            logger.info(
                "  %s -> %s (doc_code=%s)",
                item.get("filename"),
                item.get("status"),
                item.get("doc_code"),
            )
        counts = summarize_uploads(uploads)
        logger.info(
            "Upload result for bank %s: queued=%d duplicate=%d other=%d",
            label,
            counts.get("queued", 0),
            counts.get("duplicate", 0),
            sum(v for k, v in counts.items() if k not in {"queued", "duplicate"}),
        )
