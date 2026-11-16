# -*- coding: utf-8 -*-
"""Shared SSRF guard for any server-side fetch of a caller-supplied URL.

Both the image ingester (services/image_ingest._download) and the headless-
Chromium DOM capture (services/dom_capture.capture_and_annotate) open URLs that
can originate from an admin form field OR from LLM output (a prompt-injected SOP
can make the model emit a source_url). Without a guard those reach cloud metadata
(169.254.169.254 / metadata.google.internal), loopback, or private-range hosts —
classic SSRF that can steal the GCP service-account token.

This module is the ONE place that decides whether a URL is safe to fetch. It:
  * allows only http/https,
  * resolves the host to its IPs and rejects private / loopback / link-local /
    reserved / multicast ranges (defeats DNS-rebinding to an internal IP),
  * blocks the well-known metadata hostnames by name as belt-and-suspenders.

Pure stdlib, no Odoo import, so it is unit-testable in isolation.
"""
import ipaddress
import logging
import socket
import threading
import time
from urllib.parse import urlparse

_logger = logging.getLogger(__name__)

_BLOCKED_HOSTNAMES = {
    "metadata.google.internal",
    "metadata",
    "localhost",
}

# Short-lived host -> verdict cache for the DOM-capture route guard (see
# is_safe_url). A page load asks about the same handful of hosts hundreds of
# times; without this, every one is a blocking DNS round-trip on Playwright's
# dispatcher thread. The TTL is deliberately short so DNS-rebinding protection
# still holds: a name cannot masquerade as public for longer than the window.
_DNS_CACHE_TTL_S = 30.0
_DNS_CACHE_MAX = 512
_dns_cache = {}
_dns_cache_lock = threading.Lock()


def _dns_cache_get(host):
    key = (host or "").lower()
    now = time.monotonic()
    with _dns_cache_lock:
        hit = _dns_cache.get(key)
        if not hit:
            return None
        verdict, expires = hit
        if expires < now:
            _dns_cache.pop(key, None)
            return None
        return verdict


def _dns_cache_put(host, verdict):
    key = (host or "").lower()
    with _dns_cache_lock:
        if len(_dns_cache) >= _DNS_CACHE_MAX:
            # Unbounded growth would be a slow leak in a long-lived worker.
            # Drop everything already expired; if that frees nothing, clear.
            now = time.monotonic()
            for k in [k for k, (_v, e) in _dns_cache.items() if e < now]:
                _dns_cache.pop(k, None)
            if len(_dns_cache) >= _DNS_CACHE_MAX:
                _dns_cache.clear()
        _dns_cache[key] = (verdict, time.monotonic() + _DNS_CACHE_TTL_S)
    return verdict


def reset_dns_cache():
    """Drop every memoised verdict (tests, and after a DNS change)."""
    with _dns_cache_lock:
        _dns_cache.clear()



# RFC 6052 well-known prefix for NAT64/DNS64 (64:ff9b::/96). On an IPv6-only or
# NAT64 network (common on macOS/corporate Wi-Fi and in some CI runners) DNS64
# synthesises AAAA records in this range for IPv4-only hosts, so getaddrinfo
# returns e.g. 64:ff9b::14cf:4952 for github.com. Python flags that whole block
# is_reserved, which made the guard reject EVERY public URL on such a network -
# blocking all legitimate image/SOP ingestion. The address is not itself a
# destination: the low 32 bits are the real IPv4 address, so we unwrap and judge
# THAT. A NAT64 wrapper around an internal IPv4 (e.g. 64:ff9b::a00:1 -> 10.0.0.1)
# is still correctly blocked, so this closes no hole.
_NAT64_WELL_KNOWN = ipaddress.ip_network("64:ff9b::/96")


def _unwrap_nat64(ip):
    """Return the embedded IPv4 address for a NAT64 address, else None."""
    if ip.version != 6 or ip not in _NAT64_WELL_KNOWN:
        return None
    try:
        return ipaddress.ip_address(int(ip) & 0xFFFFFFFF)
    except ValueError:
        return None


def _ip_is_blocked(ip_str):
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return True  # unparseable -> refuse
    embedded = _unwrap_nat64(ip)
    if embedded is not None:
        # judge the real IPv4 destination behind the NAT64 wrapper
        ip = embedded
    return (
        ip.is_private or ip.is_loopback or ip.is_link_local
        or ip.is_reserved or ip.is_multicast or ip.is_unspecified
    )


def is_safe_url(url, *, allow_data=False):
    """True only when ``url`` is safe to open server-side. http(s) hosts are
    resolved and must be entirely public/non-metadata. Fail-closed on anything
    unparseable.

    ``allow_data``: when True, a ``data:`` URL is permitted. A data: URL is
    inline content with NO host to reach, so it cannot be an SSRF vector — the
    DOM-capture path renders self-contained data: HTML and needs this. It stays
    OFF by default so a plain image/file fetch never accepts one."""
    raw = (url or "").strip()
    if allow_data and raw[:5].lower() == "data:":
        return True
    try:
        parsed = urlparse(raw)
    except (ValueError, TypeError):
        return False
    if parsed.scheme not in ("http", "https"):
        return False
    host = parsed.hostname
    if not host:
        return False
    if host.lower() in _BLOCKED_HOSTNAMES:
        return False
    # A bare IP literal in the URL: check it directly.
    try:
        ipaddress.ip_address(host)
        return not _ip_is_blocked(host)
    except ValueError:
        pass
    # A hostname: resolve every A/AAAA record and reject if ANY is internal
    # (stops a name that resolves to 169.254.169.254 / 10.x / ::1).
    #
    # CACHED: the DOM-capture route guard calls this for EVERY sub-resource a
    # page requests (150+ on a site like github.com), and each miss is a
    # BLOCKING getaddrinfo on Playwright's dispatcher thread. Uncached, a
    # container with slow DNS spends tens of seconds stalled here, which is
    # long enough for the driver to give up and force-kill the browser. The
    # TTL keeps rebinding protection meaningful - an attacker cannot flip a
    # name to an internal IP for longer than the window - while collapsing a
    # page load's worth of lookups into a handful.
    cached = _dns_cache_get(host)
    if cached is not None:
        return cached
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return _dns_cache_put(host, False)
    if not infos:
        return _dns_cache_put(host, False)
    for _family, _type, _proto, _canon, sockaddr in infos:
        if _ip_is_blocked(sockaddr[0]):
            return _dns_cache_put(host, False)
    return _dns_cache_put(host, True)


def assert_safe_url(url, *, context="", allow_data=False):
    """Raise ValueError if ``url`` is not safe to fetch server-side."""
    if not is_safe_url(url, allow_data=allow_data):
        _logger.warning("SSRF guard blocked URL %r%s", url,
                        (" (%s)" % context) if context else "")
        raise ValueError(
            "Refusing to fetch %r: not a public http(s) URL (SSRF guard)%s"
            % (url, (" [%s]" % context) if context else ""))
