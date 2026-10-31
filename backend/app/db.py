"""Connection pools (one per DB role) and the single helper every route uses.

Each product has its own pool logged in as <product>_app, so an ERP request can
never touch AML tables - PostgreSQL rejects it even if the code is wrong.
All business rules live in DB functions; Python only calls them.
"""
import logging

from fastapi import HTTPException
from psycopg import errors
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from .config import PRODUCTS, settings

log = logging.getLogger(__name__)

pools: dict[str, ConnectionPool] = {}

# SQLSTATE raised by our DB functions -> HTTP status (contract in docs/DB_GUIDE.md)
_HTTP = {
    "42501": 403,  # insufficient_privilege (permission, maker-checker)
    "22023": 400,  # invalid_parameter_value (bad input, illegal state change)
    "P0002": 404,  # no_data_found
    "23505": 409,  # unique_violation
    "22P02": 422, "23503": 422, "23502": 422, "23514": 422, "22007": 422, "22008": 422,  # bad data at commit
}


def open_pools() -> None:
    for name in ("iam", *PRODUCTS):
        pools[name] = ConnectionPool(
            settings.dsn(f"{name}_app"), min_size=1, max_size=10,
            kwargs={"autocommit": True},  # each function call is its own transaction
            name=name, open=True)


def close_pools() -> None:
    for p in pools.values():
        p.close()


def call(pool: str, function: str, *args):
    """SELECT <function>(args...) on the given pool and return the single value.

    `function` is always a literal from our code (never user input).
    dict/list args are sent as jsonb.
    """
    args = tuple(Jsonb(a) if isinstance(a, (dict, list)) else a for a in args)
    placeholders = ", ".join(["%s"] * len(args))
    try:
        with pools[pool].connection() as conn:
            return conn.execute(f"SELECT {function}({placeholders})", args).fetchone()[0]
    except errors.Error as e:
        status = _HTTP.get(e.sqlstate or "")
        if status is None:
            log.exception("DB call %s failed", function)
            raise HTTPException(500, "Database error") from e
        raise HTTPException(status, e.diag.message_primary or "Request rejected") from e


def rows(pool: str, sql: str, *args) -> list[tuple]:
    """For set-returning functions (e.g. fn_get_batch_events)."""
    with pools[pool].connection() as conn:
        return conn.execute(sql, args).fetchall()
