#!/usr/bin/env bash
# =====================================================================
# NairaFlow | Portfolio 4 - Key-value model with Redis
# Five access patterns where a key-value store beats the relational DB:
# sessions, OTP rate-limiting, idempotency keys, balance cache, leaderboards.
# =====================================================================
export MSYS_NO_PATHCONV=1
R() { echo "> redis-cli $*"; docker exec nf-redis redis-cli "$@"; }

R FLUSHALL
echo; echo "### K1 Mobile-app session token with automatic expiry (TTL)"
R SET session:9f3c2a1b '{"customerId":"CUS-000002","device":"dev-2","kyc":3}' EX 900
R GET session:9f3c2a1b
R TTL session:9f3c2a1b

echo; echo "### K2 OTP brute-force protection: max 3 attempts per phone per 5 minutes (INCR + EXPIRE)"
for i in 1 2 3 4; do
  n=$(docker exec nf-redis redis-cli INCR otp:attempts:+2348031234501)
  [ "$n" = "1" ] && docker exec nf-redis redis-cli EXPIRE otp:attempts:+2348031234501 300 >/dev/null
  if [ "$n" -le 3 ]; then echo "  attempt $n -> allowed"; else echo "  attempt $n -> BLOCKED (locked for $(docker exec nf-redis redis-cli TTL otp:attempts:+2348031234501)s)"; fi
done

echo; echo "### K3 Idempotency key: SET NX guarantees a retried transfer is processed once"
R SET idem:a1b2c3d4-0000-4000-8000-000000008103 PROCESSING NX EX 86400
R SET idem:a1b2c3d4-0000-4000-8000-000000008103 PROCESSING NX EX 86400
echo "  (nil on the 2nd call = duplicate request detected, return the stored result instead)"

echo; echo "### K4 Read-through balance cache (hash) - invalidated after each posting"
R HSET acct:0123456781 balance 964500.00 currency NGN status ACTIVE
R EXPIRE acct:0123456781 60
R HGETALL acct:0123456781
R DEL acct:0123456781

echo; echo "### K5 Real-time 'top senders today' leaderboard (sorted set)"
R ZINCRBY senders:2026-11-11 25000 0123456781
R ZINCRBY senders:2026-11-11 150000 0123456786
R ZINCRBY senders:2026-11-11 72000 0123456790
R ZINCRBY senders:2026-11-11 40000 0123456781
R ZREVRANGE senders:2026-11-11 0 2 WITHSCORES

echo; echo "### K6 Fraud velocity counter: distinct senders into an account per hour (HyperLogLog)"
for s in $(seq 1 120); do docker exec nf-redis redis-cli PFADD inflow:3000050001:2026111022 "sender$s" >/dev/null; done
R PFCOUNT inflow:3000050001:2026111022
echo "  ~12 KB per key regardless of sender count; approximate (0.81% std error) but O(1)"

echo; echo "### Memory and key overview"
R DBSIZE
R INFO memory | grep -E "used_memory_human|maxmemory_policy"
