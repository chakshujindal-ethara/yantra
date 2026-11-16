# Odoo 19 CE with the Yantra bridge addons and Ethara's Assessment v2, vendored at a pinned commit (vendor/VENDOR.toml).
# Database settings come from the environment (HOST, PORT, USER, PASSWORD), which the official image's entrypoint turns
# into --db_* flags. Pinned by digest (the tag is the nightly it was taken from); Dependabot's docker ecosystem bumps it.
FROM odoo:20.0-20261112@sha256:8bcae4c1f895683ee851e19dd3e7d999e81e770defe9015bc9dad8bbf10f2b0d
USER root
# Assessment v2's Python packages (PyJWT, httpx, boto3, redis), pinned with hashes. The base image ships older
# Debian copies of some of their dependencies (urllib3, idna, certifi); pip installs its own beside them.
COPY requirements-v2.txt /tmp/requirements-v2.txt
RUN pip3 install --no-cache-dir --break-system-packages --require-hashes -r /tmp/requirements-v2.txt \
    && rm /tmp/requirements-v2.txt \
    && python3 -c "import jwt; assert hasattr(jwt, 'encode'), 'another package named jwt shadows PyJWT'"
COPY odoo.conf /etc/odoo/odoo.conf
# Not /mnt/extra-addons: the base image declares that path a VOLUME, and compose keeps a container's anonymous volumes
# across recreates, so a rebuilt image's addons there would be hidden behind the first build's copy.
COPY addons /mnt/yantra-addons
COPY vendor/addons /mnt/vendor-addons
COPY init.sh /usr/local/bin/yantra-odoo-init
RUN chmod 755 /usr/local/bin/yantra-odoo-init
USER odoo
