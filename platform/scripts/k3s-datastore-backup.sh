#!/usr/bin/env bash
# k3s-datastore-backup.sh — online snapshot of the k3s SQLite (kine) datastore -> MinIO.
#
# WHY: this node's k3s datastore is SQLite/kine (state.db), not etcd, so there are no
# etcd-snapshots, and Velero captures k8s API objects, NOT the datastore file. This gives
# a lower-RPO, point-in-time datastore artifact for SAME-HOST rollback (corruption / bad
# bulk change). Full-host-loss DR remains rebuild-k3s + velero-restore (the encryption key
# in /var/lib/rancher/k3s/server/cred is deliberately NOT shipped here).
#
# HOW: SQLite online backup API (consistent on a live WAL db) -> gzip -> MinIO via SigV4
# (stdlib python; no aws/mc on the host). Dedicated least-privilege MinIO user, bucket
# k3s-datastore-backups (SSE-S3 + 7-day ILM expiry = automatic retention).
#
# Scheduled: platform/host/k3s-datastore-backup.cron -> /etc/cron.d/k3s-datastore-backup.
# Restore:   docs/03-runbooks/k3s-datastore-restore.md
#
# Usage (as root): k3s-datastore-backup.sh [backup | list [prefix] | get <key> <dest>]
set -euo pipefail

CMD="${1:-backup}"
DB="${K3S_DB:-/var/lib/rancher/k3s/server/db/state.db}"
SECRET_NS="${MINIO_SECRET_NS:-velero}"
SECRET_NAME="${MINIO_SECRET_NAME:-k3s-datastore-backup-minio}"
NAME_PREFIX="${NAME_PREFIX:-state}"
KUBECTL="${KUBECTL:-k3s kubectl}"

log(){ printf '[k3s-db-backup] %s\n' "$*"; }
command -v sqlite3 >/dev/null || { echo "ERROR: sqlite3 not installed (apt-get install -y sqlite3)" >&2; exit 1; }

# endpoint + scoped creds + bucket, all resolved from the cluster (nothing on cmdline)
CIP="$($KUBECTL get svc -n minio minio -o jsonpath='{.spec.clusterIP}')"
[ -n "$CIP" ] || { echo "ERROR: cannot resolve minio ClusterIP" >&2; exit 1; }
export S3_ENDPOINT="http://${CIP}:9000"
export S3_AKID="$($KUBECTL get secret "$SECRET_NAME" -n "$SECRET_NS" -o jsonpath='{.data.MINIO_ACCESS_KEY}' | base64 -d)"
export S3_SKEY="$($KUBECTL get secret "$SECRET_NAME" -n "$SECRET_NS" -o jsonpath='{.data.MINIO_SECRET_KEY}' | base64 -d)"
export S3_BUCKET="$($KUBECTL get secret "$SECRET_NAME" -n "$SECRET_NS" -o jsonpath='{.data.MINIO_BUCKET}' | base64 -d)"
[ -n "$S3_AKID" ] && [ -n "$S3_SKEY" ] && [ -n "$S3_BUCKET" ] || { echo "ERROR: missing MinIO creds/bucket in $SECRET_NS/$SECRET_NAME" >&2; exit 1; }

# Minimal S3 client (SigV4, path-style, stdlib only). Op + args via env.
s3py(){ python3 - <<'PY'
import os,sys,hashlib,hmac,datetime,urllib.request,urllib.parse,urllib.error,xml.etree.ElementTree as ET
AKID=os.environ["S3_AKID"];SKEY=os.environ["S3_SKEY"]
ENDPOINT=os.environ["S3_ENDPOINT"].rstrip("/");BUCKET=os.environ["S3_BUCKET"]
REGION=os.environ.get("S3_REGION","us-east-1");SERVICE="s3";HOST=urllib.parse.urlparse(ENDPOINT).netloc
OP=os.environ["S3_OP"];KEY=os.environ.get("S3_KEY","");FILE=os.environ.get("S3_FILE","");PFX=os.environ.get("S3_PFX","")
def _sign(k,m):return hmac.new(k,m.encode(),hashlib.sha256).digest()
def _sk(ds):
    k=_sign(("AWS4"+SKEY).encode(),ds);k=_sign(k,REGION);k=_sign(k,SERVICE);return _sign(k,"aws4_request")
def s3(method,path,query="",body=b"",extra=None):
    extra=extra or {};now=datetime.datetime.now(datetime.timezone.utc)
    amz=now.strftime("%Y%m%dT%H%M%SZ");ds=now.strftime("%Y%m%d");ph=hashlib.sha256(body).hexdigest()
    cu=urllib.parse.quote(path,safe="/~")
    qd=sorted(urllib.parse.parse_qsl(query,keep_blank_values=True))
    cqs="&".join("{}={}".format(urllib.parse.quote(k,safe="~"),urllib.parse.quote(v,safe="~")) for k,v in qd)
    h={"host":HOST,"x-amz-content-sha256":ph,"x-amz-date":amz}
    for k,v in extra.items():h[k.lower()]=v
    sh=";".join(sorted(h));ch="".join("{}:{}\n".format(k,h[k].strip()) for k in sorted(h))
    creq="\n".join([method,cu,cqs,ch,sh,ph]);scope="{}/{}/{}/aws4_request".format(ds,REGION,SERVICE)
    sts="\n".join(["AWS4-HMAC-SHA256",amz,scope,hashlib.sha256(creq.encode()).hexdigest()])
    sig=hmac.new(_sk(ds),sts.encode(),hashlib.sha256).hexdigest()
    auth="AWS4-HMAC-SHA256 Credential={}/{},SignedHeaders={},Signature={}".format(AKID,scope,sh,sig)
    req=urllib.request.Request(ENDPOINT+cu+(("?"+query) if query else ""),data=(body if method in("PUT","POST") else None),method=method)
    req.add_header("Authorization",auth)
    for k in h:
        if k!="host":req.add_header(k,h[k])
    return urllib.request.urlopen(req,timeout=600)
try:
    if OP=="put":
        with open(FILE,"rb") as f:body=f.read()
        s3("PUT","/{}/{}".format(BUCKET,KEY),body=body,extra={"x-amz-server-side-encryption":"AES256"});print(KEY)
    elif OP=="list":
        keys=[];tok=None
        while True:
            q="list-type=2&prefix="+urllib.parse.quote(PFX)
            if tok:q+="&continuation-token="+urllib.parse.quote(tok)
            root=ET.fromstring(s3("GET","/"+BUCKET,query=q).read().decode());ns="{http://s3.amazonaws.com/doc/2006-03-01/}"
            keys+=[e.text for e in root.iter(ns+"Key")]
            nt=root.find(ns+"NextContinuationToken")
            if nt is not None and nt.text:tok=nt.text
            else:break
        print("\n".join(sorted(keys)))
    elif OP=="get":
        with open(FILE,"wb") as f:f.write(s3("GET","/{}/{}".format(BUCKET,KEY)).read())
        print(FILE)
    elif OP=="delete":
        s3("DELETE","/{}/{}".format(BUCKET,KEY));print("deleted "+KEY)
    else:
        sys.stderr.write("unknown S3_OP\n");sys.exit(2)
except urllib.error.HTTPError as e:
    sys.stderr.write("S3 {} {} -> HTTP {}\n{}\n".format(OP,KEY,e.code,e.read().decode()[:500]));sys.exit(1)
PY
}

case "$CMD" in
  backup)
    [ -f "$DB" ] || { echo "ERROR: datastore not found at $DB (etcd datastore? this script is SQLite-only)" >&2; exit 1; }
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    TS="$(date -u +%Y%m%dT%H%M%SZ)"; HN="$(hostname -s)"
    SNAP="$TMP/${NAME_PREFIX}-${HN}-${TS}.db"
    log "online .backup of $DB"
    sqlite3 -readonly "$DB" <<SQL
.timeout 60000
.backup '$SNAP'
SQL
    sqlite3 "$SNAP" 'PRAGMA integrity_check;' | head -1 | grep -qx ok \
      || { echo "ERROR: snapshot failed integrity_check" >&2; exit 1; }
    gzip -1 "$SNAP"; SNAPGZ="$SNAP.gz"; KEY="$(basename "$SNAPGZ")"
    log "uploading s3://$S3_BUCKET/$KEY ($(du -h "$SNAPGZ" | cut -f1), SSE-S3)"
    S3_OP=put S3_KEY="$KEY" S3_FILE="$SNAPGZ" s3py >/dev/null
    log "done — retention via 7-day bucket ILM"
    ;;
  list) S3_OP=list S3_PFX="${2:-}" s3py ;;
  get)
    [ $# -ge 3 ] || { echo "usage: $0 get <key> <dest-file>" >&2; exit 2; }
    S3_OP=get S3_KEY="$2" S3_FILE="$3" s3py ;;
  *) echo "usage: $0 [backup | list [prefix] | get <key> <dest>]" >&2; exit 2 ;;
esac
