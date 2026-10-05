"""The PC's certificate and the phones that were paired with it.

Both ends hold a self-signed certificate and know the other's fingerprint
(SHA-256 of the DER certificate). Nothing else is ever trusted: the daemon's
TLS context accepts a client certificate only when it is one of the paired
ones, and the phone refuses every server certificate but the pinned one.
"""

import datetime
import hashlib
import json
import os
import ssl
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from . import config

CERT = config.STATE / "cert.pem"
KEY = config.STATE / "key.pem"
DEVICES = config.STATE / "devices.json"


def fingerprint(der):
    return hashlib.sha256(der).hexdigest()


def pem_fingerprint(pem):
    return fingerprint(x509.load_pem_x509_certificate(pem.encode()).public_bytes(serialization.Encoding.DER))


def ensure_certificate():
    """Creates the PC's key and certificate once; returns the fingerprint."""
    if not (CERT.exists() and KEY.exists()):
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"pshell {config.hostname()}")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (
            x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=365 * 30))
            .sign(key, hashes.SHA256())
        )
        descriptor = os.open(KEY, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        CERT.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return pem_fingerprint(CERT.read_text())


class Devices:
    """devices.json: [{ id, name, model, cert, paired, seen }], id being the fingerprint."""

    def __init__(self):
        self.list = []
        self.load()

    def load(self):
        try:
            data = json.loads(DEVICES.read_text())
            self.list = [d for d in data if isinstance(d, dict) and d.get("id") and d.get("cert")]
        except (OSError, ValueError):
            self.list = []

    def save(self):
        temporary = DEVICES.with_suffix(".tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump(self.list, handle, indent="\t")
        temporary.replace(DEVICES)

    def get(self, device_id):
        return next((d for d in self.list if d["id"] == device_id), None)

    def add(self, name, model, cert_pem):
        device_id = pem_fingerprint(cert_pem)
        self.list = [d for d in self.list if d["id"] != device_id]
        device = {"id": device_id, "name": name, "model": model, "cert": cert_pem, "paired": int(time.time()), "seen": int(time.time())}
        self.list.append(device)
        self.save()
        return device

    def remove(self, device_id):
        before = len(self.list)
        self.list = [d for d in self.list if d["id"] != device_id]
        if len(self.list) != before:
            self.save()
        return len(self.list) != before

    def touch(self, device_id, **fields):
        device = self.get(device_id)
        if device:
            device.update(fields, seen=int(time.time()))
            self.save()


def server_context(devices):
    """TLS for the listening port. A client certificate is optional so that an
    unpaired phone can reach /pair; one that is presented must be a paired one,
    or the handshake fails. Everything but /pair then asks for it."""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(CERT, KEY)
    context.verify_mode = ssl.CERT_OPTIONAL
    # A paired certificate is trusted as it is, not looked up by its name:
    # two phones may carry the same subject, and a lookup by name would then
    # check the second one against the first one's key.
    context.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
    for device in devices.list:
        trust(context, device["cert"])
    return context


def trust(context, cert_pem):
    try:
        context.load_verify_locations(cadata=cert_pem)
    except ssl.SSLError:
        pass


def peer_device(devices, ssl_object):
    """The paired device behind a connection, or None."""
    if ssl_object is None:
        return None
    der = ssl_object.getpeercert(binary_form=True)
    return devices.get(fingerprint(der)) if der else None
