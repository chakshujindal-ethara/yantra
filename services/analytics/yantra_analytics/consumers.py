"""What analytics consumes: everything. One durable consumer on `>` per generation; dead letters are replayed by
whichever generation's name they carry."""

from collections.abc import Iterator, Mapping

from yantra_analytics.service import DURABLE, ingest
from yantra_common.consumer import Handler

__all__ = ["AnyGeneration", "ingest"]


class AnyGeneration(Mapping[str, Handler]):
    """The replay table for analytics: every `analytics-all-g<n>` maps to `ingest`, whatever generation wrote the
    dead letter."""

    def __getitem__(self, durable: str) -> Handler:
        if durable.startswith(f"{DURABLE}-g"):
            return ingest
        raise KeyError(durable)

    def __iter__(self) -> Iterator[str]:
        return iter([f"{DURABLE}-g0"])

    def __len__(self) -> int:
        return 1
