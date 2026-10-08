from __future__ import annotations

import logging
import time
from collections import Counter
from pathlib import Path
from typing import Any, Callable

import httpx

from scraper.config import DEFAULT_UPLOAD_PATH, upload_max_bytes, upload_max_files

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


def chunk_payload(
    payload: list[tuple[str, bytes]], max_files: int, max_bytes: int
) -> list[list[tuple[str, bytes]]]:
    """Split files into request batches of at most ``max_files`` files and ``max_bytes``
    bytes (a single file bigger than ``max_bytes`` goes alone; the server judges it)."""
    batches: list[list[tuple[str, bytes]]] = []
    current: list[tuple[str, bytes]] = []
    size = 0
    for item in payload:
        n = len(item[1])
        if current and (len(current) >= max_files or size + n > max_bytes):
            batches.append(current)
            current, size = [], 0
        current.append(item)
        size += n
    if current:
        batches.append(current)
    return batches


def merge_results(results: list[dict]) -> dict:
    """One response for several batches: v2 ``uploads`` are concatenated; legacy
    responses (no per-file detail) are kept under ``batches``."""
    if len(results) == 1:
        return results[0]
    lists = [r.get("uploads") for r in results]
    if results and all(isinstance(u, list) for u in lists):
        return {"uploads": [item for u in lists for item in u]}  # type: ignore[union-attr]
    return {"batches": results}


class UploadBatchError(RuntimeError):
    """Some batches of an upload failed. ``result``/``uploaded_files`` describe the
    batches that succeeded (record them); ``failed_files`` still need uploading."""

    def __init__(self, message: str, *, result: dict, uploaded_files: list[Path], failed_files: list[Path]) -> None:
        super().__init__(message)
        self.result = result
        self.uploaded_files = uploaded_files
        self.failed_files = failed_files


class _TooLarge(RuntimeError):
    pass


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
        max_files_per_request: int | None = None,
        max_bytes_per_request: int | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_token = api_token
        self._profile_key = profile_key
        self._upload_path = upload_path
        self._anon_key = anon_key or None
        self._transport = transport
        self._retry_delays = retry_delays
        self._sleep = sleep
        self._max_files = max_files_per_request or upload_max_files()
        self._max_bytes = max_bytes_per_request or upload_max_bytes()

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

        Files are sent in batches of at most 20 files / 32 MB (the Ledger v2 server
        limits); a 413 splits the batch in half and retries.

        Returns the parsed JSON response body (``{"raw": text}`` if the body is
        not a JSON object; v2 ``uploads`` merged across batches).  4xx responses
        raise immediately; 5xx responses and network errors are retried with
        backoff before raising.  When some batches succeed and others fail,
        ``UploadBatchError`` carries both so the caller can record the uploaded
        files.
        """
        if not files:
            raise ValueError("No files to upload")
        if not self._api_token:
            raise RuntimeError("CCS_SCRAPER_API_TOKEN is not set")

        hint = bank_code or None
        data = {"bank_code_hint": hint} if hint else {}
        # Read once so every retry sends identical bytes without reopening files.
        payload = [(path.name, path.read_bytes()) for path in files]
        by_name = {path.name: path for path in files}
        batches = chunk_payload(payload, self._max_files, self._max_bytes)
        if len(batches) > 1:
            logger.info("Uploading %d file(s) in %d request(s)", len(payload), len(batches))

        results: list[dict] = []
        uploaded: list[Path] = []
        failed: list[Path] = []
        errors: list[Exception] = []
        with httpx.Client(timeout=120, transport=self._transport) as client:
            for batch in batches:
                try:
                    results.extend(self._post_splitting(client, batch, data))
                    uploaded.extend(by_name[name] for name, _ in batch)
                except Exception as exc:  # noqa: BLE001 — other batches still go
                    errors.append(exc)
                    failed.extend(by_name[name] for name, _ in batch)

        if errors:
            if not results and len(batches) == 1:
                raise errors[0]
            raise UploadBatchError(
                f"{len(failed)} of {len(payload)} file(s) failed to upload: {errors[0]}",
                result=merge_results(results) if results else {},
                uploaded_files=uploaded,
                failed_files=failed,
            )
        result = merge_results(results)
        self._log_result(result, bank_code)
        return result

    def _post_splitting(self, client: httpx.Client, batch: list[tuple[str, bytes]], data: dict) -> list[dict]:
        """POST one batch; on 413 split it in half and post each half (recursively)."""
        try:
            return [self._post_with_retries(client, batch, data)]
        except _TooLarge as exc:
            if len(batch) == 1:
                raise RuntimeError(f"Upload failed 413: {batch[0][0]} is too large for one request") from exc
            mid = len(batch) // 2
            logger.warning("Upload of %d file(s) rejected with 413; splitting into %d + %d", len(batch), mid,
                           len(batch) - mid)
            return self._post_splitting(client, batch[:mid], data) + self._post_splitting(client, batch[mid:], data)

    def _post_with_retries(self, client: httpx.Client, batch: list[tuple[str, bytes]], data: dict) -> dict:
        url = self.upload_url
        headers = self._headers()
        last_exc: Exception = RuntimeError("Upload failed")
        for attempt, delay in enumerate((*self._retry_delays, None), start=1):
            multipart = [("files", (name, content, "application/pdf")) for name, content in batch]
            try:
                response = client.post(url, headers=headers, files=multipart, data=data)
            except httpx.HTTPError as exc:
                last_exc = exc
            else:
                if response.is_success:
                    body = self._json_or_text(response)
                    return body if isinstance(body, dict) else {"raw": body}

                body = self._json_or_text(response)
                if response.status_code == 413:
                    raise _TooLarge(f"Upload failed 413: {body}")
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
