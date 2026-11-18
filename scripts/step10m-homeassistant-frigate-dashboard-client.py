#!/usr/bin/env python3
"""Home Assistant WebSocket client for the generated Frigate dashboard."""

import base64
import json
import os
import sys

import websocket


def request(ws, message_id, message_type, **payload):
    ws.send(json.dumps({"id": message_id, "type": message_type, **payload}))
    while True:
        response = json.loads(ws.recv())
        if response.get("id") != message_id:
            continue
        if not response.get("success"):
            error = response.get("error", {})
            raise RuntimeError(error.get("message", "Home Assistant request failed"))
        return response.get("result")


def collect_entities(value):
    found = set()
    if isinstance(value, dict):
        entity = value.get("entity")
        if isinstance(entity, str):
            found.add(entity)
        entities = value.get("entities")
        if isinstance(entities, list):
            found.update(item for item in entities if isinstance(item, str))
        for child in value.values():
            found.update(collect_entities(child))
    elif isinstance(value, list):
        for child in value:
            found.update(collect_entities(child))
    return found


def main():
    credentials = json.loads(sys.stdin.read())
    token = credentials.get("token", "")
    if not isinstance(token, str) or not token:
        raise RuntimeError("Home Assistant token was not provided on stdin")

    url_path = os.environ["HA_DASHBOARD_URL_PATH"]
    title = os.environ["HA_DASHBOARD_TITLE"]
    icon = os.environ["HA_DASHBOARD_ICON"]
    force = os.environ.get("FORCE_UPDATE", "0") == "1"
    config = json.loads(base64.b64decode(os.environ["DASHBOARD_CONFIG_B64"]))

    ws = websocket.create_connection("ws://127.0.0.1:8123/api/websocket", timeout=20)
    try:
        hello = json.loads(ws.recv())
        if hello.get("type") != "auth_required":
            raise RuntimeError("Home Assistant WebSocket did not request authentication")

        ws.send(json.dumps({"type": "auth", "access_token": token}))
        auth = json.loads(ws.recv())
        if auth.get("type") != "auth_ok":
            raise RuntimeError("Home Assistant WebSocket authentication failed")

        dashboards = request(ws, 1, "lovelace/dashboards/list")
        existing = next((item for item in dashboards if item.get("url_path") == url_path), None)
        if existing and not force:
            print("dashboard_exists=" + url_path)
            return

        next_id = 2
        previous_config = None
        if existing:
            previous_config = request(ws, next_id, "lovelace/config", url_path=url_path)
            if not isinstance(previous_config, dict):
                raise RuntimeError("Could not read the existing dashboard configuration for rollback protection")
            next_id += 1

        states = request(ws, next_id, "get_states")
        next_id += 1
        available_entities = {item.get("entity_id") for item in states}
        required_entities = collect_entities(config)
        missing_entities = sorted(required_entities - available_entities)
        if missing_entities:
            raise RuntimeError("Dashboard entities not found: " + ", ".join(missing_entities))
        print("dashboard_entities_validated=" + str(len(required_entities)))

        created_id = None
        if not existing:
            created = request(
                ws, next_id, "lovelace/dashboards/create", url_path=url_path,
                title=title, icon=icon, show_in_sidebar=True, require_admin=False,
            )
            next_id += 1
            created_id = created.get("id")
            print("dashboard_created=" + str(created.get("url_path", url_path)))
        else:
            print("dashboard_update=enabled")

        try:
            request(ws, next_id, "lovelace/config/save", url_path=url_path, config=config)
        except Exception as save_error:
            if created_id:
                try:
                    request(ws, next_id + 1, "lovelace/dashboards/delete", dashboard_id=created_id)
                except Exception as cleanup_error:
                    raise RuntimeError(
                        f"Dashboard save failed and the new empty dashboard could not be removed: {cleanup_error}"
                    ) from save_error
            elif previous_config is not None:
                try:
                    request(ws, next_id + 1, "lovelace/config/save",
                            url_path=url_path, config=previous_config)
                except Exception as rollback_error:
                    raise RuntimeError(
                        f"Dashboard update failed and the previous configuration could not be restored: {rollback_error}"
                    ) from save_error
                raise RuntimeError(f"Dashboard update failed; previous configuration was restored: {save_error}") from save_error
            raise
        print("dashboard_config_saved=" + url_path)
    finally:
        ws.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Home Assistant dashboard operation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
