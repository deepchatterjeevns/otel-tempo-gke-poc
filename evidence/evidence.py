#!/usr/bin/env python3
"""
Python unified evidence CLI for OTel/Tempo POC (GCP Port).
Replaces the individual run-*.ps1/sh scripts.
"""

import argparse
import csv
import json
import os
import subprocess
import time
import urllib.request
import urllib.parse
from datetime import datetime

RESULTS_DIR = os.path.join(os.path.dirname(__file__), "results")
os.makedirs(RESULTS_DIR, exist_ok=True)

def log(msg):
    ts = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{ts}] {msg}")

def tempo_api(path):
    url = f"http://127.0.0.1:3200{path}"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode())
    except Exception as e:
        return {}

def prom_api(query):
    url = f"http://127.0.0.1:9090/api/v1/query?query={urllib.parse.quote(query)}"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode())
    except Exception as e:
        return {}

def run_kubectl(cmd_args, namespace="default", return_json=False):
    base_cmd = ["kubectl", "-n", namespace] + cmd_args
    if return_json:
        base_cmd += ["-o", "json"]
    try:
        res = subprocess.run(base_cmd, capture_output=True, text=True, check=True)
        if return_json:
            return json.loads(res.stdout)
        return res.stdout
    except subprocess.CalledProcessError:
        return {} if return_json else ""

def ingest(args):
    run_id = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    csv_file = os.path.join(RESULTS_DIR, f"ingest-{run_id}.csv")
    log(f"=== Evidence 1: trace ingest (duration={args.duration_minutes}m) ===")

    try:
        col_pods = run_kubectl(["get", "pods", "-l", "app.kubernetes.io/managed-by=opentelemetry-operator"], "gap-otel", True)
        if len(col_pods.get("items", [])) < 1:
            log("Error: No collector pods found")
            return
    except Exception:
        log("Error checking pods")
        return

    log(f"Letting loadgen run for {args.duration_minutes} minutes")
    time.sleep(args.duration_minutes * 60)

    deadline = time.time() + args.timeout_seconds
    trace_found = False
    span_count = 0
    services = set()
    trace_id = ""

    while not trace_found and time.time() < deadline:
        search = tempo_api("/api/search?tags=service.name%3Dgap-frontend&limit=5")
        if search.get("traces"):
            trace_id = search["traces"][0].get("traceID")
            trace = tempo_api(f"/api/traces/{trace_id}")
            spans = trace.get("spans", [])
            span_count = len(spans)
            for s in spans:
                for attr in s.get("resource", {}).get("attributes", []):
                    if attr.get("key") == "service.name":
                        services.add(attr.get("value", {}).get("stringValue", ""))
            
            if span_count >= 2 and "gap-frontend" in services and "gap-backend" in services:
                trace_found = True
        if not trace_found:
            time.sleep(10)

    with open(csv_file, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["run_id", "timestamp", "trace_id", "span_count", "frontend_span", "backend_span", "verdict"])
        verdict = "PASS" if trace_found else "FAIL"
        writer.writerow([run_id, datetime.utcnow().isoformat(), trace_id, span_count, "gap-frontend" in services, "gap-backend" in services, verdict])

    log(f"Verdict: {verdict}")
    log(f"Artifact: {csv_file}")

def correlation(args):
    run_id = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    csv_file = os.path.join(RESULTS_DIR, f"correlation-{run_id}.csv")
    log("=== Evidence 2: correlation ===")

    queries = [
        ("frontend call rate", 'rate(traces_span_metrics_calls_total{service_name="gap-frontend"}[5m])', True),
        ("frontend duration", 'traces_span_metrics_duration_seconds_bucket{service_name="gap-frontend"}', False),
        ("backend call rate", 'rate(traces_span_metrics_calls_total{service_name="gap-backend"}[5m])', True),
        ("backend duration", 'traces_span_metrics_duration_seconds_bucket{service_name="gap-backend"}', False),
        ("span label", 'traces_span_metrics_calls_total{span_name="GET /"}', False)
    ]

    with open(csv_file, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["run_id", "timestamp", "claim", "query", "value", "verdict"])
        
        for name, query, check_val in queries:
            deadline = time.time() + 60
            val = None
            while val is None and time.time() < deadline:
                resp = prom_api(query)
                if resp.get("status") == "success" and resp.get("data", {}).get("result"):
                    val = resp["data"]["result"][0].get("value", [None, "found"])[1]
                if val is None:
                    time.sleep(10)
            
            ok = False
            if val is not None:
                if check_val and val != "found":
                    try:
                        ok = float(val) > 0
                    except:
                        pass
                else:
                    ok = True
            
            verdict = "PASS" if ok else "FAIL"
            log(f"{verdict}: {name} (val={val})")
            writer.writerow([run_id, datetime.utcnow().isoformat(), name, query, val, verdict])

def latency(args):
    run_id = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    csv_file = os.path.join(RESULTS_DIR, f"latency-{run_id}.csv")
    log("=== Evidence 3: latency attribution ===")

    deadline = time.time() + args.timeout_seconds
    traces = []
    while len(traces) < args.sample_traces and time.time() < deadline:
        resp = tempo_api(f"/api/search?tags=service.name%3Dgap-frontend&limit={args.sample_traces}")
        traces = resp.get("traces", [])
        if len(traces) < args.sample_traces:
            time.sleep(10)

    if not traces:
        log("FAIL: no traces found")
        return

    front_sum, front_c, back_sum, back_c = 0, 0, 0, 0

    with open(csv_file, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["run_id", "timestamp", "trace_id", "span_id", "service_name", "span_name", "duration_ns", "duration_ms"])
        
        for t in traces:
            t_id = t.get("traceID")
            trace = tempo_api(f"/api/traces/{t_id}")
            for s in trace.get("spans", []):
                svc = ""
                for attr in s.get("resource", {}).get("attributes", []):
                    if attr.get("key") == "service.name":
                        svc = attr.get("value", {}).get("stringValue", "")
                
                dur_ns = int(s.get("duration", 0))
                dur_ms = dur_ns / 1e6
                writer.writerow([run_id, datetime.utcnow().isoformat(), t_id, s.get("spanID"), svc, s.get("name"), dur_ns, dur_ms])
                
                if svc == "gap-frontend":
                    front_sum += dur_ns
                    front_c += 1
                elif svc == "gap-backend":
                    back_sum += dur_ns
                    back_c += 1

    avg_f = (front_sum / front_c / 1e6) if front_c else -1
    avg_b = (back_sum / back_c / 1e6) if back_c else -1
    log(f"avg frontend: {avg_f:.2f}ms | avg backend: {avg_b:.2f}ms")
    
    if avg_b > (avg_f - 5):
        log("PASS: backend holds latency")
    else:
        log("FAIL: attribution mismatch")

def resilience(args):
    run_id = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    csv_file = os.path.join(RESULTS_DIR, f"resilience-{run_id}.csv")
    log(f"=== Evidence 4: resilience (runs={args.runs}) ===")

    with open(csv_file, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["run_id", "iteration", "timestamp", "victim_pod", "replacement_s", "traces_flowed", "verdict"])

        for i in range(1, args.runs + 1):
            pods = run_kubectl(["get", "pods", "-l", "app.kubernetes.io/managed-by=opentelemetry-operator"], "gap-otel", True)
            items = pods.get("items", [])
            if len(items) < 2:
                log("Error: Expected 2 collectors")
                return
            
            victim = items[0].get("metadata", {}).get("name")
            log(f"Killing {victim}")
            
            t0 = time.time()
            subprocess.run(["kubectl", "delete", "pod", victim, "-n", "gap-otel", "--wait=false"], stdout=subprocess.DEVNULL)
            
            end_load = time.time() + args.load_seconds
            while time.time() < end_load:
                subprocess.run(["kubectl", "run", f"load-{int(time.time()*1000)}", "--image=curlimages/curl:8.8.0", "--restart=Never", "--rm", "-i", "--quiet", "--", "-s", "-o", "/dev/null", "http://frontend.gap-demo.svc:8000/"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                time.sleep(0.5)

            deadline = time.time() + 120
            ready = False
            while time.time() < deadline:
                p = run_kubectl(["get", "pods", "-l", "app.kubernetes.io/managed-by=opentelemetry-operator"], "gap-otel", True)
                running = [x for x in p.get("items", []) if x.get("status", {}).get("phase") == "Running"]
                if len(running) >= 2:
                    ready = True
                    break
                time.sleep(5)
            
            t_ready = time.time() - t0
            time.sleep(20)
            
            unix_end = int(time.time())
            unix_start = unix_end - 300
            search = tempo_api(f"/api/search?tags=service.name%3Dgap-frontend&limit=1&start={unix_start}&end={unix_end}")
            flowed = "YES" if len(search.get("traces", [])) >= 1 else "NO"
            
            verdict = "PASS" if (ready and flowed == "YES") else "FAIL"
            writer.writerow([run_id, i, datetime.utcnow().isoformat(), victim, round(t_ready, 1), flowed, verdict])
            log(f"Run {i} verdict: {verdict}")

def main():
    parser = argparse.ArgumentParser(description="Evidence scripts (GCP Port)")
    subparsers = parser.add_subparsers(dest="command")

    p_ingest = subparsers.add_parser("ingest")
    p_ingest.add_argument("--duration-minutes", type=int, default=2)
    p_ingest.add_argument("--timeout-seconds", type=int, default=300)

    p_corr = subparsers.add_parser("correlation")

    p_lat = subparsers.add_parser("latency")
    p_lat.add_argument("--sample-traces", type=int, default=10)
    p_lat.add_argument("--timeout-seconds", type=int, default=300)

    p_res = subparsers.add_parser("resilience")
    p_res.add_argument("--runs", type=int, default=2)
    p_res.add_argument("--load-seconds", type=int, default=60)

    args = parser.parse_args()

    if args.command == "ingest": ingest(args)
    elif args.command == "correlation": correlation(args)
    elif args.command == "latency": latency(args)
    elif args.command == "resilience": resilience(args)
    else: parser.print_help()

if __name__ == "__main__":
    main()
