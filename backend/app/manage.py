"""Account administration from the command line.

    python -m app.manage create-user --username dana --role clinician_reader

The password is read from a prompt (or CADENCE_NEW_USER_PASSWORD for scripts),
never from a command-line argument where it would land in shell history.
"""

import argparse
import getpass
import os
import sys

from app.auth import ROLES, create_user_sync
from app.config import settings
from app.db import init_db_sync


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.manage")
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create-user", help="Add an account")
    create.add_argument("--username", required=True)
    create.add_argument("--role", required=True, choices=sorted(ROLES))
    create.add_argument("--patient-id", default=settings.cadence_default_patient_id)
    args = parser.parse_args(argv)

    init_db_sync()
    password = os.environ.get("CADENCE_NEW_USER_PASSWORD") or getpass.getpass("Password: ")
    try:
        create_user_sync(args.username, password, args.role, args.patient_id)
    except ValueError as exc:
        print(f"Not created: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # duplicate username, unreadable database
        print(f"Not created: {exc}", file=sys.stderr)
        return 1
    print(f"Created {args.role} account '{args.username}'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
