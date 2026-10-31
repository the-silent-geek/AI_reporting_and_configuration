"""Two kinds of failure, decided once where they happen.

FinalError      the input itself is bad (unsupported/corrupt/empty file). Retrying
                gives the same result: report FAILED and acknowledge the job.
RetryableError  a dependency hiccup (DB, storage, OCR time budget). The job is
                re-queued with backoff; after WORKER_MAX_ATTEMPTS it becomes FAILED.

`message` is shown to users in the UI (ingestion_batch.error_message), so it must
never contain paths, SQL, stack traces, prompts or secrets. `code` is for logs/ops.
"""


class WorkerError(Exception):
    retryable = False

    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class FinalError(WorkerError):
    retryable = False


class RetryableError(WorkerError):
    retryable = True
