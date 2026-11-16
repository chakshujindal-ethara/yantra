"""The analytics module's own settings (`YANTRA_ANALYTICS_*`), read without the whole process configuration."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class AnalyticsSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="YANTRA_ANALYTICS_", extra="ignore")

    retention_days: int = 400  # warehouse events older than this are deleted; the marts keep their aggregates


@lru_cache(maxsize=1)
def analytics_settings() -> AnalyticsSettings:
    return AnalyticsSettings()
