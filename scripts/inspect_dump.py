import json

with open("/tmp/envoy_dump.json") as f:
    d = json.load(f)

for c in d.get("configs", []):
    if "ListenersConfigDump" in c.get("@type", ""):
        for dl in c.get("dynamic_listeners", []):
            if dl.get("name") == "routing/envoy-ai-gateway/http":
                l = dl.get("active_state", {}).get("listener", {})
                print("per_connection_buffer_limit_bytes:", l.get("per_connection_buffer_limit_bytes"))
                dfc = l.get("default_filter_chain", {})
                for f in dfc.get("filters", []):
                    tc = f.get("typed_config", {})
                    print("hcm keys:", list(tc.keys()))
                    for k in ["max_request_headers_kb", "stream_idle_timeout", "request_timeout"]:
                        print(" ", k, tc.get(k))
