import json, sys
d = json.load(sys.stdin)
key = sys.argv[1]
if key not in d:
    sys.stderr.write("missing key %s in %s\n" % (key, json.dumps(d)[:400]))
    raise SystemExit(1)
print(d[key])
