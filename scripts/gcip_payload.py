import json, sys, time
sa, uid, dept = sys.argv[1], sys.argv[2], sys.argv[3]
now = int(time.time())
payload = {
    "iss": sa,
    "sub": sa,
    "aud": "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit",
    "iat": now,
    "exp": now + 3600,
    "uid": uid,
    "claims": {"department": dept},
}
print(json.dumps({"payload": json.dumps(payload)}))
