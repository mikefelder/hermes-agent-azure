#!/usr/bin/env python3
"""Start or scrub the one-time Hermes Key Vault bootstrap job."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import subprocess
import tempfile
from typing import Any


API_VERSION = "2025-01-01"
SECRET_NAME = "bootstrap-secret-value"
MODE_ENV_NAME = "BOOTSTRAP_MODE"
VALUE_ENV_NAME = "BOOTSTRAP_SECRET_VALUE"


def run(command: list[str], *, capture: bool = False) -> str:
    result = subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
    )
    return result.stdout.strip() if capture else ""


def terraform_output(name: str) -> str:
    return run(["terraform", "output", "-raw", name], capture=True)


def az_json(method: str, url: str, body: dict[str, Any] | None = None) -> Any:
    command = ["az", "rest", "--method", method, "--url", url, "--output", "json"]
    temporary_path: str | None = None
    try:
        if body is not None:
            with tempfile.NamedTemporaryFile(
                mode="w",
                prefix="hermes-bootstrap-",
                suffix=".json",
                delete=False,
            ) as temporary:
                os.chmod(temporary.name, 0o600)
                json.dump(body, temporary, separators=(",", ":"))
                temporary_path = temporary.name
            command.extend(["--body", f"@{temporary_path}"])

        output = run(command, capture=True)
        return json.loads(output) if output else None
    finally:
        if temporary_path:
            try:
                os.remove(temporary_path)
            except FileNotFoundError:
                pass


def job_url() -> str:
    subscription_id = run(
        ["az", "account", "show", "--query", "id", "--output", "tsv"],
        capture=True,
    )
    resource_group = terraform_output("resource_group_name")
    job_name = terraform_output("secret_bootstrap_job_name")
    if not job_name or job_name == "null":
        raise RuntimeError(
            "Bootstrap job is disabled. Apply with enable_secret_bootstrap=true first."
        )
    resource_id = (
        f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.App/jobs/{job_name}"
    )
    return f"https://management.azure.com{resource_id}"


def get_job(base_url: str) -> dict[str, Any]:
    return az_json("get", f"{base_url}?api-version={API_VERSION}")


def patch_job(base_url: str, job: dict[str, Any]) -> None:
    body = {
        "properties": {
            "configuration": job["properties"]["configuration"],
            "template": job["properties"]["template"],
        }
    }
    az_json("patch", f"{base_url}?api-version={API_VERSION}", body)


def bootstrap_container(job: dict[str, Any]) -> dict[str, Any]:
    containers = job["properties"]["template"]["containers"]
    return next(container for container in containers if container["name"] == "bootstrap")


def scrub(base_url: str) -> None:
    job = get_job(base_url)
    configuration = job["properties"]["configuration"]
    configuration["secrets"] = [
        secret
        for secret in (configuration.get("secrets") or [])
        if secret.get("name") != SECRET_NAME
    ]
    container = bootstrap_container(job)
    container["env"] = [
        entry
        for entry in (container.get("env") or [])
        if entry.get("name") not in (MODE_ENV_NAME, VALUE_ENV_NAME)
    ]
    patch_job(base_url, job)
    print("Temporary Container Apps secret and environment reference removed.")


def status(base_url: str) -> None:
    response = az_json("get", f"{base_url}/executions?api-version={API_VERSION}")
    executions = sorted(
        response.get("value", []),
        key=lambda execution: execution.get("properties", {}).get("startTime", ""),
        reverse=True,
    )
    if not executions:
        print("No bootstrap executions found.")
        return

    latest = executions[0]
    properties = latest.get("properties", {})
    print(f"Execution: {latest.get('name', 'unknown')}")
    print(f"Status: {properties.get('status', 'unknown')}")
    print(f"Started: {properties.get('startTime', 'unknown')}")
    print(f"Ended: {properties.get('endTime') or 'not finished'}")


def seed(base_url: str, mode: str) -> None:
    label = "New Hermes dashboard password" if mode == "dashboard" else "Tailscale OAuth client secret"
    secret_value = getpass.getpass(f"{label} (20+ characters): ")
    confirmation = getpass.getpass(f"Confirm {label.lower()}: ")
    if secret_value != confirmation:
        raise ValueError("Secret values do not match")
    if len(secret_value) < 20:
        raise ValueError("Secret must contain at least 20 characters")

    job = get_job(base_url)
    configuration = job["properties"]["configuration"]
    configuration["secrets"] = [
        secret
        for secret in (configuration.get("secrets") or [])
        if secret.get("name") != SECRET_NAME
    ]
    configuration["secrets"].append({"name": SECRET_NAME, "value": secret_value})

    container = bootstrap_container(job)
    container["env"] = [
        entry
        for entry in (container.get("env") or [])
        if entry.get("name") not in (MODE_ENV_NAME, VALUE_ENV_NAME)
    ]
    container["env"].extend(
        [
            {"name": MODE_ENV_NAME, "value": mode},
            {"name": VALUE_ENV_NAME, "secretRef": SECRET_NAME},
        ]
    )

    try:
        patch_job(base_url, job)
        execution = az_json(
            "post",
            f"{base_url}/start?api-version={API_VERSION}",
            {},
        )
    except Exception:
        scrub(base_url)
        raise
    finally:
        secret_value = ""
        confirmation = ""

    execution_name = execution.get("name", "unknown") if execution else "unknown"
    print(f"Bootstrap execution started: {execution_name}")
    print("Do not destroy the job until the execution reports Succeeded.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action", choices=("seed", "seed-tailscale", "status", "scrub")
    )
    args = parser.parse_args()

    base_url = job_url()
    if args.action == "seed":
        seed(base_url, "dashboard")
    elif args.action == "seed-tailscale":
        seed(base_url, "tailscale")
    elif args.action == "status":
        status(base_url)
    else:
        scrub(base_url)


if __name__ == "__main__":
    main()