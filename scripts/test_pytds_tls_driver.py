#!/usr/bin/env python3
"""Script utilitário para validar login TLS usando o checkout local do pytds."""
from __future__ import annotations

import contextlib
import os
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
PYTDS_SRC = PROJECT_ROOT / "pytds" / "src"
if not PYTDS_SRC.exists():
    raise SystemExit(f"Pasta do pytds não encontrada em {PYTDS_SRC}")

if str(PYTDS_SRC) not in sys.path:
    sys.path.insert(0, str(PYTDS_SRC))

os.environ.setdefault("PYTDS_TRACE_EVENTS", "1")

import pytds  # type: ignore  # pylint: disable=import-error
from pytds import tds_base  # type: ignore  # pylint: disable=import-error

HOST = "localhost"
PORT = 1433
DATABASE = "dart"
USER = "dart"
PASSWORD = "dart"
QUERY = "SELECT 1 AS value"
APPNAME = "pytds-local-tls-check"
CAFILE = PROJECT_ROOT / "scripts" / "certificate" / "sqlserver.crt"
LOG_PATH = PROJECT_ROOT / "scripts" / "pytds_tls_driver.log"


class _TeeWriter:
    def __init__(self, *streams):
        self._streams = streams

    def write(self, data):
        for stream in self._streams:
            stream.write(data)

    def flush(self):
        for stream in self._streams:
            stream.flush()


def run_once() -> None:
    print("[PYTDS-TLS] pytds localizado em:", getattr(pytds, "__file__", "?"))
    print("[PYTDS-TLS] Versão reportada:", getattr(pytds, "__version__", "unknown"))
    print(
        "[PYTDS-TLS] Destino:",
        f"user={USER} host={HOST} port={PORT} db={DATABASE}",
    )
    print("[PYTDS-TLS] Certificado CA:", CAFILE)

    conn = pytds.connect(
        server=HOST,
        port=PORT,
        database=DATABASE,
        user=USER,
        password=PASSWORD,
        as_dict=False,
        appname=APPNAME,
        autocommit=False,
        tds_version=tds_base.TDS74,
        bytes_to_unicode=True,
        cafile=str(CAFILE),
        validate_host=False,
    )
    print("[PYTDS-TLS] Conexão estabelecida via", conn.__class__.__name__)
    with conn.cursor() as cursor:
        print("[PYTDS-TLS] Executando:", QUERY)
        cursor.execute(QUERY)
        row = cursor.fetchone()
        print("[PYTDS-TLS] Resultado:", row)
    conn.close()
    print("[PYTDS-TLS] Conexão TLS encerrada com sucesso")


def main() -> None:
    try:
        run_once()
    except Exception as exc:  # noqa: BLE001
        print("[PYTDS-TLS] Falha ao conectar com TLS:", exc)
        raise


if __name__ == "__main__":
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_PATH, "w", encoding="utf-8", buffering=1) as fh:
        tee = _TeeWriter(sys.stdout, fh)
        with contextlib.redirect_stdout(tee):
            print("[PYTDS-TLS] Gravando log em", LOG_PATH)
            main()
            print("[PYTDS-TLS] Logs capturados em", LOG_PATH)
