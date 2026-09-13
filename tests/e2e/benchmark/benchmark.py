import asyncio
import aiohttp
import json
import os
import random
import time
import numpy as np
from kubernetes import client, config
from kubernetes.client.rest import ApiException

# Configuration
NAMESPACE = "vllm"
ARMS = ["gemma-rr", "gemma-epp", "gemma-epp-noprefix"]
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROMPTS_FILE = os.path.join(SCRIPT_DIR, "prompts.json")
if not os.path.exists(PROMPTS_FILE):
    PROMPTS_FILE = "prompts.json"
VLLM_LABEL_SELECTOR = "app=vllm-server"
EXPECTED_VLLM_PODS = 2

AUDIENCE = "https://agent-router.internal"
METADATA_IDENTITY_URL = (
    "http://metadata.google.internal/computeMetadata/v1/"
    "instance/service-accounts/default/identity?audience=" + AUDIENCE
)
ID_TOKEN = ""


def fetch_id_token():
    import urllib.request

    req = urllib.request.Request(
        METADATA_IDENTITY_URL, headers={"Metadata-Flavor": "Google"}
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.read().decode("utf-8").strip()


def get_gateway_url(v1):
    try:
        svcs = v1.list_namespaced_service(namespace="envoy-gateway-system")
        for s in svcs.items:
            if "envoy-routing-envoy-ai-gateway" in s.metadata.name:
                for p in s.spec.ports:
                    if p.port == 8080:
                        url = f"http://{s.metadata.name}.envoy-gateway-system.svc.cluster.local:8080/v1/chat/completions"
                        print(f"Discovered Gateway endpoint: {url}")
                        return url
        for s in svcs.items:
            for p in s.spec.ports:
                if p.port == 8080:
                    url = f"http://{s.metadata.name}.envoy-gateway-system.svc.cluster.local:8080/v1/chat/completions"
                    print(f"Discovered Gateway endpoint (port 8080): {url}")
                    return url
    except Exception as e:
        print(f"Gateway service discovery notice: {e}")
    return "http://envoy-routing-envoy-ai-gateway-add85b85.envoy-gateway-system.svc.cluster.local:8080/v1/chat/completions"


def setup_k8s():
    try:
        config.load_incluster_config()
    except Exception:
        config.load_kube_config()
    return client.CoreV1Api()


def delete_vllm_pods(v1, namespace, label_selector):
    print(f"Deleting vLLM pods with label {label_selector} in namespace {namespace}...")
    try:
        v1.delete_collection_namespaced_pod(
            namespace=namespace,
            label_selector=label_selector,
            grace_period_seconds=10,
        )
    except ApiException as e:
        print(f"delete_collection failed: {e}. Falling back to individual delete...")
        try:
            pods = v1.list_namespaced_pod(namespace=namespace, label_selector=label_selector)
            for p in pods.items:
                v1.delete_namespaced_pod(
                    name=p.metadata.name,
                    namespace=namespace,
                    grace_period_seconds=10,
                )
        except Exception as e2:
            print(f"Individual delete exception: {e2}")


def wait_for_vllm_pods_ready(v1, namespace, label_selector, expected_count=EXPECTED_VLLM_PODS, timeout=600):
    print("Waiting for old vLLM pods to terminate and new pods to become Ready...")
    start_time = time.time()
    time.sleep(5)  # brief pause for k8s to register deletion

    while time.time() - start_time < timeout:
        try:
            pods = v1.list_namespaced_pod(namespace=namespace, label_selector=label_selector).items
        except Exception as e:
            print(f"Error listing pods: {e}")
            time.sleep(5)
            continue

        terminating_pods = [p for p in pods if p.metadata.deletion_timestamp is not None]
        active_pods = [p for p in pods if p.metadata.deletion_timestamp is None]

        if terminating_pods:
            print(f"Waiting for {len(terminating_pods)} terminating pod(s) to exit...")
            time.sleep(5)
            continue

        if len(active_pods) < expected_count:
            print(f"Waiting for new pods to appear (active: {len(active_pods)}/{expected_count})...")
            time.sleep(5)
            continue

        all_ready = True
        for pod in active_pods:
            if pod.status.phase != "Running":
                all_ready = False
                break

            is_ready = False
            if pod.status.conditions:
                for cond in pod.status.conditions:
                    if cond.type == "Ready" and cond.status == "True":
                        is_ready = True
                        break
            if not is_ready:
                all_ready = False
                break

        if all_ready and len(active_pods) == expected_count:
            print(f"All {len(active_pods)} new vLLM pods are Running and Ready.")
            return active_pods

        time.sleep(5)

    print("Timeout waiting for pods to become ready.")
    return None


async def send_chat_completion(session, url, model, prompt_text, max_tokens=20, is_warmup=False):
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt_text}],
        "stream": True,
        "max_tokens": max_tokens,
    }

    start_time = time.time()
    try:
        async with session.post(
            url,
            json=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {ID_TOKEN}",
            },
            timeout=aiohttp.ClientTimeout(total=90),
        ) as response:
            if response.status != 200:
                body = await response.text()
                if not is_warmup:
                    print(f"HTTP {response.status} [{model}]: {body[:120]}")
                return None

            async for line in response.content:
                line_str = line.decode("utf-8", errors="ignore").strip()
                if line_str and line_str.startswith("data:") and not line_str.endswith("[DONE]"):
                    ttft = time.time() - start_time
                    async for _ in response.content:
                        pass
                    return ttft
    except Exception as e:
        if not is_warmup:
            print(f"Request exception [{model}]: {e}")
        return None


async def wait_for_route_ready(session, gateway_url, arm, max_attempts=15):
    print(f"Verifying gateway route for arm '{arm}'...")
    for attempt in range(1, max_attempts + 1):
        ttft = await send_chat_completion(session, gateway_url, arm, "Warmup ping", max_tokens=5, is_warmup=True)
        if ttft is not None:
            print(f"Route '{arm}' verified and warm (attempt {attempt}, TTFT={ttft:.3f}s)")
            return True
        print(f"Route '{arm}' warmup attempt {attempt}/{max_attempts} waiting...")
        await asyncio.sleep(4)
    print(f"Warning: Route '{arm}' failed to stabilize within timeout.")
    return False


async def fetch_vllm_metrics(session, pod_ip):
    url = f"http://{pod_ip}:8000/metrics"
    try:
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=10)) as response:
            if response.status == 200:
                return await response.text()
    except Exception as e:
        print(f"Error scraping metrics from {pod_ip}: {e}")
    return ""


def parse_metrics(metrics_text):
    total_hits = 0.0
    kv_perc = 0.0
    total_queries = 0.0
    cached_tokens = 0.0
    for line in metrics_text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("vllm:prefix_cache_hits_total"):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    total_hits += float(parts[1])
                except ValueError:
                    pass
        elif line.startswith("vllm:prefix_cache_queries_total"):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    total_queries += float(parts[1])
                except ValueError:
                    pass
        elif line.startswith("vllm:prompt_tokens_cached_total"):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    cached_tokens += float(parts[1])
                except ValueError:
                    pass
        elif line.startswith("vllm:kv_cache_usage_perc") or line.startswith("vllm:gpu_cache_usage_perc"):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    kv_perc = max(kv_perc, float(parts[1]))
                except ValueError:
                    pass
    return total_hits, kv_perc, total_queries, cached_tokens


async def run_arm(arm, prompts, v1):
    print(f"\n========================================================")
    print(f" Starting Evaluation for Arm: {arm}")
    print(f"========================================================")
    gateway_url = get_gateway_url(v1)

    # Step 1: Cache reset via Pod termination & restart
    delete_vllm_pods(v1, NAMESPACE, VLLM_LABEL_SELECTOR)
    pods = wait_for_vllm_pods_ready(v1, NAMESPACE, VLLM_LABEL_SELECTOR, expected_count=EXPECTED_VLLM_PODS)
    if not pods:
        print(f"Aborting arm '{arm}' due to pod readiness timeout.")
        return None

    # Allow 5s buffer for service/NEG routing tables
    await asyncio.sleep(5)

    connector = aiohttp.TCPConnector(limit=50)
    async with aiohttp.ClientSession(connector=connector) as session:
        # Warmup route
        ready = await wait_for_route_ready(session, gateway_url, arm)
        if not ready:
            print(f"Route not ready for arm '{arm}'. Aborting.")
            return None

        # Round 1: Cold Prefill / Cache Population with 16 persona prompts (~2k tokens each)
        print(f"\n[Arm: {arm}] Phase 1: Cache Population (16 prompts, ~2000 tokens each)...")
        cold_tasks = []
        for p in prompts:
            cold_tasks.append(send_chat_completion(session, gateway_url, arm, p["text"]))
        cold_results = await asyncio.gather(*cold_tasks)
        cold_ttfts = [r for r in cold_results if r is not None]
        print(f"Phase 1 Completed: {len(cold_ttfts)}/{len(prompts)} succeeded.")
        if cold_ttfts:
            cold_p50 = np.percentile(cold_ttfts, 50)
            cold_p95 = np.percentile(cold_ttfts, 95)
            cold_p99 = np.percentile(cold_ttfts, 99)
            print(f"Phase 1 Cold TTFT - P50: {cold_p50:.3f}s | P95: {cold_p95:.3f}s | P99: {cold_p99:.3f}s")
        else:
            cold_p50 = cold_p95 = cold_p99 = 0.0

        # Pause 3 seconds
        await asyncio.sleep(3)

        # Round 2: Cache Evaluation / Prefix Hit with same 16 persona prompts
        print(f"\n[Arm: {arm}] Phase 2: Cache Evaluation (16 prompts, measuring prefix cache hit)...")
        eval_tasks = []
        for p in prompts:
            eval_tasks.append(send_chat_completion(session, gateway_url, arm, p["text"]))
        eval_results = await asyncio.gather(*eval_tasks)
        eval_ttfts = [r for r in eval_results if r is not None]
        print(f"Phase 2 Completed: {len(eval_ttfts)}/{len(prompts)} succeeded.")

        if not eval_ttfts:
            print("No valid evaluation TTFT recorded.")
            return None

        eval_p50 = np.percentile(eval_ttfts, 50)
        eval_p95 = np.percentile(eval_ttfts, 95)
        eval_p99 = np.percentile(eval_ttfts, 99)
        print(f"Phase 2 Eval TTFT - P50: {eval_p50:.3f}s | P95: {eval_p95:.3f}s | P99: {eval_p99:.3f}s")

        # Step 3: Collect Prometheus metrics from vLLM pods
        print(f"\nCollecting cache metrics from {len(pods)} vLLM pod(s)...")
        pod_ips = [pod.status.pod_ip for pod in pods if pod.status.pod_ip]
        total_hits = 0.0
        cache_usages = {}
        per_pod_hits = {}

        for ip in pod_ips:
            metrics_text = await fetch_vllm_metrics(session, ip)
            hits, kv_perc, queries, cached = parse_metrics(metrics_text)
            total_hits += hits
            cache_usages[ip] = kv_perc
            per_pod_hits[ip] = hits
            hit_rate = (hits / queries * 100.0) if queries > 0 else 0.0
            print(f"Pod {ip} -> Prefix Cache Hits: {hits:.0f} tokens (Queries: {queries:.0f}, Hit Rate: {hit_rate:.1f}%), KV Cache Usage: {kv_perc * 100:.1f}%")

        print(f"Total Cluster Prefix Cache Hits: {total_hits:.0f} tokens")

        return {
            "arm": arm,
            "cold_ttfts": cold_ttfts,
            "cold_p50": cold_p50,
            "cold_p95": cold_p95,
            "cold_p99": cold_p99,
            "eval_ttfts": eval_ttfts,
            "eval_p50": eval_p50,
            "eval_p95": eval_p95,
            "eval_p99": eval_p99,
            "total_hits": total_hits,
            "per_pod_hits": per_pod_hits,
            "cache_usages": cache_usages,
        }


def main():
    global ID_TOKEN
    ID_TOKEN = fetch_id_token()
    print(f"Workload ID token acquired, length={len(ID_TOKEN)}")
    print("Loading prompts...")
    with open(PROMPTS_FILE, "r") as f:
        prompts = json.load(f)
    print(f"Loaded {len(prompts)} prompts from {PROMPTS_FILE}.")

    v1 = setup_k8s()

    random.shuffle(ARMS)
    print(f"Randomized run order: {ARMS}")

    results = {}
    for arm in ARMS:
        res = asyncio.run(run_arm(arm, prompts, v1))
        results[arm] = res

    print("\n========================================================")
    print("            3-ARM BENCHMARK FINAL REPORT                ")
    print("========================================================")
    print(f"{'Arm':<22} | {'Cold P50':<10} | {'Eval P50':<10} | {'Eval P95':<10} | {'Eval P99':<10} | {'Cache Hits (Tokens)':<20} | {'KV Cache %'}")
    print("-" * 100)

    for arm in ARMS:
        res = results.get(arm)
        if res:
            usages = ", ".join([f"{v * 100:.1f}%" for v in res["cache_usages"].values()])
            print(
                f"{arm:<22} | {res['cold_p50']:<10.3f}s | {res['eval_p50']:<10.3f}s | {res['eval_p95']:<10.3f}s | {res['eval_p99']:<10.3f}s | {res['total_hits']:<20.0f} | {usages}"
            )
        else:
            print(f"{arm:<22} | FAILED OR ABORTED")

    # Statistical Analysis
    if "gemma-rr" in results and "gemma-epp-noprefix" in results and "gemma-epp" in results:
        rr = results["gemma-rr"]
        epp_noprefix = results["gemma-epp-noprefix"]
        epp = results["gemma-epp"]
        if rr and epp_noprefix and epp:
            epp_overhead = epp_noprefix["eval_p50"] - rr["eval_p50"]
            prefix_scorer_gain = epp_noprefix["eval_p50"] - epp["eval_p50"]
            cold_p50 = epp["cold_p50"]
            speedup = (cold_p50 / epp["eval_p50"]) if epp["eval_p50"] > 0 and cold_p50 > 0 else 0

            print(f"\n[Statistical Analysis]")
            print(f"EPP Overhead (vs Pure RR)   : {epp_overhead:+.3f}s")
            print(f"Prefix Scorer Net Gain      : {prefix_scorer_gain:+.3f}s")
            if speedup > 0:
                print(f"EPP Cache Hit Speedup       : {speedup:.2f}x (Cold vs Eval)")

    print("\nBenchmark run completed successfully.")


if __name__ == "__main__":
    main()
