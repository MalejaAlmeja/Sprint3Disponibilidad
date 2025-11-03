import json, os, time, threading
from concurrent.futures import ThreadPoolExecutor, wait, ALL_COMPLETED
import pymysql
from aws_xray_sdk.core import xray_recorder, patch_all
patch_all()

# Lee variables de entorno inyectadas por Terraform
DB1_HOST = os.environ["DB1_HOST"]
DB2_HOST = os.environ["DB2_HOST"]
DB3_HOST = os.environ["DB3_HOST"]
DB_USER  = os.environ["DB_USER"]
DB_PASS  = os.environ["DB_PASS"]
DB_NAME  = os.environ.get("DB_NAME", "wms")
DB_PORT  = int(os.environ.get("DB_PORT", "3306"))
CONNECT_TIMEOUT = float(os.environ.get("CONNECT_TIMEOUT", "0.05"))  # 50ms
READ_TIMEOUT    = float(os.environ.get("READ_TIMEOUT", "0.05"))     # 50ms
WRITE_TIMEOUT   = float(os.environ.get("WRITE_TIMEOUT", "0.05"))    # 50ms

def now_ms():
    return int(time.time() * 1000)

def connect(host):
    return pymysql.connect(
        host=host, user=DB_USER, password=DB_PASS, database=DB_NAME, port=DB_PORT,
        connect_timeout=CONNECT_TIMEOUT, read_timeout=READ_TIMEOUT, write_timeout=WRITE_TIMEOUT,
        cursorclass=pymysql.cursors.DictCursor, autocommit=False
    )

def read_one(host, sku):
    start = now_ms()
    try:
        with connect(host) as conn, conn.cursor() as cur:
            cur.execute("SELECT sku, available_qty, version, updated_at FROM inventory WHERE sku=%s", (sku,))
            row = cur.fetchone()
            if not row:
                return {"host": host, "ok": False, "err": "NOT_FOUND", "latencyMs": now_ms()-start}
            row["host"] = host
            row["ok"] = True
            row["latencyMs"] = now_ms()-start
            return row
    except Exception as e:
        return {"host": host, "ok": False, "err": str(e), "latencyMs": now_ms()-start}

def conditional_update(host, sku, qty, expected_version):
    start = now_ms()
    try:
        with connect(host) as conn, conn.cursor() as cur:
            cur.execute(
                "UPDATE inventory SET available_qty=%s, version=version+1, updated_at=NOW(6) "
                "WHERE sku=%s AND version=%s",
                (qty, sku, expected_version)
            )
            affected = cur.rowcount
            conn.commit()
            return {"host": host, "ok": True, "affected": affected, "latencyMs": now_ms()-start}
    except Exception as e:
        return {"host": host, "ok": False, "err": str(e), "latencyMs": now_ms()-start}

def majority_value(rows):
    # Regla: mayoría por available_qty; si 1-1-1 usar el más reciente updated_at
    freq = {}
    for r in rows:
        if r.get("ok"):
            q = r["available_qty"]
            freq[q] = freq.get(q, 0) + 1
    if not freq:
        return None, "NO_OK_ROWS"
    # ¿hay mayoría (>=2)?
    winner = None
    for q,val in freq.items():
        if val >= 2:
            winner = q
            break
    if winner is not None:
        return {"available_qty": winner}, "MAJ"
    # 1-1-1: desempatar por updated_at más reciente
    ok_rows = [r for r in rows if r.get("ok")]
    ok_rows.sort(key=lambda r: r["updated_at"] or "", reverse=True)
    if ok_rows:
        return {"available_qty": ok_rows[0]["available_qty"]}, "TIE_UPDATED_AT"
    return None, "NO_TIE_BREAK"

def emf_log(metric_name, value, dims=None):
    # Formato Embedded Metric Format (EMF) para CloudWatch
    # https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format.html
    blob = {
        "_aws": {
            "Timestamp": now_ms(),
            "CloudWatchMetrics": [{
                "Namespace": "ConsistencyExperiment",
                "Dimensions": [list(dims.keys())] if dims else [[]],
                "Metrics": [{"Name": metric_name, "Unit": "Milliseconds"}]
            }]
        },
        metric_name: value
    }
    if dims:
        blob.update(dims)
    print(json.dumps(blob))

def handler(event, context):
    # Evento EventBridge esperado:
    # {
    #   "detail": {
    #       "sku": "ABC-123",
    #       "detectedAtEpochMs": 1730568000123
    #   }
    # }
    detail = event.get("detail") or {}
    sku = detail.get("sku")
    detected_at = int(detail.get("detectedAtEpochMs", now_ms()))
    t0 = now_ms()

    # Lecturas en paralelo (DB1..DB3)
    hosts = [DB1_HOST, DB2_HOST, DB3_HOST]
    read_start = now_ms()
    with ThreadPoolExecutor(max_workers=3) as ex:
        futures = [ex.submit(read_one, h, sku) for h in hosts]
        wait(futures, return_when=ALL_COMPLETED)
    rows = [f.result() for f in futures]
    read_ms = now_ms() - read_start

    # Decisión por mayoría
    maj_start = now_ms()
    maj, mode = majority_value(rows)
    maj_ms = now_ms() - maj_start
    if maj is None:
        resolution_latency_ms = now_ms() - detected_at
        emf_log("resolutionLatencyMs", resolution_latency_ms, {"sku": sku, "success": 0, "mode": mode})
        return {"status": "NO_DECISION", "mode": mode, "rows": rows}

    target_qty = maj["available_qty"]

    # Reparaciones: a cada nodo divergente, UPDATE con chequeo de versión
    repair_start = now_ms()
    updates = []
    with ThreadPoolExecutor(max_workers=3) as ex:
        futs = []
        for r in rows:
            if r.get("ok") and r["available_qty"] != target_qty:
                futs.append(ex.submit(conditional_update, r["host"], sku, target_qty, r["version"]))
        if futs:
            wait(futs, return_when=ALL_COMPLETED)
            updates = [f.result() for f in futs]
    repair_ms = now_ms() - repair_start

    resolved_at = now_ms()
    resolution_latency_ms = resolved_at - detected_at

    # Métricas EMF
    emf_log("resolutionLatencyMs", resolution_latency_ms, {"sku": sku, "success": 1})
    emf_log("dbReadParallelMs", read_ms, {"sku": sku})
    emf_log("majorityDecisionMs", maj_ms, {"sku": sku, "mode": mode})
    emf_log("dbRepairWriteMs", repair_ms, {"sku": sku})

    return {
        "status": "OK",
        "sku": sku,
        "mode": mode,
        "target_qty": target_qty,
        "reads": rows,
        "updates": updates,
        "resolutionLatencyMs": resolution_latency_ms
    }
